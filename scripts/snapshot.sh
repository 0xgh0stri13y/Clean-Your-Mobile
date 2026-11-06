#!/usr/bin/env bash
# Clean Your Mobile - system snapshot
#
# Measures the phone and writes the numbers into the current session directory,
# so that `before` and `after` always land side by side and tools/report.py can
# find the pair. Writes both a readable .txt and a machine-readable .json.
#
# Usage:
#   bash scripts/snapshot.sh before
#   bash scripts/snapshot.sh after
#   CYM_SESSION=<name|path> bash scripts/snapshot.sh after   # target a session

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASE="${1:-before}"
case "$PHASE" in
    before|after) ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "Phase must be 'before' or 'after', not '$PHASE'." ;;
esac

banner "snapshot ($PHASE)"
require_device
describe_device

# `before` starts (or reuses) a session; `after` must attach to an existing one.
if [ "$PHASE" = "before" ]; then
    SESSION="$(session_dir)"
else
    SESSION="$(resume_or_new_session)"
    if [ ! -f "$SESSION/snapshot_before.txt" ]; then
        die "No before snapshot in ${SESSION:-<none>}. Run the before snapshot first, or set CYM_SESSION."
    fi
fi
init_session "$SESSION"
hr
info " Session : $SESSION"
hr

TXT="$SESSION/snapshot_${PHASE}.txt"
JSON="$SESSION/snapshot_${PHASE}.json"

# ------------------------------------------------------------- collectors ----
# Every collector degrades to an empty value rather than failing the run:
# OEM ROMs withhold different parts of dumpsys, and a missing number is better
# than a dead script.

num() { # keep digits only, default 0
    local v; v="$(tr -cd '0-9' <<< "${1:-}")"
    printf '%s' "${v:-0}"
}

# `grep -c` prints 0 AND exits 1 when nothing matches, so `|| printf 0` would
# append a second zero and produce "00". Swallow the status instead.
count() { grep -c "$@" || true; }
counte() { grep -cE "$@" || true; }

count_packages() { # count_packages [pm flags...]
    num "$(sh_ "pm list packages $*" 2>/dev/null | count '^package:')"
}

step "Packages"
PKG_TOTAL="$(count_packages)"
PKG_SYSTEM="$(count_packages -s)"
PKG_USER="$(count_packages -3)"
PKG_DISABLED="$(count_packages -d)"
PKG_ENABLED="$(count_packages -e)"
ok "$PKG_TOTAL installed, $PKG_DISABLED disabled"

step "Memory"
MEM_TOTAL_KB="$(num "$(sh_ "grep MemTotal /proc/meminfo"     | awk '{print $2}')")"
MEM_AVAIL_KB="$(num "$(sh_ "grep MemAvailable /proc/meminfo" | awk '{print $2}')")"
MEM_FREE_KB="$(num  "$(sh_ "grep ^MemFree /proc/meminfo"     | awk '{print $2}')")"
MEM_CACHED_KB="$(num "$(sh_ "grep ^Cached /proc/meminfo"     | awk '{print $2}')")"
MEM_USED_KB=$(( MEM_TOTAL_KB > MEM_AVAIL_KB ? MEM_TOTAL_KB - MEM_AVAIL_KB : 0 ))
ok "$(( MEM_AVAIL_KB / 1024 )) MB available of $(( MEM_TOTAL_KB / 1024 )) MB"

step "Storage"
# df output varies; take the /data row and read the 1K-blocks columns.
DF_LINE="$(sh_ "df /data" | awk 'NR>1 && $1 !~ /^Filesystem/ {print; exit}')"
DATA_TOTAL_KB="$(num "$(awk '{print $2}' <<< "$DF_LINE")")"
DATA_USED_KB="$(num  "$(awk '{print $3}' <<< "$DF_LINE")")"
DATA_FREE_KB="$(num  "$(awk '{print $4}' <<< "$DF_LINE")")"
ok "$(( DATA_FREE_KB / 1024 )) MB free on /data"

step "Battery"
BATT_DUMP="$(sh_ "dumpsys battery")"
BATT_LEVEL="$(num "$(grep -i '  level:' <<< "$BATT_DUMP" | awk '{print $2}')")"
BATT_TEMP_DECI="$(num "$(grep -i 'temperature:' <<< "$BATT_DUMP" | awk '{print $2}')")"
BATT_STATUS="$(grep -iE '^\s*status:' <<< "$BATT_DUMP" | awk '{print $2}' | head -1)"
ok "level ${BATT_LEVEL}%, $(awk -v t="$BATT_TEMP_DECI" 'BEGIN{printf "%.1f", t/10}')C"

step "Processes and services"
# dumpsys names the same process in several places - the LRU list, the known
# process list, and every connection record that points at it - so a plain
# grep -c counts one process many times. Measured on a OnePlus 10 Pro
# (Android 16), that inflated 131 processes to 439, which happened to equal the
# package count and looked plausible. Count distinct pid:name pairs instead.
PROC_DUMP="$(sh_ "dumpsys activity processes" 2>/dev/null)"
PROC_COUNT="$(num "$(printf '%s\n' "$PROC_DUMP" \
    | grep -oE 'ProcessRecord\{[0-9a-f]+ [0-9]+:[^}]+\}' \
    | sed -E 's/ProcessRecord\{[0-9a-f]+ //' | sort -u | count .)")"
# Cached processes carry the state "cch" or "cch+" in the ranked process list.
# That list is printed twice - once in the main section and again under
# "Process LRU list" - and the row label differs by Android version (Proc, APP,
# PERS), so match any of them and dedupe by pid.
BG_COUNT="$(num "$(printf '%s\n' "$PROC_DUMP" \
    | grep -E '^[[:space:]]+(Proc|APP|PERS) #[[:space:]]*[0-9]+:[[:space:]]+cch' \
    | grep -oE '[0-9]+:[a-zA-Z][^ ]*' | sort -u | count .)")"
# A service is declared once, on a line beginning "* ServiceRecord{".
SVC_COUNT="$(num "$(sh_ "dumpsys activity services" 2>/dev/null \
    | counte '^[[:space:]]+\* ServiceRecord\{')")"
ok "$PROC_COUNT app processes, $SVC_COUNT services, $BG_COUNT cached"

step "Permission holders"
# One dumpsys read, counted several ways: much faster than four passes.
PERM_DUMP="$(sh_ "dumpsys package packages" 2>/dev/null | grep -E 'android\.permission\.(ACCESS_FINE_LOCATION|CAMERA|RECORD_AUDIO|READ_CONTACTS|READ_SMS|READ_PHONE_STATE).*granted=true' || true)"
perm_count() { num "$(count "android.permission.$1" <<< "$PERM_DUMP")"; }
PERM_LOC="$(perm_count ACCESS_FINE_LOCATION)"
PERM_CAM="$(perm_count CAMERA)"
PERM_MIC="$(perm_count RECORD_AUDIO)"
PERM_CON="$(perm_count READ_CONTACTS)"
PERM_SMS="$(perm_count READ_SMS)"
PERM_TEL="$(perm_count READ_PHONE_STATE)"
ok "location $PERM_LOC, camera $PERM_CAM, mic $PERM_MIC, contacts $PERM_CON"

step "Launcher and animation"
HOME_PKG="$(sh_ "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME" | tail -1 | cut -d/ -f1)"
ANIM_WIN="$(sh_ "settings get global window_animation_scale"     | tr -d '\r\n')"
ANIM_TRANS="$(sh_ "settings get global transition_animation_scale" | tr -d '\r\n')"
ANIM_DUR="$(sh_ "settings get global animator_duration_scale"      | tr -d '\r\n')"

# ------------------------------------------------------------ package list ----
# Saved on both phases: the after list is what tools/report.py diffs against,
# and the before list is the record a restore is rebuilt from.
step "Saving package lists"
sh_ "pm list packages -f" | sed 's/^package://' > "$SESSION/packages_${PHASE}_full.txt"
sh_ "pm list packages"    | sed 's/^package://' | sort > "$SESSION/packages_${PHASE}.txt"
sh_ "pm list packages -d" | sed 's/^package://' | sort > "$SESSION/packages_${PHASE}_disabled.txt"
sh_ "pm list packages -3" | sed 's/^package://' | sort > "$SESSION/packages_${PHASE}_user.txt"
sh_ "pm list packages -s" | sed 's/^package://' | sort > "$SESSION/packages_${PHASE}_system.txt"
ok "$(wc -l < "$SESSION/packages_${PHASE}.txt" | tr -d ' ') names recorded"

# ----------------------------------------------------------------- output ----
MB() { awk -v k="${1:-0}" 'BEGIN{printf "%.0f", k/1024}'; }

{
    printf 'CLEAN YOUR MOBILE - %s SNAPSHOT\n' "$(tr '[:lower:]' '[:upper:]' <<< "$PHASE")"
    printf 'Taken        : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Device       : %s %s (%s)\n' "$DEV_BRAND" "$DEV_MODEL" "$DEV_DEVICE"
    printf 'Android      : %s (API %s)\n' "$DEV_ANDROID" "$DEV_SDK"
    printf 'Build        : %s\n' "$DEV_BUILD"
    printf 'Patch level  : %s\n' "${DEV_SECPATCH:-unknown}"
    printf '\n'
    printf 'Total packages      : %s\n' "$PKG_TOTAL"
    printf 'System packages     : %s\n' "$PKG_SYSTEM"
    printf 'User packages       : %s\n' "$PKG_USER"
    printf 'Enabled packages    : %s\n' "$PKG_ENABLED"
    printf 'Disabled packages   : %s\n' "$PKG_DISABLED"
    printf '\n'
    printf 'RAM total MB        : %s\n' "$(MB "$MEM_TOTAL_KB")"
    printf 'RAM available MB    : %s\n' "$(MB "$MEM_AVAIL_KB")"
    printf 'RAM used MB         : %s\n' "$(MB "$MEM_USED_KB")"
    printf 'RAM free MB         : %s\n' "$(MB "$MEM_FREE_KB")"
    printf 'RAM cached MB       : %s\n' "$(MB "$MEM_CACHED_KB")"
    printf '\n'
    printf 'Data total MB       : %s\n' "$(MB "$DATA_TOTAL_KB")"
    printf 'Data used MB        : %s\n' "$(MB "$DATA_USED_KB")"
    printf 'Data free MB        : %s\n' "$(MB "$DATA_FREE_KB")"
    printf '\n'
    printf 'Battery level       : %s\n' "$BATT_LEVEL"
    printf 'Battery temp C      : %s\n' "$(awk -v t="$BATT_TEMP_DECI" 'BEGIN{printf "%.1f", t/10}')"
    printf 'Battery status      : %s\n' "${BATT_STATUS:-unknown}"
    printf '\n'
    printf 'Running processes   : %s\n' "$PROC_COUNT"
    printf 'Running services    : %s\n' "$SVC_COUNT"
    printf 'Cached processes    : %s\n' "$BG_COUNT"
    printf '\n'
    printf 'Location access     : %s\n' "$PERM_LOC"
    printf 'Camera access       : %s\n' "$PERM_CAM"
    printf 'Microphone access   : %s\n' "$PERM_MIC"
    printf 'Contacts access     : %s\n' "$PERM_CON"
    printf 'SMS access          : %s\n' "$PERM_SMS"
    printf 'Phone state access  : %s\n' "$PERM_TEL"
    printf '\n'
    printf 'Home launcher       : %s\n' "${HOME_PKG:-unknown}"
    printf 'Animation scales    : window %s / transition %s / animator %s\n' \
        "${ANIM_WIN:-null}" "${ANIM_TRANS:-null}" "${ANIM_DUR:-null}"
} > "$TXT"

cat > "$JSON" <<JSON
{
  "phase": "$PHASE",
  "taken": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "device": {
    "brand": "$DEV_BRAND",
    "model": "$DEV_MODEL",
    "device": "$DEV_DEVICE",
    "android": "$DEV_ANDROID",
    "sdk": "$DEV_SDK",
    "build": "$DEV_BUILD",
    "security_patch": "${DEV_SECPATCH:-}"
  },
  "packages": {
    "total": $PKG_TOTAL,
    "system": $PKG_SYSTEM,
    "user": $PKG_USER,
    "enabled": $PKG_ENABLED,
    "disabled": $PKG_DISABLED
  },
  "memory_kb": {
    "total": $MEM_TOTAL_KB,
    "available": $MEM_AVAIL_KB,
    "used": $MEM_USED_KB,
    "free": $MEM_FREE_KB,
    "cached": $MEM_CACHED_KB
  },
  "storage_kb": {
    "data_total": $DATA_TOTAL_KB,
    "data_used": $DATA_USED_KB,
    "data_free": $DATA_FREE_KB
  },
  "battery": {
    "level": $BATT_LEVEL,
    "temperature_c": $(awk -v t="$BATT_TEMP_DECI" 'BEGIN{printf "%.1f", t/10}'),
    "status": "${BATT_STATUS:-unknown}"
  },
  "runtime": {
    "processes": $PROC_COUNT,
    "services": $SVC_COUNT,
    "cached_processes": $BG_COUNT
  },
  "permissions": {
    "location": $PERM_LOC,
    "camera": $PERM_CAM,
    "microphone": $PERM_MIC,
    "contacts": $PERM_CON,
    "sms": $PERM_SMS,
    "phone_state": $PERM_TEL
  },
  "home_launcher": "${HOME_PKG:-unknown}",
  "animation": {
    "window": "${ANIM_WIN:-null}",
    "transition": "${ANIM_TRANS:-null}",
    "animator": "${ANIM_DUR:-null}"
  }
}
JSON

info ""
hr
ok "Snapshot written"
info "   $TXT"
info "   $JSON"
hr
if [ "$PHASE" = "before" ]; then
    info " Next: python tools/scan.py --session \"$SESSION\""
else
    info " Next: python tools/report.py --session \"$SESSION\""
fi
