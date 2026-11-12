# Clean Your Mobile - apply a removal list (Windows)
#
# The PowerShell twin of scripts/debloat.sh. Same guard, same batching, same
# restore record.
#
#   powershell -ExecutionPolicy Bypass -File scripts\debloat.ps1 <plan> -DryRun
#   powershell -ExecutionPolicy Bypass -File scripts\debloat.ps1 <plan>
#   powershell -ExecutionPolicy Bypass -File scripts\debloat.ps1 <plan> -Disable
#
# Every removal is reversible. Nothing here needs root.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Plan,
    [switch]$DryRun,
    [switch]$Disable,
    [switch]$Yes,
    [ValidateRange(1, 5)][int]$BatchSize = 5,
    [string]$Session
)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

if (-not $Plan) {
    Write-Host "Usage: powershell -File scripts\debloat.ps1 <plan-file> [-DryRun] [-Disable] [-Yes] [-BatchSize 1-5]"
    exit 1
}
if (-not (Test-Path $Plan)) { Stop-Cym "Plan file not found: $Plan" }
if ($Session) { $env:CYM_SESSION = $Session }

$method = "uninstall"
if ($Disable) { $method = "disable" }

$title = "debloat"
if ($DryRun) { $title = "debloat (dry run)" }
Write-Banner $title

Assert-Device | Out-Null
Write-DeviceInfo
Import-Essentials

# ---------------------------------------------------------- read the plan ----
$wanted = New-Object System.Collections.ArrayList
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($line in (Get-Content $Plan)) {
    $text = $line
    $hash = $text.IndexOf("#")
    if ($hash -ge 0) { $text = $text.Substring(0, $hash) }
    $text = $text.Trim()
    if (-not $text) { continue }
    if ($seen.Add($text)) { [void]$wanted.Add($text) }
}
if ($wanted.Count -eq 0) { Stop-Cym "No package names in $Plan" }

# ------------------------------------------------------------- the guard -----
Write-Host ""
Write-Step "Checking the plan against the never-touch list"
$installed = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($p in (Get-CymPackages)) { [void]$installed.Add($p) }
# System apps only: anything else has no system copy, so `pm uninstall -k
# --user 0` would delete it and `install-existing` could not bring it back.
$system = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($p in (Get-CymPackages "-s")) { [void]$system.Add($p) }
if ($system.Count -eq 0) { Stop-Cym "The phone returned no system package list - refusing to continue." }

$queue   = New-Object System.Collections.ArrayList
$refused = New-Object System.Collections.ArrayList
$absent  = New-Object System.Collections.ArrayList
$regular = New-Object System.Collections.ArrayList
foreach ($pkg in $wanted) {
    $reason = Get-BlockReason $pkg
    if ($reason) {
        [void]$refused.Add([pscustomobject]@{ Id = $pkg; Reason = $reason })
    } elseif (-not $installed.Contains($pkg)) {
        [void]$absent.Add($pkg)
    } elseif (-not $system.Contains($pkg)) {
        [void]$regular.Add($pkg)
    } else {
        [void]$queue.Add($pkg)
    }
}

Write-Host ""
Write-Host (" In the plan        : {0}" -f $wanted.Count)
Write-Host (" Will be processed  : {0}" -f $queue.Count)
Write-Host (" Refused (protected): {0}" -f $refused.Count)
Write-Host (" Not installed      : {0}" -f $absent.Count)
Write-Host (" Left alone         : {0}  (regular apps, not system apps)" -f $regular.Count)

if ($refused.Count -gt 0) {
    Write-Host ""
    Write-Fail "Refused - these stay on the phone whatever the plan says:"
    foreach ($r in $refused) { Write-Host ("    {0,-52}{1}" -f $r.Id, $r.Reason) }
}
if ($absent.Count -gt 0) {
    Write-Host ""
    Write-Warn "Not installed on this phone, nothing to do:"
    foreach ($a in $absent) { Write-Host "    $a" }
}
if ($regular.Count -gt 0) {
    Write-Host ""
    Write-Warn "Left alone - regular apps, not system apps. A removal would delete the"
    Write-Warn "only copy and the restore record could not bring it back. Uninstall them"
    Write-Warn "from the home screen like any other app if you want them gone:"
    foreach ($r in $regular) { Write-Host "    $r" }
}
if ($queue.Count -eq 0) {
    Write-Host ""
    Write-Ok "Nothing left to do."
    exit 0
}

if ((Get-HomeResolverCount) -lt 1) {
    Write-Warn "Could not confirm a launcher answers HOME. Proceeding carefully."
}

# -------------------------------------------------------------- session ------
$sessionDir = Resume-OrNewSession
Initialize-Session $sessionDir
$logFile     = Join-Path $sessionDir "debloat.log"
$removedFile = Join-Path $sessionDir "removed_packages.txt"
$failedFile  = Join-Path $sessionDir "failed_packages.txt"
$restoreSh   = Join-Path $sessionDir "restore.sh"
$restorePs   = Join-Path $sessionDir "restore.ps1"
# Only on a real run: a dry run must leave the session exactly as it found it.
# An empty removed_packages.txt is not harmless - it used to shadow plan.txt and
# make tools/check.py report the session as unusable.
if (-not $DryRun) {
  foreach ($f in @($removedFile, $failedFile)) {
    if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f | Out-Null }
  }
}

function Write-Log([string]$Message) {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Add-Content -Path $logFile -Value "$stamp $Message" -Encoding utf8
}

Write-Host ""
Write-Rule
Write-Host " Session : $sessionDir"
if ($method -eq "disable") {
    Write-Host " Method  : pm disable-user --user 0 (app stays installed)"
} else {
    Write-Host " Method  : pm uninstall -k --user 0 (data kept, system copy kept)"
}
Write-Host (" Batches : {0} packages, {1} per batch, health check after each" -f $queue.Count, $BatchSize)
Write-Rule

# ---------------------------------------------------- restore record first ----
if (-not $DryRun) {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $shHeader = @"
#!/usr/bin/env bash
# Clean Your Mobile - restore script (generated)
# Device: $($script:Device.Brand) $($script:Device.Model), Android $($script:Device.Android)
# Generated: $stamp
set -uo pipefail
ADB="`${ADB_BINARY:-adb}"
run() { if [ -n "`${ANDROID_SERIAL:-}" ]; then "`$ADB" -s "`$ANDROID_SERIAL" "`$@"; else "`$ADB" "`$@"; fi; }
fail=0
echo "Restoring packages removed from $($script:Device.Brand) $($script:Device.Model)..."

"@
    Set-Content -Path $restoreSh -Value $shHeader -Encoding utf8 -NoNewline
    $psHeader = @"
# Clean Your Mobile - restore script (generated)
# Device: $($script:Device.Brand) $($script:Device.Model), Android $($script:Device.Android)
# Generated: $stamp
`$ErrorActionPreference = "Continue"
if (`$env:ADB_BINARY) { `$adb = `$env:ADB_BINARY } else { `$adb = "adb" }
`$fail = 0

"@
    Set-Content -Path $restorePs -Value $psHeader -Encoding utf8 -NoNewline
    Write-Log "SESSION start method=$method queue=$($queue.Count) plan=$Plan"
}

function Add-RestoreLine([string]$Pkg) {
    if ($method -eq "disable") {
        Add-Content $restoreSh "echo `"  $Pkg`"; run shell pm enable --user 0 $Pkg >/dev/null || fail=`$((fail+1))" -Encoding utf8
        Add-Content $restorePs "Write-Host `"  $Pkg`"; & `$adb shell pm enable --user 0 $Pkg | Out-Null; if (`$LASTEXITCODE -ne 0) { `$fail++ }" -Encoding utf8
    } else {
        Add-Content $restoreSh "echo `"  $Pkg`"; run shell cmd package install-existing $Pkg >/dev/null || fail=`$((fail+1))" -Encoding utf8
        Add-Content $restorePs "Write-Host `"  $Pkg`"; & `$adb shell cmd package install-existing $Pkg | Out-Null; if (`$LASTEXITCODE -ne 0) { `$fail++ }" -Encoding utf8
    }
}

# -------------------------------------------------------------- confirm ------
if (-not $DryRun -and -not $Yes) {
    Write-Host ""
    Write-Host (" About to process {0} package(s):" -f $queue.Count)
    $queue | Select-Object -First 60 | ForEach-Object { Write-Host "    $_" }
    if ($queue.Count -gt 60) { Write-Host ("    ... and {0} more" -f ($queue.Count - 60)) }
    Write-Host ""
    $answer = Read-Host " Type YES to continue, anything else to stop"
    if ($answer -ne "YES") {
        Write-Host " Stopped. Nothing was changed."
        exit 0
    }
}

# ----------------------------------------------------------- the removal -----
# Turn a pm error into something a person can act on. Kept in step with
# explain_failure() in scripts/debloat.sh.
function Get-FailureExplanation([string]$Reply) {
    if ($Reply -match "SecurityException" -and $Reply -match "no root permission") {
        return "blocked by the vendor ROM (would need root, which this project will not use)"
    }
    if ($Reply -match "change component state") {
        # ColorOS, realme UI and OxygenOS refuse a disable with "Permission
        # Denial: attempt to change component state"; some ROMs word it "Shell
        # cannot change component state". Same wall either way, and it used to
        # fall through and print a raw Java exception.
        return "the ROM will not let a shell change this package - vendor-protected, and no tool gets past it without root"
    }
    if ($Reply -match "DELETE_FAILED_INTERNAL_ERROR") {
        return "ROM refused the uninstall - try -Disable, or check Settings > Security > Device admin apps"
    }
    if ($Reply -match "DELETE_FAILED_DEVICE_POLICY_MANAGER") {
        return "a device policy or work profile owns this package"
    }
    if ($Reply -match "not installed for")  { return "not installed for this user - nothing to do" }
    if ($Reply -match "Unknown package")    { return "the phone does not know this package name" }
    if (-not $Reply)                        { return "no reply from the phone - the connection may have dropped" }
    # First meaningful line only; a Java stack trace is 15 lines of noise.
    $short = ($Reply -replace '\s*at [a-zA-Z0-9_.$]+\(.*', '')
    if ($short.Length -gt 120) { $short = $short.Substring(0, 120) }
    return $short
}

# Why '2>&1' inside the device shell: pm writes its refusals to stderr, and the
# adb wrapper discards stderr to keep adb's own noise out. The redirect happens
# on the phone, so the real reason travels back on stdout. Without it, a vendor
# refusal looked identical to a dropped connection.
function Remove-OnePackage([string]$Pkg) {
    if ($method -eq "disable") {
        $reply = (Invoke-Shell "pm disable-user --user 0 $Pkg 2>&1").Trim()
        if ($reply -match "new state: disabled-user") {
            return [pscustomobject]@{ Ok = $true; Reply = $reply; Raw = $reply }
        }
        return [pscustomobject]@{ Ok = $false; Reply = (Get-FailureExplanation $reply); Raw = $reply }
    }
    $reply = (Invoke-Shell "pm uninstall -k --user 0 $Pkg 2>&1").Trim()
    if ($reply -match "Success") {
        return [pscustomobject]@{ Ok = $true; Reply = $reply; Raw = $reply }
    }
    return [pscustomobject]@{ Ok = $false; Reply = (Get-FailureExplanation $reply); Raw = $reply }
}

function Test-PackageGone([string]$Pkg) {
    if ($method -eq "disable") {
        return ((Get-CymPackages "-d") -contains $Pkg)
    }
    return (-not ((Get-CymPackages "--user 0") -contains $Pkg))
}

$total = $queue.Count
$totalBatches = [math]::Ceiling($total / $BatchSize)
$done = 0; $failed = 0; $consecutive = 0; $aborted = $false

for ($i = 0; $i -lt $total; $i++) {
    $pkg = $queue[$i]

    if ($i % $BatchSize -eq 0) {
        Write-Host ""
        Write-Step ("Batch {0} of {1}" -f ([math]::Floor($i / $BatchSize) + 1), $totalBatches)
    }

    Write-Host ("  [{0}/{1}] {2,-48} " -f ($i + 1), $total, $pkg) -NoNewline

    if ($DryRun) {
        Write-Host "would $method" -ForegroundColor DarkGray
        $done++
        continue
    }

    $result = Remove-OnePackage $pkg
    if ($result.Ok) {
        if (Test-PackageGone $pkg) {
            Write-Host "ok" -ForegroundColor Green
            Write-Log "REMOVED $pkg"
        } else {
            Write-Host "unverified" -ForegroundColor Yellow
            Write-Log "UNVERIFIED $pkg reply=$($result.Reply)"
        }
        Add-Content $removedFile $pkg -Encoding utf8
        Add-RestoreLine $pkg
        $done++
        $consecutive = 0
    } else {
        Write-Host "failed " -ForegroundColor Red -NoNewline
        Write-Host $result.Reply
        Add-Content $failedFile ("{0}`t{1}" -f $pkg, $result.Reply) -Encoding utf8
        # Short explanation on screen and in failed_packages.txt; the phone's
        # full reply, stack trace and all, goes in the log.
        Write-Log "FAILED $pkg explanation=$($result.Reply) raw=$($result.Raw)"
        $failed++
        $consecutive++
        if ($consecutive -ge 3) {
            Write-Host ""
            Write-Fail "$consecutive removals failed in a row. Stopping here."
            Write-Host " Common causes: the package is protected by the ROM, a work"
            Write-Host " profile owns it, or the ADB connection dropped."
            $aborted = $true
            break
        }
    }

    if ((($i + 1) % $BatchSize -eq 0) -or ($i -eq $total - 1)) {
        Write-Host "  health check " -ForegroundColor DarkGray -NoNewline
        if (Test-DeviceHealth) {
            Write-Host "phone responsive" -ForegroundColor Green
            Write-Log "HEALTH ok after $($i + 1)"
        } else {
            Write-Host "no answer" -ForegroundColor Red
            Write-Host ""
            Write-Fail "The phone stopped answering after this batch. Stopping."
            Write-Log "HEALTH failed after $($i + 1)"
            Write-Host ""
            Write-Host " Attempting to restore this batch..."
            $batchStart = $i - ($i % $BatchSize)
            for ($j = $batchStart; $j -le $i; $j++) {
                $p = $queue[$j]
                Write-Host ("    {0} ... " -f $p) -NoNewline
                if ($method -eq "disable") {
                    Invoke-Shell "pm enable --user 0 $p" | Out-Null
                } else {
                    Invoke-Shell "cmd package install-existing $p" | Out-Null
                }
                Write-Host "attempted"
            }
            Write-Host ""
            Write-Host " If the phone is still unresponsive, see docs\TROUBLESHOOTING.md"
            Write-Host " (hold power 10-20 seconds to reboot; a reboot alone fixes most of this)."
            $aborted = $true
            break
        }
    }
}

if (-not $DryRun) {
    Add-Content $restoreSh @"

echo ""
if [ "`$fail" -eq 0 ]; then
    echo "Restore complete. Reboot the phone to be sure everything comes back."
else
    echo "`$fail package(s) would not restore."
    echo "Try again after a reboot; a factory reset brings back every system package."
fi
"@ -Encoding utf8
    Add-Content $restorePs @"

Write-Host ""
if (`$fail -eq 0) { Write-Host "Restore complete. Reboot the phone." }
else { Write-Host "`$fail package(s) would not restore. Try again after a reboot." }
"@ -Encoding utf8

    if ((Get-HomeResolverCount) -lt 1) {
        Write-Host ""
        Write-Fail "Nothing answers HOME any more. Run the restore script now:"
        Write-Host "   powershell -ExecutionPolicy Bypass -File `"$restorePs`""
    }
}

# ---------------------------------------------------------------- summary ----
Write-Host ""
Write-Rule
if ($DryRun) {
    Write-Host " DRY RUN - nothing on the phone was changed" -ForegroundColor White
    Write-Host (" Would process : {0} package(s)" -f $done)
    Write-Host (" Would refuse  : {0} package(s)" -f $refused.Count)
    Write-Host (" Left alone    : {0} regular app(s)" -f $regular.Count)
    Write-Rule
    Write-Host " Re-run without -DryRun to apply it."
    exit 0
}
Write-Host " Result" -ForegroundColor White
Write-Host (" Processed : {0}" -f $done)
Write-Host (" Failed    : {0}" -f $failed)
Write-Host (" Refused   : {0}" -f $refused.Count)
Write-Host (" Left alone: {0}" -f $regular.Count)
if ($aborted) {
    Write-Host (" Run stopped early - {0} package(s) were not reached" -f ($total - $done - $failed)) -ForegroundColor Yellow
}
Write-Rule
Write-Host " Restore   : powershell -ExecutionPolicy Bypass -File `"$restorePs`""
Write-Host " Log       : $logFile"
Write-Rule
Write-Log "SESSION end processed=$done failed=$failed aborted=$aborted"
Write-Host ""
Write-Host " Next: adb reboot, then"
Write-Host "       powershell -ExecutionPolicy Bypass -File scripts\snapshot.ps1 after"
Write-Host "       python tools\report.py --session `"$sessionDir`""

if ($aborted) { exit 2 }
exit 0
