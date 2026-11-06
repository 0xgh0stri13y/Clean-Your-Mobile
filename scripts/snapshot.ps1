# Clean Your Mobile - system snapshot (Windows)
#
# The PowerShell twin of scripts/snapshot.sh. Writes into the current session
# directory so before and after land side by side.
#
#   powershell -ExecutionPolicy Bypass -File scripts\snapshot.ps1 before
#   powershell -ExecutionPolicy Bypass -File scripts\snapshot.ps1 after

[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet("before", "after")][string]$Phase = "before",
    [string]$Session
)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

if ($Session) { $env:CYM_SESSION = $Session }

Write-Banner "snapshot ($Phase)"
Assert-Device | Out-Null
Write-DeviceInfo

if ($Phase -eq "before") {
    $sessionDir = Get-SessionDir
} else {
    $sessionDir = Resume-OrNewSession
    if (-not (Test-Path (Join-Path $sessionDir "snapshot_before.txt"))) {
        Stop-Cym "No before snapshot in $sessionDir. Run the before snapshot first, or pass -Session."
    }
}
Initialize-Session $sessionDir
Write-Rule
Write-Host " Session : $sessionDir"
Write-Rule

function Get-Digits($Value) {
    if (-not $Value) { return 0 }
    $digits = ($Value -replace "[^0-9]", "")
    if (-not $digits) { return 0 }
    return [int64]$digits
}

function Measure-CymPackages([string]$Flags = "") {
    return (Get-CymPackages $Flags).Count
}

Write-Step "Packages"
$pkgTotal    = Measure-CymPackages
$pkgSystem   = Measure-CymPackages "-s"
$pkgUser     = Measure-CymPackages "-3"
$pkgDisabled = Measure-CymPackages "-d"
$pkgEnabled  = Measure-CymPackages "-e"
Write-Ok "$pkgTotal installed, $pkgDisabled disabled"

Write-Step "Memory"
$meminfo = Invoke-Shell "cat /proc/meminfo"
function Get-MemField([string]$Name) {
    $line = ($meminfo -split "`n" | Where-Object { $_ -match "^$Name\s*:" } | Select-Object -First 1)
    return (Get-Digits $line)
}
$memTotal  = Get-MemField "MemTotal"
$memAvail  = Get-MemField "MemAvailable"
$memFree   = Get-MemField "MemFree"
$memCached = Get-MemField "Cached"
$memUsed = 0
if ($memTotal -gt $memAvail) { $memUsed = $memTotal - $memAvail }
Write-Ok ("{0} MB available of {1} MB" -f [math]::Round($memAvail / 1024), [math]::Round($memTotal / 1024))

Write-Step "Storage"
$dfLine = (Invoke-Shell "df /data" -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() } | Select-Object -First 1)
$dfCols = @($dfLine -split "\s+" | Where-Object { $_ })
$dataTotal = 0; $dataUsed = 0; $dataFree = 0
if ($dfCols.Count -ge 4) {
    $dataTotal = Get-Digits $dfCols[1]
    $dataUsed  = Get-Digits $dfCols[2]
    $dataFree  = Get-Digits $dfCols[3]
}
Write-Ok ("{0} MB free on /data" -f [math]::Round($dataFree / 1024))

Write-Step "Battery"
$battDump = Invoke-Shell "dumpsys battery"
$battLevel = Get-Digits (($battDump -split "`n" | Where-Object { $_ -match "^\s*level:" } | Select-Object -First 1))
$battTempDeci = Get-Digits (($battDump -split "`n" | Where-Object { $_ -match "temperature:" } | Select-Object -First 1))
$battStatusLine = ($battDump -split "`n" | Where-Object { $_ -match "^\s*status:" } | Select-Object -First 1)
$battStatus = "unknown"
if ($battStatusLine) { $battStatus = ($battStatusLine -split ":")[1].Trim() }
$battTemp = [math]::Round($battTempDeci / 10, 1)
Write-Ok "level $battLevel%, $battTemp C"

Write-Step "Processes and services"
# dumpsys names the same process in several places, so counting matching lines
# counts one process many times. Count distinct pid:name pairs instead.
$procDump = Invoke-Shell "dumpsys activity processes"
$svcDump  = Invoke-Shell "dumpsys activity services"
$procCount = @([regex]::Matches($procDump, 'ProcessRecord\{[0-9a-f]+ ([0-9]+:[^}]+)\}') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count
# The ranked process list is printed twice and its row label differs by Android
# version (Proc, APP, PERS), so match any of them and dedupe by pid.
$bgCount = @($procDump -split "`n" |
    Where-Object { $_ -match '^\s+(Proc|APP|PERS) #\s*[0-9]+:\s+cch' } |
    ForEach-Object { [regex]::Match($_, '[0-9]+:[a-zA-Z][^ ]*').Value } |
    Where-Object { $_ } | Sort-Object -Unique).Count
$svcCount = @($svcDump -split "`n" | Where-Object { $_ -match '^\s+\* ServiceRecord\{' }).Count
Write-Ok "$procCount app processes, $svcCount services, $bgCount cached"

Write-Step "Permission holders"
$permDump = Invoke-Shell "dumpsys package packages"
function Measure-Perm([string]$Permission) {
    return @($permDump -split "`n" | Where-Object {
        $_ -match [regex]::Escape("android.permission.$Permission") -and $_ -match "granted=true"
    }).Count
}
$permLoc = Measure-Perm "ACCESS_FINE_LOCATION"
$permCam = Measure-Perm "CAMERA"
$permMic = Measure-Perm "RECORD_AUDIO"
$permCon = Measure-Perm "READ_CONTACTS"
$permSms = Measure-Perm "READ_SMS"
$permTel = Measure-Perm "READ_PHONE_STATE"
Write-Ok "location $permLoc, camera $permCam, mic $permMic, contacts $permCon"

Write-Step "Launcher and animation"
$homeResolved = Invoke-Shell "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
$homePkg = "unknown"
$homeLines = @($homeResolved -split "`n" | Where-Object { $_ -match "/" })
if ($homeLines.Count -gt 0) { $homePkg = ($homeLines[-1] -split "/")[0].Trim() }
$animWin   = (Invoke-Shell "settings get global window_animation_scale").Trim()
$animTrans = (Invoke-Shell "settings get global transition_animation_scale").Trim()
$animDur   = (Invoke-Shell "settings get global animator_duration_scale").Trim()

Write-Step "Saving package lists"
$maps = @{
    ("packages_{0}_full.txt"     -f $Phase) = "-f"
    ("packages_{0}.txt"          -f $Phase) = ""
    ("packages_{0}_disabled.txt" -f $Phase) = "-d"
    ("packages_{0}_user.txt"     -f $Phase) = "-3"
    ("packages_{0}_system.txt"   -f $Phase) = "-s"
}
foreach ($name in $maps.Keys) {
    $list = Get-CymPackages $maps[$name]
    Set-Content -Path (Join-Path $sessionDir $name) -Value $list -Encoding utf8
}
Write-Ok ("{0} names recorded" -f $pkgTotal)

# ----------------------------------------------------------------- output ----
$asMb = { param($kb) [math]::Round($kb / 1024) }
$taken = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$txt = @"
CLEAN YOUR MOBILE - $($Phase.ToUpper()) SNAPSHOT
Taken        : $taken
Device       : $($script:Device.Brand) $($script:Device.Model) ($($script:Device.Device))
Android      : $($script:Device.Android) (API $($script:Device.Sdk))
Build        : $($script:Device.Build)
Patch level  : $($script:Device.SecurityPatch)

Total packages      : $pkgTotal
System packages     : $pkgSystem
User packages       : $pkgUser
Enabled packages    : $pkgEnabled
Disabled packages   : $pkgDisabled

RAM total MB        : $(& $asMb $memTotal)
RAM available MB    : $(& $asMb $memAvail)
RAM used MB         : $(& $asMb $memUsed)
RAM free MB         : $(& $asMb $memFree)
RAM cached MB       : $(& $asMb $memCached)

Data total MB       : $(& $asMb $dataTotal)
Data used MB        : $(& $asMb $dataUsed)
Data free MB        : $(& $asMb $dataFree)

Battery level       : $battLevel
Battery temp C      : $battTemp
Battery status      : $battStatus

Running processes   : $procCount
Running services    : $svcCount
Cached processes    : $bgCount

Location access     : $permLoc
Camera access       : $permCam
Microphone access   : $permMic
Contacts access     : $permCon
SMS access          : $permSms
Phone state access  : $permTel

Home launcher       : $homePkg
Animation scales    : window $animWin / transition $animTrans / animator $animDur
"@
$txtPath = Join-Path $sessionDir ("snapshot_{0}.txt" -f $Phase)
Set-Content -Path $txtPath -Value $txt -Encoding utf8

$payload = [ordered]@{
    phase  = $Phase
    taken  = $taken
    device = [ordered]@{
        brand = $script:Device.Brand; model = $script:Device.Model
        device = $script:Device.Device; android = $script:Device.Android
        sdk = $script:Device.Sdk; build = $script:Device.Build
        security_patch = $script:Device.SecurityPatch
    }
    packages = [ordered]@{
        total = $pkgTotal; system = $pkgSystem; user = $pkgUser
        enabled = $pkgEnabled; disabled = $pkgDisabled
    }
    memory_kb = [ordered]@{
        total = $memTotal; available = $memAvail; used = $memUsed
        free = $memFree; cached = $memCached
    }
    storage_kb = [ordered]@{
        data_total = $dataTotal; data_used = $dataUsed; data_free = $dataFree
    }
    battery = [ordered]@{ level = $battLevel; temperature_c = $battTemp; status = $battStatus }
    runtime = [ordered]@{ processes = $procCount; services = $svcCount; cached_processes = $bgCount }
    permissions = [ordered]@{
        location = $permLoc; camera = $permCam; microphone = $permMic
        contacts = $permCon; sms = $permSms; phone_state = $permTel
    }
    home_launcher = $homePkg
    animation = [ordered]@{ window = $animWin; transition = $animTrans; animator = $animDur }
}
$jsonPath = Join-Path $sessionDir ("snapshot_{0}.json" -f $Phase)
($payload | ConvertTo-Json -Depth 6) | Out-File -FilePath $jsonPath -Encoding utf8

Write-Host ""
Write-Rule
Write-Ok "Snapshot written"
Write-Host "   $txtPath"
Write-Host "   $jsonPath"
Write-Rule
if ($Phase -eq "before") {
    Write-Host " Next: python tools\scan.py --session `"$sessionDir`" --plan"
} else {
    Write-Host " Next: python tools\report.py --session `"$sessionDir`""
}
