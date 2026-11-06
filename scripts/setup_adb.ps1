# Clean Your Mobile - install the Android platform tools (Windows)
#
#   powershell -ExecutionPolicy Bypass -File scripts\setup_adb.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\setup_adb.ps1 -Force
#   powershell -ExecutionPolicy Bypass -File scripts\setup_adb.ps1 -Persist
#
# -Force    reinstall even when adb is already on the PATH
# -Persist  add the install directory to your user PATH permanently
#
# This file is deliberately ASCII only. Windows PowerShell 5.1 reads a script
# without a byte-order mark as ANSI, and a stray emoji then breaks the parse
# before a single line runs.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Persist
)

$ErrorActionPreference = "Stop"

$Rule = "-" * 60
function Write-Rule { Write-Host $Rule -ForegroundColor DarkGray }
function Write-Ok  ([string]$m) { Write-Host "  ok  " -ForegroundColor Green  -NoNewline; Write-Host $m }
function Write-Warn([string]$m) { Write-Host " warn " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Fail([string]$m) { Write-Host " fail " -ForegroundColor Red    -NoNewline; Write-Host $m }

Write-Rule
Write-Host " Clean Your Mobile" -ForegroundColor White -NoNewline
Write-Host " - ADB setup"
Write-Rule

$installDir = Join-Path $env:USERPROFILE "platform-tools"
$adbExe = Join-Path $installDir "adb.exe"

# -------------------------------------------------------- already there? -----
function Get-AdbVersion([string]$Exe) {
    try {
        $out = & $Exe version 2>$null
        if ($out) { return ($out | Select-Object -First 1) }
    } catch {}
    return $null
}

$existing = Get-Command adb -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    $version = Get-AdbVersion $existing.Source
    Write-Ok "adb is already installed"
    Write-Host "   $($existing.Source)"
    if ($version) { Write-Host "   $version" }
    Write-Host ""
    Write-Host " Nothing to do. Pass -Force to reinstall anyway."
    Write-Host " Next: powershell -ExecutionPolicy Bypass -File scripts\connect.ps1"
    exit 0
}

if ((Test-Path $adbExe) -and -not $Force) {
    Write-Ok "Found a copy at $adbExe"
    Write-Warn "It is not on your PATH for this session."
    $env:PATH = "$installDir;$env:PATH"
    Write-Ok "Added for this terminal session."
} else {
    # ------------------------------------------------------------ download ---
    $url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
    $zip = Join-Path $env:TEMP "cym-platform-tools.zip"

    Write-Host ""
    Write-Host " Source : Google official platform-tools"
    Write-Host " Target : $installDir"
    Write-Host ""
    Write-Host "Downloading..." -ForegroundColor Cyan

    # TLS 1.2 is not the default on older Windows PowerShell and the download
    # fails with a bare "could not create SSL/TLS secure channel" without it.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
    } catch {}

    $progressBackup = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"   # a progress bar makes this ~10x slower
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        Write-Fail "Download failed: $($_.Exception.Message)"
        Write-Host ""
        Write-Host " Download it by hand instead:"
        Write-Host "   $url"
        Write-Host " then unzip it so that this path exists:"
        Write-Host "   $adbExe"
        exit 1
    } finally {
        $ProgressPreference = $progressBackup
    }
    $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Ok "Downloaded $sizeMb MB"

    Write-Host "Extracting..." -ForegroundColor Cyan
    if (Test-Path $installDir) {
        # Only replace a directory that looks like platform-tools, never an
        # unrelated folder that happens to sit at that path.
        if ((Test-Path (Join-Path $installDir "adb.exe")) -or
            (Test-Path (Join-Path $installDir "NOTICE.txt"))) {
            Remove-Item $installDir -Recurse -Force
        } else {
            Write-Fail "$installDir exists and does not look like platform-tools."
            Write-Host " Move it aside and run this again."
            exit 1
        }
    }
    Expand-Archive -Path $zip -DestinationPath $env:USERPROFILE -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $adbExe)) {
        Write-Fail "Extraction did not produce $adbExe"
        exit 1
    }
    Write-Ok "Extracted to $installDir"
    $env:PATH = "$installDir;$env:PATH"
}

# ---------------------------------------------------------------- verify -----
$version = Get-AdbVersion $adbExe
if (-not $version) {
    Write-Fail "adb is in place but will not run. Check your antivirus quarantine."
    exit 1
}
Write-Host ""
Write-Ok "adb works"
Write-Host "   $version"

# ------------------------------------------------------------------ PATH -----
Write-Host ""
if ($Persist) {
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -and ($userPath -split ";" | Where-Object { $_.TrimEnd("\") -eq $installDir.TrimEnd("\") })) {
        Write-Ok "Already on your user PATH."
    } else {
        $newPath = $installDir
        if ($userPath) { $newPath = "$userPath;$installDir" }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Ok "Added to your user PATH permanently."
        Write-Host "   Open a new terminal for other programs to see it."
    }
} else {
    Write-Warn "adb is on the PATH for THIS terminal session only."
    Write-Host "   To make it permanent, run this script again with -Persist,"
    Write-Host "   or add this directory to your PATH by hand:"
    Write-Host "   $installDir"
}

Write-Host ""
Write-Rule
Write-Host " On the phone, before you connect:"
Write-Host "   Settings > About phone > tap Build number seven times"
Write-Host "   Settings > System > Developer options > USB debugging ON"
Write-Host ""
Write-Host " Then:  powershell -ExecutionPolicy Bypass -File scripts\connect.ps1"
Write-Rule
Write-Host ""
Write-Host " If the phone shows as 'unauthorized', unlock the screen and accept"
Write-Host " the 'Allow USB debugging?' dialog. If Windows does not see the phone"
Write-Host " at all, install your manufacturer's USB driver, or try a different"
Write-Host " cable: charge-only cables carry no data."
