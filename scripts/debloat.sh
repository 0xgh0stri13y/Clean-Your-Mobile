#!/usr/bin/env bash
# Clean Your Mobile - apply a removal list
#
# Reads a plan file (one package per line, # comments allowed), refuses
# anything on the never-touch list, works in batches of five with a health
# check between them, and writes a restore record as it goes.
#
# Usage:
#   bash scripts/debloat.sh <plan-file> [options]
#
# Options:
#   --dry-run           Decide everything, change nothing. Always do this first.
#   --disable           Use `pm disable-user` instead of `pm uninstall -k`.
#                       Slightly more conservative: the app stays installed.
#   --yes               Skip the confirmation prompt (for scripted runs).
#   --batch-size N      Packages per batch, 1 to 5 (default 5).
#   --session NAME      Write into a named session instead of the newest one.
#
# Every removal is reversible. Nothing here needs root.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN=""
DRY_RUN=0
METHOD="uninstall"
ASSUME_YES=0
BATCH_SIZE=5
MAX_CONSECUTIVE_FAILURES=3

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --disable)    METHOD="disable"; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --batch-size) BATCH_SIZE="${2:-5}"; shift 2 ;;
        --session)    CYM_SESSION="${2:-}"; export CYM_SESSION; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)           die "Unknown option: $1 (try --help)" ;;
        *)            PLAN="$1"; shift ;;
    esac
done

[ -z "$PLAN" ] && { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 1; }
[ -f "$PLAN" ] || die "Plan file not found: $PLAN"
case "$BATCH_SIZE" in
    [1-5]) ;;
    *) die "--batch-size must be 1 to 5 (the safety cap). Got: $BATCH_SIZE" ;;
esac

banner "debloat$([ "$DRY_RUN" = 1 ] && printf ' (dry run)')"
require_device
describe_device
load_essentials

# ---------------------------------------------------------- read the plan ----
# Blank lines and # comments are skipped. Duplicates are collapsed, keeping
# the first occurrence, so a hand-edited plan cannot run a package twice.
declare -a WANTED=()
declare -A SEEN=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(tr -d '\r' <<< "$line" | awk '{$1=$1};1')"
    [ -z "$line" ] && continue
    [ -n "${SEEN[$line]:-}" ] && continue
    SEEN[$line]=1
    WANTED+=("$line")
done < "$PLAN"

[ "${#WANTED[@]}" -eq 0 ] && die "No package names in $PLAN"

# ------------------------------------------------------------- the guard -----
# Three things are checked before anything is touched:
#   1. the never-touch list          -> refused, no override
#   2. a protected-category name     -> refused unless CYM_ALLOW_PROTECTED=1
#   3. actually installed right now  -> skipped, nothing to do
step "Checking the plan against the never-touch list"
INSTALLED="$(sh_ "pm list packages" | sed 's/^package://' | sort)"

declare -a QUEUE=() REFUSED=() ABSENT=()
for pkg in "${WANTED[@]}"; do
    if reason="$(block_reason "$pkg")"; then
        if grep -qxF "$pkg" <<< "$INSTALLED"; then
            QUEUE+=("$pkg")
        else
            ABSENT+=("$pkg")
        fi
    else
        REFUSED+=("$pkg|$reason")
    fi
done

info ""
printf ' In the plan        : %s\n' "${#WANTED[@]}"
printf ' Will be processed  : %s\n' "${#QUEUE[@]}"
printf ' Refused (protected): %s\n' "${#REFUSED[@]}"
printf ' Not installed      : %s\n' "${#ABSENT[@]}"

if [ "${#REFUSED[@]}" -gt 0 ]; then
    info ""
    err "Refused - these stay on the phone whatever the plan says:"
    for entry in "${REFUSED[@]}"; do
        printf '    %-52s %s\n' "${entry%%|*}" "${entry#*|}" >&2
    done
fi
if [ "${#ABSENT[@]}" -gt 0 ]; then
    info ""
    warn "Not installed on this phone, nothing to do:"
    printf '    %s\n' "${ABSENT[@]}" >&2
fi

[ "${#QUEUE[@]}" -eq 0 ] && { info ""; ok "Nothing left to do."; exit 0; }

# A launcher must still answer HOME afterwards, or the phone boots to nothing.
HOME_COUNT="$(home_resolver_count)"
if [ "${HOME_COUNT:-0}" -lt 1 ]; then
    warn "Could not confirm a launcher answers HOME. Proceeding carefully."
fi

# ------------------------------------------------------------- session -------
SESSION="$(resume_or_new_session)"
init_session "$SESSION"
LOG="$SESSION/debloat.log"
REMOVED_FILE="$SESSION/removed_packages.txt"
FAILED_FILE="$SESSION/failed_packages.txt"
RESTORE="$SESSION/restore.sh"
RESTORE_PS="$SESSION/restore.ps1"
# Only on a real run: a dry run must leave the session exactly as it found it.
# An empty removed_packages.txt is not harmless - it used to shadow plan.txt
# and make tools/check.py report the session as unusable.
[ "$DRY_RUN" = 0 ] && touch "$REMOVED_FILE" "$FAILED_FILE"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

info ""
hr
info " Session : $SESSION"
info " Method  : $([ "$METHOD" = disable ] && printf 'pm disable-user --user 0 (app stays installed)' || printf 'pm uninstall -k --user 0 (data kept, system copy kept)')"
info " Batches : ${#QUEUE[@]} packages, $BATCH_SIZE per batch, health check after each"
hr

# ---------------------------------------------------- restore record first ----
# Rule 4 of AGENTS.md: the restore script exists before the first removal, not
# after the last one. If the run dies halfway, the record still works.
write_restore_headers() {
    cat > "$RESTORE" <<'SH'
#!/usr/bin/env bash
# Clean Your Mobile - restore script (generated)
# Puts back everything this session removed. Safe to run more than once.
set -uo pipefail
ADB="${ADB_BINARY:-adb}"
run() { if [ -n "${ANDROID_SERIAL:-}" ]; then "$ADB" -s "$ANDROID_SERIAL" "$@"; else "$ADB" "$@"; fi; }
fail=0
SH
    {
        printf '\n# Device: %s %s, Android %s, build %s\n' "$DEV_BRAND" "$DEV_MODEL" "$DEV_ANDROID" "$DEV_BUILD"
        printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'echo "Restoring packages removed from %s %s..."\n\n' "$DEV_BRAND" "$DEV_MODEL"
    } >> "$RESTORE"
    chmod +x "$RESTORE" 2>/dev/null || true

    {
        printf '# Clean Your Mobile - restore script (generated)\n'
        printf '# Device: %s %s, Android %s\n' "$DEV_BRAND" "$DEV_MODEL" "$DEV_ANDROID"
        printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '$ErrorActionPreference = "Continue"\n'
        printf '$adb = if ($env:ADB_BINARY) { $env:ADB_BINARY } else { "adb" }\n'
        printf '$fail = 0\n\n'
    } > "$RESTORE_PS"
}

# One line per package, appended the moment that package comes off.
record_restore() {
    local pkg="$1"
    if [ "$METHOD" = "disable" ]; then
        printf 'echo "  %s"; run shell pm enable --user 0 %s >/dev/null || fail=$((fail+1))\n' "$pkg" "$pkg" >> "$RESTORE"
        printf 'Write-Host "  %s"; & $adb shell pm enable --user 0 %s | Out-Null; if ($LASTEXITCODE -ne 0) { $fail++ }\n' "$pkg" "$pkg" >> "$RESTORE_PS"
    else
        printf 'echo "  %s"; run shell cmd package install-existing %s >/dev/null || fail=$((fail+1))\n' "$pkg" "$pkg" >> "$RESTORE"
        printf 'Write-Host "  %s"; & $adb shell cmd package install-existing %s | Out-Null; if ($LASTEXITCODE -ne 0) { $fail++ }\n' "$pkg" "$pkg" >> "$RESTORE_PS"
    fi
}

finish_restore() {
    cat >> "$RESTORE" <<'SH'

echo ""
if [ "$fail" -eq 0 ]; then
    echo "Restore complete. Reboot the phone to be sure everything comes back."
else
    echo "$fail package(s) would not restore."
    echo "Try again after a reboot; a factory reset brings back every system package."
fi
SH
    {
        printf '\nWrite-Host ""\n'
        printf 'if ($fail -eq 0) { Write-Host "Restore complete. Reboot the phone." }\n'
        printf 'else { Write-Host "$fail package(s) would not restore. Try again after a reboot." }\n'
    } >> "$RESTORE_PS"
}

if [ "$DRY_RUN" = 0 ]; then
    write_restore_headers
    log "SESSION start method=$METHOD queue=${#QUEUE[@]} plan=$PLAN"
fi

# -------------------------------------------------------------- confirm ------
if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    info ""
    info " About to process ${#QUEUE[@]} package(s):"
    printf '    %s\n' "${QUEUE[@]}" | head -60
    [ "${#QUEUE[@]}" -gt 60 ] && info "    ... and $(( ${#QUEUE[@]} - 60 )) more"
    info ""
    read -r -p " Type YES to continue, anything else to stop: " answer
    [ "$answer" = "YES" ] || { info " Stopped. Nothing was changed."; exit 0; }
fi

# ----------------------------------------------------------- the removal -----
# Why `2>&1` inside the device shell: pm writes its refusals to stderr, and the
# adb wrapper discards stderr to keep adb's own noise out of the output. The
# redirect happens on the phone, so the real reason travels back on stdout.
# Without it, every vendor refusal was reported as "no reply" - which is how a
# Funtouch ROM blocking a package looked identical to a dropped connection.
explain_failure() { # turn a pm error into something a person can act on
    local reply="$1"
    case "$reply" in
        *"SecurityException"*"no root permission"*)
            printf 'blocked by the vendor ROM (would need root, which this project will not use)' ;;
        *"change component state"*)
            # ColorOS, realme UI and OxygenOS refuse a disable with
            # "Permission Denial: attempt to change component state"; some ROMs
            # word it "Shell cannot change component state". Same wall either
            # way, and it used to fall through and print a raw Java exception.
            printf 'the ROM will not let a shell change this package - vendor-protected, and no tool gets past it without root' ;;
        *"DELETE_FAILED_INTERNAL_ERROR"*)
            printf 'ROM refused the uninstall - try --disable, or check Settings > Security > Device admin apps' ;;
        *"DELETE_FAILED_DEVICE_POLICY_MANAGER"*)
            printf 'a device policy or work profile owns this package' ;;
        *"not installed for"*)
            printf 'not installed for this user - nothing to do' ;;
        *"Unknown package"*)
            printf 'the phone does not know this package name' ;;
        "")
            printf 'no reply from the phone - the connection may have dropped' ;;
        *)  # First meaningful line only; a Java stack trace is 15 lines of noise.
            printf '%s' "$(printf '%s' "$reply" | sed 's/[[:space:]]*at [a-zA-Z0-9_.$]*(.*//' \
                   | cut -c1-120)" ;;
    esac
}

remove_one() { # remove_one <pkg> -> prints the device's reply, returns 0 on success
    local pkg="$1" reply
    if [ "$METHOD" = "disable" ]; then
        reply="$(sh_ "pm disable-user --user 0 $pkg 2>&1" | tr -d '\r' | tr '\n' ' ')"
        [[ "$reply" == *"new state: disabled-user"* ]] && { printf '%s' "$reply"; return 0; }
    else
        reply="$(sh_ "pm uninstall -k --user 0 $pkg 2>&1" | tr -d '\r' | tr '\n' ' ')"
        [[ "$reply" == *"Success"* ]] && { printf '%s' "$reply"; return 0; }
    fi
    # Full reply goes to the log; the caller prints the short explanation.
    CYM_LAST_RAW_REPLY="$reply"
    explain_failure "$reply"
    return 1
}

verify_gone() { # the package must no longer be enabled for user 0
    local pkg="$1"
    if [ "$METHOD" = "disable" ]; then
        sh_ "pm list packages -d" | grep -qxF "package:$pkg"
    else
        ! sh_ "pm list packages --user 0" | grep -qxF "package:$pkg"
    fi
}

TOTAL="${#QUEUE[@]}"
TOTAL_BATCHES=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))
DONE=0; FAILED=0; CONSECUTIVE=0; ABORTED=0

for (( i=0; i<TOTAL; i++ )); do
    pkg="${QUEUE[$i]}"

    if (( i % BATCH_SIZE == 0 )); then
        info ""
        step "Batch $(( i / BATCH_SIZE + 1 )) of $TOTAL_BATCHES"
    fi

    printf '  [%*d/%d] %-48s ' "${#TOTAL}" "$(( i + 1 ))" "$TOTAL" "$pkg"

    if [ "$DRY_RUN" = 1 ]; then
        printf '%swould %s%s\n' "$C_DIM" "$METHOD" "$C_RESET"
        DONE=$(( DONE + 1 ))
        continue
    fi

    if reply="$(remove_one "$pkg")"; then
        if verify_gone "$pkg"; then
            printf '%sok%s\n' "$C_GREEN" "$C_RESET"
            printf '%s\n' "$pkg" >> "$REMOVED_FILE"
            record_restore "$pkg"
            log "REMOVED $pkg"
            DONE=$(( DONE + 1 ))
            CONSECUTIVE=0
        else
            # The command said yes and the phone says otherwise. Record it for
            # restore anyway: a half-applied change is the dangerous one.
            printf '%sunverified%s\n' "$C_YELLOW" "$C_RESET"
            printf '%s\n' "$pkg" >> "$REMOVED_FILE"
            record_restore "$pkg"
            log "UNVERIFIED $pkg reply=$reply"
            DONE=$(( DONE + 1 ))
            CONSECUTIVE=0
        fi
    else
        printf '%sfailed%s %s\n' "$C_RED" "$C_RESET" "$reply"
        printf '%s\t%s\n' "$pkg" "$reply" >> "$FAILED_FILE"
        # The short explanation goes on screen and in failed_packages.txt; the
        # phone's full reply, stack trace and all, goes in the log.
        log "FAILED $pkg explanation=$reply raw=${CYM_LAST_RAW_REPLY:-}"
        FAILED=$(( FAILED + 1 ))
        CONSECUTIVE=$(( CONSECUTIVE + 1 ))
        if [ "$CONSECUTIVE" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            info ""
            err "$CONSECUTIVE removals failed in a row. Stopping here."
            info " Common causes: the package is protected by the ROM, a work"
            info " profile owns it, or the ADB connection dropped."
            ABORTED=1
            break
        fi
    fi

    # Health check at the end of each batch and at the end of the run.
    if (( (i + 1) % BATCH_SIZE == 0 )) || (( i == TOTAL - 1 )); then
        [ "$DRY_RUN" = 1 ] && continue
        printf '  %shealth check%s ' "$C_DIM" "$C_RESET"
        if health_check; then
            printf '%sphone responsive%s\n' "$C_GREEN" "$C_RESET"
            log "HEALTH ok after $(( i + 1 ))"
        else
            printf '%sno answer%s\n' "$C_RED" "$C_RESET"
            info ""
            err "The phone stopped answering after this batch. Stopping."
            log "HEALTH failed after $(( i + 1 ))"
            info ""
            info " Attempting to restore this batch..."
            batch_start=$(( i - (i % BATCH_SIZE) ))
            for (( j=batch_start; j<=i; j++ )); do
                p="${QUEUE[$j]}"
                grep -qxF "$p" "$REMOVED_FILE" || continue
                printf '    %s ... ' "$p"
                if [ "$METHOD" = "disable" ]; then
                    sh_ "pm enable --user 0 $p" >/dev/null 2>&1 && printf 'back\n' || printf 'no answer\n'
                else
                    sh_ "cmd package install-existing $p" >/dev/null 2>&1 && printf 'back\n' || printf 'no answer\n'
                fi
            done
            info ""
            info " If the phone is still unresponsive, see docs/TROUBLESHOOTING.md"
            info " (hold power 10-20 seconds to reboot; a reboot alone fixes most of this)."
            ABORTED=1
            break
        fi
    fi
done

[ "$DRY_RUN" = 0 ] && finish_restore

# A launcher must still own HOME.
if [ "$DRY_RUN" = 0 ]; then
    AFTER_HOME="$(home_resolver_count)"
    if [ "${AFTER_HOME:-0}" -lt 1 ]; then
        info ""
        err "Nothing answers HOME any more. Restoring the launcher now."
        sh_ "cmd package install-existing $(sh_ 'pm list packages' | grep -i launcher | head -1 | cut -d: -f2)" >/dev/null 2>&1 || true
        info " Run: bash $RESTORE"
    fi
fi

# ----------------------------------------------------------------- summary ---
info ""
hr
if [ "$DRY_RUN" = 1 ]; then
    printf ' %sDRY RUN%s - nothing on the phone was changed\n' "$C_BOLD" "$C_RESET"
    printf ' Would process : %s package(s)\n' "$DONE"
    printf ' Would refuse  : %s package(s)\n' "${#REFUSED[@]}"
    hr
    info " Re-run without --dry-run to apply it."
    exit 0
fi
printf ' %sResult%s\n' "$C_BOLD" "$C_RESET"
printf ' Processed : %s\n' "$DONE"
printf ' Failed    : %s\n' "$FAILED"
printf ' Refused   : %s\n' "${#REFUSED[@]}"
[ "$ABORTED" = 1 ] && printf ' %sRun stopped early - %s package(s) in the plan were not reached%s\n' \
    "$C_YELLOW" "$(( TOTAL - DONE - FAILED ))" "$C_RESET"
hr
printf ' Restore   : bash %s\n' "$RESTORE"
printf '             powershell -File %s\n' "$RESTORE_PS"
printf ' Log       : %s\n' "$LOG"
hr
log "SESSION end processed=$DONE failed=$FAILED aborted=$ABORTED"
info ""
info " Next: adb reboot, then"
info "       bash scripts/snapshot.sh after"
info "       python tools/report.py --session \"$SESSION\""

[ "$ABORTED" = 1 ] && exit 2
exit 0
