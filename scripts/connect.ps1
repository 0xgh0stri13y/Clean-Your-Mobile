# Clean Your Mobile - connect to a phone over USB or Wi-Fi (Windows)
#
#   powershell -ExecutionPolicy Bypass -File scripts\connect.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\connect.ps1 -Wireless
#   powershell -ExecutionPolicy Bypass -File scripts\connect.ps1 -Wireless -PairTarget 192.168.1.42:37123 -PairCode 123456
#   powershell -ExecutionPolicy Bypass -File scripts\connect.ps1 -FromUsb
#   powershell -ExecutionPolicy Bypass -File scripts\connect.ps1 -Disconnect

[CmdletBinding()]
param(
    [switch]$Wireless,
    [switch]$FromUsb,
    [switch]$Disconnect,
    [string]$PairTarget,
    [string]$PairCode
)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

Write-Banner "connect"
Initialize-Adb
Write-Host " adb: $($script:Adb)"
& $script:Adb start-server 2>$null | Out-Null

if ($Disconnect) {
    & $script:Adb disconnect 2>$null | Out-Null
    Write-Ok "Dropped every wireless connection. USB devices are untouched."
    exit 0
}

if ($Wireless) {
    if (-not $PairTarget) {
        Write-Host ""
        Write-Host " On the phone: Settings > Developer options > Wireless debugging"
        Write-Host "               > Pair device with pairing code"
        Write-Host ""
        $PairTarget = Read-Host " Pairing address shown on the phone (ip:port)"
        $PairCode = Read-Host " Six-digit pairing code"
    }
    if (-not $PairTarget) { Stop-Cym "No pairing address given." }

    Write-Step "Pairing with $PairTarget"
    $pairOut = & $script:Adb pair $PairTarget $PairCode 2>$null
    $pairText = ($pairOut -join "`n")
    Write-Host $pairText
    if ($pairText -notmatch "Successfully paired") {
        Write-Fail "Pairing failed."
        Write-Host "   - The pairing dialog must still be open; its port changes each time."
        Write-Host "   - The computer and the phone must be on the same Wi-Fi network."
        Write-Host "   - Some corporate and guest networks block device-to-device traffic."
        exit 1
    }
    Write-Ok "Paired."

    $pairIp = ($PairTarget -split ":")[0]
    Write-Host ""
    Write-Host " The Wireless debugging screen also shows a connect port, a different"
    Write-Host " number from the pairing port."
    $connectTarget = Read-Host " Connect address (ip:port) [$pairIp`:5555]"
    if (-not $connectTarget) { $connectTarget = "$pairIp`:5555" }

    Write-Step "Connecting to $connectTarget"
    & $script:Adb connect $connectTarget
} elseif ($FromUsb) {
    Write-Step "Reading the phone's Wi-Fi address over USB"
    $addr = & $script:Adb shell ip -f inet addr show wlan0 2>$null
    $ip = $null
    if ($addr) {
        $m = [regex]::Match(($addr -join "`n"), "inet\s+([0-9.]+)")
        if ($m.Success) { $ip = $m.Groups[1].Value }
    }
    if (-not $ip) { Stop-Cym "Could not read wlan0. Is the phone on Wi-Fi and connected over USB?" }
    Write-Ok "Phone is at $ip"
    Write-Step "Opening ADB on port 5555"
    & $script:Adb tcpip 5555 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $script:Adb connect "$ip`:5555"
    Write-Host ""
    Write-Warn "Port 5555 stays open until the phone reboots. Unplug the cable now if you like."
} else {
    Write-Step "Looking for a device"
}

Write-Host ""
Assert-Device | Out-Null
Write-Rule
Write-DeviceInfo
Write-Rule
Write-Ok "Ready. Next: powershell -ExecutionPolicy Bypass -File scripts\snapshot.ps1 before"
