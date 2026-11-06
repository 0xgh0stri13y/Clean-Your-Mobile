#!/usr/bin/env bash
# Clean Your Mobile - restore
#
# Puts back what a session removed. Three ways to use it:
#
#   bash scripts/restore.sh                       # the newest session
#   bash scripts/restore.sh backups/<session>     # a named session
#   bash scripts/restore.sh --all                 # every session, oldest first
#   bash scripts/restore.sh --package com.foo.bar # one package, no session
#   bash scripts/restore.sh --list                # what is on record
#
# This re-runs the restore from the session's own record rather than replaying
# a generated script, so it works even if that script was edited or lost.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="latest"
TARGET=""
SINGLE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --all)      MODE="all"; shift ;;
        --list)     MODE="list"; shift ;;
        --package)  MODE="single"; SINGLE="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)         die "Unknown option: $1 (try --help)" ;;
        *)          MODE="dir"; TARGET="$1"; shift ;;
    esac
done

banner "restore"

if [ "$MODE" = "list" ]; then
    found=0
    for dir in "$CYM_BACKUP_ROOT"/*/; do
        [ -d "$dir" ] || continue
        dir="${dir%/}"
        count=0
        [ -f "$dir/removed_packages.txt" ] && count="$(grep -c . "$dir/removed_packages.txt" || echo 0)"
        printf ' %-44s %3s package(s)\n' "$(basename "$dir")" "$count"
        found=1
    done
    [ "$found" = 0 ] && info " No sessions in $CYM_BACKUP_ROOT yet."
    exit 0
fi

require_device
describe_device
info ""

# restore_pkg <pkg> - try both routes; a package may have been disabled OR
# uninstalled for user 0, and running the wrong one is harmless.
restore_pkg() {
    local pkg="$1" a b
    a="$(sh_ "cmd package install-existing $pkg" | tr -d '\r\n')"
    b="$(sh_ "pm enable --user 0 $pkg"            | tr -d '\r\n')"
    # Installed and enabled for this user is the only outcome that counts.
    if sh_ "pm list packages --user 0" | grep -qxF "package:$pkg"; then
        if sh_ "pm list packages -d" | grep -qxF "package:$pkg"; then
            printf 'installed but still disabled'; return 1
        fi
        printf 'restored'; return 0
    fi
    printf '%s' "${a:-$b}"
    return 1
}

restore_session() {
    local dir="$1" list="$1/removed_packages.txt"
    if [ ! -f "$list" ]; then
        warn "$(basename "$dir") has no removed_packages.txt - skipping."
        return 0
    fi
    local total done_ failed
    total="$(grep -c . "$list" || echo 0)"
    [ "$total" = 0 ] && { info " $(basename "$dir"): nothing recorded."; return 0; }

    step "$(basename "$dir") - $total package(s)"
    done_=0; failed=0
    local n=0
    while IFS= read -r pkg; do
        pkg="$(tr -d '\r' <<< "$pkg" | awk '{$1=$1};1')"
        [ -z "$pkg" ] && continue
        n=$(( n + 1 ))
        printf '  [%d/%s] %-48s ' "$n" "$total" "$pkg"
        if reply="$(restore_pkg "$pkg")"; then
            printf '%sok%s\n' "$C_GREEN" "$C_RESET"
            done_=$(( done_ + 1 ))
        else
            printf '%sfailed%s %s\n' "$C_RED" "$C_RESET" "$reply"
            failed=$(( failed + 1 ))
        fi
    done < "$list"

    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) RESTORED ok=$done_ failed=$failed" >> "$dir/debloat.log"
    info ""
    printf ' Restored : %s\n' "$done_"
    printf ' Failed   : %s\n' "$failed"
    if [ "$failed" -gt 0 ]; then
        info ""
        warn "Some packages did not come back."
        info "   Reboot and run this again: a package the system is holding open"
        info "   often restores on the second try. A factory reset brings back"
        info "   every system package as a last resort."
    fi
    RESTORE_TOTAL_OK=$(( ${RESTORE_TOTAL_OK:-0} + done_ ))
    RESTORE_TOTAL_FAIL=$(( ${RESTORE_TOTAL_FAIL:-0} + failed ))
}

case "$MODE" in
single)
    [ -z "$SINGLE" ] && die "--package needs a package name."
    printf ' %-52s ' "$SINGLE"
    if reply="$(restore_pkg "$SINGLE")"; then
        printf '%sok%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '%sfailed%s %s\n' "$C_RED" "$C_RESET" "$reply"
        exit 1
    fi
    ;;
dir)
    [ -d "$TARGET" ] || die "Not a directory: $TARGET"
    restore_session "$TARGET"
    ;;
all)
    any=0
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        restore_session "$dir"; info ""; any=1
    done < <(ls -1dt "$CYM_BACKUP_ROOT"/*/ 2>/dev/null | sed 's#/$##' | tac)
    [ "$any" = 0 ] && die "No sessions found in $CYM_BACKUP_ROOT"
    ;;
latest)
    LATEST="$(latest_session)"
    [ -z "$LATEST" ] && die "No session found. Pass a directory, or use --list."
    restore_session "$LATEST"
    ;;
esac

info ""
hr
ok "Done. Reboot the phone so the restored apps register properly."
info "   adb reboot"
hr
