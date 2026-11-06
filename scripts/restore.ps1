# Clean Your Mobile - restore (Windows)
#
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -Path backups\<session>
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -All
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -Package com.foo.bar
#   powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -List

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [switch]$All,
    [switch]$List,
    [string]$Package
)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

Write-Banner "restore"

if ($List) {
    if (-not (Test-Path $script:CymBackupRoot)) {
        Write-Host " No sessions in $($script:CymBackupRoot) yet."
        exit 0
    }
    $dirs = Get-ChildItem $script:CymBackupRoot -Directory -ErrorAction SilentlyContinue
    if (-not $dirs) {
        Write-Host " No sessions in $($script:CymBackupRoot) yet."
        exit 0
    }
    foreach ($d in $dirs) {
        $file = Join-Path $d.FullName "removed_packages.txt"
        $count = 0
        if (Test-Path $file) {
            $count = @(Get-Content $file | Where-Object { $_.Trim() }).Count
        }
        Write-Host ("  {0,-44}{1,3} package(s)" -f $d.Name, $count)
    }
    exit 0
}

Assert-Device | Out-Null
Write-DeviceInfo
Write-Host ""

function Restore-OnePackage([string]$Pkg) {
    # A package may have been disabled or uninstalled for user 0; running both
    # routes is harmless and covers either case.
    Invoke-Shell "cmd package install-existing $Pkg" | Out-Null
    Invoke-Shell "pm enable --user 0 $Pkg" | Out-Null
    $present = (Get-CymPackages "--user 0") -contains $Pkg
    if (-not $present) { return [pscustomobject]@{ Ok = $false; Reply = "not installed for this user" } }
    if ((Get-CymPackages "-d") -contains $Pkg) {
        return [pscustomobject]@{ Ok = $false; Reply = "installed but still disabled" }
    }
    return [pscustomobject]@{ Ok = $true; Reply = "restored" }
}

function Restore-Session([string]$Dir) {
    $file = Join-Path $Dir "removed_packages.txt"
    if (-not (Test-Path $file)) {
        Write-Warn "$(Split-Path -Leaf $Dir) has no removed_packages.txt - skipping."
        return
    }
    $list = @(Get-Content $file | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list.Count -eq 0) {
        Write-Host " $(Split-Path -Leaf $Dir): nothing recorded."
        return
    }
    Write-Step ("{0} - {1} package(s)" -f (Split-Path -Leaf $Dir), $list.Count)
    $done = 0; $failed = 0; $n = 0
    foreach ($pkg in $list) {
        $n++
        Write-Host ("  [{0}/{1}] {2,-48} " -f $n, $list.Count, $pkg) -NoNewline
        $result = Restore-OnePackage $pkg
        if ($result.Ok) {
            Write-Host "ok" -ForegroundColor Green
            $done++
        } else {
            Write-Host "failed " -ForegroundColor Red -NoNewline
            Write-Host $result.Reply
            $failed++
        }
    }
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Add-Content -Path (Join-Path $Dir "debloat.log") -Value "$stamp RESTORED ok=$done failed=$failed" -Encoding utf8
    Write-Host ""
    Write-Host (" Restored : {0}" -f $done)
    Write-Host (" Failed   : {0}" -f $failed)
    if ($failed -gt 0) {
        Write-Host ""
        Write-Warn "Some packages did not come back."
        Write-Host "   Reboot and run this again: a package the system is holding open"
        Write-Host "   often restores on the second try. A factory reset brings back"
        Write-Host "   every system package as a last resort."
    }
}

if ($Package) {
    Write-Host ("  {0,-52} " -f $Package) -NoNewline
    $result = Restore-OnePackage $Package
    if ($result.Ok) {
        Write-Host "ok" -ForegroundColor Green
    } else {
        Write-Host "failed " -ForegroundColor Red -NoNewline
        Write-Host $result.Reply
        exit 1
    }
} elseif ($All) {
    $dirs = @(Get-ChildItem $script:CymBackupRoot -Directory -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime)
    if ($dirs.Count -eq 0) { Stop-Cym "No sessions found in $($script:CymBackupRoot)" }
    foreach ($d in $dirs) { Restore-Session $d.FullName; Write-Host "" }
} elseif ($Path) {
    if (-not (Test-Path $Path)) { Stop-Cym "Not a directory: $Path" }
    Restore-Session (Resolve-Path $Path).Path
} else {
    $latest = Get-LatestSession
    if (-not $latest) { Stop-Cym "No session found. Pass a directory, or use -List." }
    Restore-Session $latest
}

Write-Host ""
Write-Rule
Write-Ok "Done. Reboot the phone so the restored apps register properly."
Write-Host "   adb reboot"
Write-Rule
