#!/usr/bin/env bash
# Clean Your Mobile - connect to a phone over USB or Wi-Fi
#
# Usage:
#   bash scripts/connect.sh                       # find a USB device, report it
#   bash scripts/connect.sh --wireless            # pair over Wi-Fi, interactive
#   bash scripts/connect.sh --wireless 192.168.1.42:37123 123456
#   bash scripts/connect.sh --from-usb            # switch a USB device to Wi-Fi
#   bash scripts/connect.sh --disconnect          # drop all Wi-Fi connections

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="usb"
PAIR_TARGET=""
PAIR_CODE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --wireless|-w) MODE="wireless"; shift
                       [ $# -gt 0 ] && [[ "$1" != --* ]] && { PAIR_TARGET="$1"; shift; }
                       [ $# -gt 0 ] && [[ "$1" != --* ]] && { PAIR_CODE="$1"; shift; } ;;
        --from-usb)    MODE="from-usb"; shift ;;
        --disconnect)  MODE="disconnect"; shift ;;
        -h|--help)     sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)             die "Unknown option: $1 (try --help)" ;;
    esac
done

banner "connect"
require_adb
info " adb: $ADB"
"$ADB" start-server >/dev/null 2>&1 || true

case "$MODE" in

disconnect)
    "$ADB" disconnect >/dev/null 2>&1 || true
    ok "Dropped every wireless connection. USB devices are untouched."
    ;;

wireless)
    # Android 11 and newer: Developer options > Wireless debugging > Pair with
    # pairing code. The pairing port is NOT the connect port; both are shown.
    if [ -z "$PAIR_TARGET" ]; then
        info ""
        info " On the phone: Settings > Developer options > Wireless debugging"
        info "               > Pair device with pairing code"
        info ""
        read -r -p " Pairing address shown on the phone (ip:port): " PAIR_TARGET
        read -r -p " Six-digit pairing code: " PAIR_CODE
    fi
    [ -z "$PAIR_TARGET" ] && die "No pairing address given."

    step "Pairing with $PAIR_TARGET"
    if ! "$ADB" pair "$PAIR_TARGET" "$PAIR_CODE" 2>&1 | tee /dev/stderr | grep -q "Successfully paired"; then
        err "Pairing failed."
        info "   - The pairing dialog must still be open; its port changes each time."
        info "   - The computer and the phone must be on the same Wi-Fi network."
        info "   - Some corporate and guest networks block device-to-device traffic."
        exit 1
    fi
    ok "Paired."

    PAIR_IP="${PAIR_TARGET%%:*}"
    info ""
    info " The Wireless debugging screen also shows a connect port, a different"
    info " number from the pairing port."
    read -r -p " Connect address (ip:port) [${PAIR_IP}:5555]: " CONNECT_TARGET
    CONNECT_TARGET="${CONNECT_TARGET:-${PAIR_IP}:5555}"

    step "Connecting to $CONNECT_TARGET"
    "$ADB" connect "$CONNECT_TARGET" || true
    ;;

from-usb)
    # A phone already trusted over USB can be flipped to TCP without pairing.
    # The port closes again on reboot.
    step "Reading the phone's Wi-Fi address over USB"
    IP="$("$ADB" shell ip -f inet addr show wlan0 2>/dev/null | tr -d '\r' \
          | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
    [ -z "$IP" ] && die "Could not read wlan0. Is the phone on Wi-Fi and connected over USB?"
    ok "Phone is at $IP"
    step "Opening ADB on port 5555"
    "$ADB" tcpip 5555 >/dev/null 2>&1 || true
    sleep 2
    "$ADB" connect "$IP:5555" || true
    info ""
    warn "Port 5555 stays open until the phone reboots. Unplug the cable now if you like."
    ;;

usb)
    step "Looking for a device"
    ;;
esac

info ""
if require_device; then
    hr
    describe_device
    hr
    ok "Ready. Next: bash scripts/snapshot.sh before"
fi
