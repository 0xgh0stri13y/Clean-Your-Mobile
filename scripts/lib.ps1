# Clean Your Mobile - shared PowerShell library
# Dot-sourced by the other .ps1 scripts. Not meant to be run directly.
# Written for Windows PowerShell 5.1, so no ternary and no && chaining.

$ErrorActionPreference = "Stop"

$script:CymLibDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CymRoot       = Split-Path -Parent $script:CymLibDir
$script:CymDbDir      = Join-Path $script:CymRoot "database"
if ($env:CYM_BACKUP_ROOT) {
    $script:CymBackupRoot = $env:CYM_BACKUP_ROOT
} else {
    $script:CymBackupRoot = Join-Path $script:CymRoot "backups"
}

$script:Rule = "-" * 60

function Write-Rule { Write-Host $script:Rule -ForegroundColor DarkGray }

function Write-Banner([string]$Title) {
    Write-Rule
    Write-Host " Clean Your Mobile" -ForegroundColor White -NoNewline
    Write-Host " - $Title"
    Write-Rule
}

function Write-Step([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok  ([string]$Message) { Write-Host "  ok  " -ForegroundColor Green  -NoNewline; Write-Host $Message }
function Write-Warn([string]$Message) { Write-Host " warn " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Fail([string]$Message) { Write-Host " fail " -ForegroundColor Red    -NoNewline; Write-Host $Message }
function Stop-Cym  ([string]$Message) { Write-Fail $Message; exit 1 }

# ------------------------------------------------------------------- adb ----
function Find-Adb {
    if ($env:ADB_BINARY) {
        $cmd = Get-Command $env:ADB_BINARY -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        if (Test-Path $env:ADB_BINARY) { return $env:ADB_BINARY }
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:USERPROFILE "platform-tools\adb.exe"),
        (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"),
        (Join-Path $env:USERPROFILE "AppData\Local\Android\Sdk\platform-tools\adb.exe"),
        "C:\Android\platform-tools\adb.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Initialize-Adb {
    $script:Adb = Find-Adb
    if (-not $script:Adb) {
        Stop-Cym "adb not found. Run: powershell -ExecutionPolicy Bypass -File scripts\setup_adb.ps1"
    }
}

# Invoke-Adb returns the device's stdout as a single string, newlines normalised.
function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $argv = @()
    if ($script:AndroidSerial) { $argv += @("-s", $script:AndroidSerial) }
    $argv += $Args
    $out = & $script:Adb @argv 2>$null
    if ($null -eq $out) { return "" }
    return ($out -join "`n").Replace("`r", "")
}

function Invoke-Shell([string]$Command) { return (Invoke-Adb "shell" $Command) }

function Get-Prop([string]$Name) { return (Invoke-Shell "getprop $Name").Trim() }

function Get-CymPackages([string]$Flags = "") {
    $out = Invoke-Shell ("pm list packages " + $Flags)
    if (-not $out) { return @() }
    return @($out -split "`n" |
        Where-Object { $_.Trim().StartsWith("package:") } |
        ForEach-Object { $_.Trim().Substring(8) } |
        Sort-Object)
}

function Get-HomeResolverCount {
    $out = Invoke-Shell "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    if (-not $out) { return 0 }
    return @($out -split "`n" | Where-Object { $_ -match "/" }).Count
}

function Assert-Device {
    Initialize-Adb
    if (-not $script:AndroidSerial) { $script:AndroidSerial = $env:ANDROID_SERIAL }

    $raw = & $script:Adb devices 2>$null
    $rows = @()
    foreach ($line in ($raw | Select-Object -Skip 1)) {
        if (-not $line -or -not $line.Trim()) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -ge 2) {
            $rows += [pscustomobject]@{ Serial = $parts[0].Trim(); State = $parts[1].Trim() }
        }
    }
    if ($rows.Count -eq 0) {
        Stop-Cym "No device found. Plug the phone in, or run: powershell -File scripts\connect.ps1"
    }
    foreach ($r in $rows) {
        if ($r.State -eq "unauthorized") {
            Write-Warn "$($r.Serial) is unauthorized - accept the Allow USB debugging prompt on the phone."
        } elseif ($r.State -eq "offline") {
            Write-Warn "$($r.Serial) is offline - replug it, or re-run connect.ps1."
        }
    }
    $ready = @($rows | Where-Object { $_.State -eq "device" } | ForEach-Object { $_.Serial })
    if ($ready.Count -eq 0) { Stop-Cym "No device is ready. See the warnings above." }
    if ($ready.Count -gt 1 -and -not $script:AndroidSerial) {
        Write-Fail "More than one device is connected:"
        $ready | ForEach-Object { Write-Host "    $_" }
        Stop-Cym 'Pick one: $env:ANDROID_SERIAL = "<serial>"'
    }
    if (-not $script:AndroidSerial) { $script:AndroidSerial = $ready[0] }

    $script:Device = [pscustomobject]@{
        Serial        = $script:AndroidSerial
        Brand         = Get-Prop "ro.product.brand"
        Model         = Get-Prop "ro.product.model"
        Device        = Get-Prop "ro.product.device"
        Android       = Get-Prop "ro.build.version.release"
        Sdk           = Get-Prop "ro.build.version.sdk"
        Build         = Get-Prop "ro.build.display.id"
        SecurityPatch = Get-Prop "ro.build.version.security_patch"
    }
    if (-not $script:Device.Model) {
        Stop-Cym "The device answered but reported no model. Is the screen unlocked?"
    }
    return $script:Device
}

function Write-DeviceInfo {
    Write-Host (" Device  : {0} {1} ({2})" -f $script:Device.Brand, $script:Device.Model, $script:Device.Device)
    Write-Host (" Android : {0} (API {1}), build {2}" -f $script:Device.Android, $script:Device.Sdk, $script:Device.Build)
    Write-Host (" Serial  : {0}" -f $script:Device.Serial)
}

function Test-DeviceHealth {
    Invoke-Shell "input keyevent KEYCODE_HOME" | Out-Null
    Start-Sleep -Seconds 2
    $probe = (Invoke-Shell "echo cym_alive").Trim()
    if ($probe -ne "cym_alive") { return $false }
    $pkg = Invoke-Shell "cmd package list packages android"
    if (-not $pkg) { return $false }
    return $true
}

# -------------------------------------------------------------- sessions ----
function Get-CymSlug([string]$Text) {
    if (-not $Text) { return "unknown" }
    $s = ($Text.ToLower() -replace "[^a-z0-9]+", "-").Trim("-")
    if (-not $s) { return "unknown" }
    return $s
}

function Get-SessionDir {
    if ($env:CYM_SESSION) {
        if ($env:CYM_SESSION -match "[\\/:]") { return $env:CYM_SESSION }
        return (Join-Path $script:CymBackupRoot $env:CYM_SESSION)
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $name = "{0}-{1}-{2}" -f (Get-CymSlug $script:Device.Brand), (Get-CymSlug $script:Device.Model), $stamp
    return (Join-Path $script:CymBackupRoot $name)
}

function Resume-OrNewSession {
    if ($env:CYM_SESSION) { return (Get-SessionDir) }
    $pointer = Join-Path $script:CymBackupRoot ".last-session"
    if (Test-Path $pointer) {
        $last = (Get-Content $pointer -Raw).Trim()
        if ($last -and (Test-Path $last)) {
            $serialFile = Join-Path $last "device.serial"
            if (Test-Path $serialFile) {
                $recorded = (Get-Content $serialFile -Raw).Trim()
                if ($recorded -eq $script:AndroidSerial) { return $last }
            }
        }
    }
    return (Get-SessionDir)
}

function Get-LatestSession {
    $pointer = Join-Path $script:CymBackupRoot ".last-session"
    if (Test-Path $pointer) {
        $last = (Get-Content $pointer -Raw).Trim()
        if ($last -and (Test-Path $last)) { return $last }
    }
    if (-not (Test-Path $script:CymBackupRoot)) { return $null }
    $newest = Get-ChildItem $script:CymBackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return $null
}

function Initialize-Session([string]$Dir) {
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    if (-not (Test-Path $script:CymBackupRoot)) {
        New-Item -ItemType Directory -Path $script:CymBackupRoot -Force | Out-Null
    }
    Set-Content -Path (Join-Path $Dir "device.serial") -Value $script:AndroidSerial -Encoding utf8
    Set-Content -Path (Join-Path $script:CymBackupRoot ".last-session") -Value $Dir -Encoding utf8
    $devJson = Join-Path $Dir "device.json"
    if (-not (Test-Path $devJson)) {
        $payload = [ordered]@{
            brand          = $script:Device.Brand
            model          = $script:Device.Model
            device         = $script:Device.Device
            android        = $script:Device.Android
            sdk            = $script:Device.Sdk
            build          = $script:Device.Build
            security_patch = $script:Device.SecurityPatch
            serial         = $script:Device.Serial
            created        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        ($payload | ConvertTo-Json) | Out-File -FilePath $devJson -Encoding utf8
    }
}

# -------------------------------------------------------- essential guard ----
# The hard stop, the same list the shell and Python tools read.
function Import-Essentials {
    if ($script:CymEssentials) { return }
    $file = Join-Path $script:CymDbDir "essential_packages.json"
    if (-not (Test-Path $file)) {
        Stop-Cym "Missing $file - refusing to touch anything without the never-touch list."
    }
    $raw = Get-Content $file -Raw | ConvertFrom-Json
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($prop in $raw.PSObject.Properties) {
        if ($prop.Name -eq "_meta") { continue }
        if ($prop.Value -is [array]) {
            # Not $pid: that is a read-only automatic variable in PowerShell
            # and assigning to it throws, which took the whole guard down.
            foreach ($entry in $prop.Value) { [void]$set.Add([string]$entry) }
        }
    }
    if ($set.Count -eq 0) { Stop-Cym "The never-touch list parsed as empty - refusing to continue." }
    $script:CymEssentials = $set
}

function Test-Essential([string]$PackageId) {
    Import-Essentials
    return $script:CymEssentials.Contains($PackageId)
}

# Package names that mean "do not touch" on their own. Kept in step with
# scripts/lib.sh and tools/cym.py - see docs/DATABASE.md.
# The trailing group covers build-time infrastructure rather than apps: runtime
# resource overlays, framework resources, GPU drivers and graphics layers.
# Removing one of those can cost you the display.
$script:ProtectedPattern = '(^android$|systemui|^com\.android\.settings|telecom|telephony|dialer|incallui|\.mms|messaging|inputmethod|latin|keyboard|^com\.android\.vending$|^com\.google\.android\.gms|^com\.google\.android\.gsf|setupwizard|provision|keystore|keychain|permissioncontroller|packageinstaller|networkstack|\.wifi|bluetooth|^com\.android\.camera|launcher|\.home$|overlay|\.rro\.|_rro$|frameworkres|gpudrivers|vulkan|\.resources$|^android\.auto_generated)'

function Get-BlockReason([string]$PackageId) {
    if (Test-Essential $PackageId) { return "on the never-touch list" }
    if ($PackageId -match $script:ProtectedPattern -and $env:CYM_ALLOW_PROTECTED -ne "1") {
        return "name matches a protected category"
    }
    return $null
}
