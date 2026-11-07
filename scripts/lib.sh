#!/usr/bin/env bash
# Clean Your Mobile - shared shell library
# Sourced by every script in scripts/. Not meant to be run directly.
#
# Provides: colours, logging, an adb wrapper with device selection,
# session directories, and the essential-package guard.

# ---------------------------------------------------------------- colours ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m';   C_BOLD=$'\033[1m';     C_DIM=$'\033[2m'
    C_RED=$'\033[0;31m';  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'
else
    C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW= C_CYAN=
fi

RULE="------------------------------------------------------------"

info()  { printf '%s\n' "$*"; }
step()  { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
ok()    { printf '%s  ok  %s%s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s warn %s%s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s fail %s%s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf '%s%s%s\n' "$C_DIM" "$RULE" "$C_RESET"; }

banner() {
    hr
    printf ' %sClean Your Mobile%s - %s\n' "$C_BOLD" "$C_RESET" "$1"
    hr
}

# ------------------------------------------------------------------ paths ----
# On Git Bash and MSYS, `pwd` gives /e/Clean Your Mobile, which the Windows
# Python tools cannot open. Paths that cross between the two - the session
# pointer above all - are written in native form.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

CYM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYM_ROOT="$(native_path "$(cd "$CYM_LIB_DIR/.." && pwd)")"
CYM_DB_DIR="$CYM_ROOT/database"
CYM_BACKUP_ROOT="${CYM_BACKUP_ROOT:-$CYM_ROOT/backups}"

# -------------------------------------------------------------------- adb ----
# ADB_BINARY points at a specific adb; ANDROID_SERIAL picks a device when
# several are attached (the same variable the real adb honours).
ADB_BINARY="${ADB_BINARY:-adb}"

adb_path() {
    if command -v "$ADB_BINARY" >/dev/null 2>&1; then
        command -v "$ADB_BINARY"; return 0
    fi
    # An ADB_BINARY the caller set explicitly must not fall through to a
    # different adb found elsewhere: silently using the wrong binary is worse
    # than failing. Only the default "adb" falls back to the known locations.
    if [ -n "${ADB_BINARY:-}" ] && [ "$ADB_BINARY" != "adb" ]; then
        err "ADB_BINARY is set to '$ADB_BINARY', which is not executable."
        info "   Unset it to search the usual locations instead." >&2
        return 1
    fi
    local candidate
    for candidate in \
        "$HOME/platform-tools/adb" \
        "$HOME/platform-tools/adb.exe" \
        "$HOME/Android/Sdk/platform-tools/adb" \
        "$HOME/Library/Android/sdk/platform-tools/adb" \
        "${LOCALAPPDATA:-}/Android/Sdk/platform-tools/adb.exe" \
        "/usr/local/bin/adb" \
        "/opt/homebrew/bin/adb"
    do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

require_adb() {
    ADB="$(adb_path)" || die "adb not found. Run: bash scripts/setup_adb.sh"
}

# adb_raw <args...> - adb with the chosen serial, carriage returns stripped.
adb_raw() {
    if [ -n "${ANDROID_SERIAL:-}" ]; then
        "$ADB" -s "$ANDROID_SERIAL" "$@" 2>/dev/null | tr -d '\r'
    else
        "$ADB" "$@" 2>/dev/null | tr -d '\r'
    fi
}

# sh_ <args...> - one shell command on the device.
sh_() { adb_raw shell "$@"; }

prop() { sh_ getprop "$1" | tr -d '\r\n'; }

# Fail unless exactly one device is usable, then describe it.
require_device() {
    require_adb
    local lines serials count serial state
    lines="$("$ADB" devices | tr -d '\r' | tail -n +2 | grep -v '^[[:space:]]*$' || true)"
    [ -z "$lines" ] && die "No device found. Plug the phone in, or run: bash scripts/connect.sh"

    while IFS=$'\t' read -r serial state; do
        [ -z "$serial" ] && continue
        case "$state" in
            device) ;;
            unauthorized) warn "$serial is unauthorized - accept the Allow USB debugging prompt on the phone." ;;
            offline)      warn "$serial is offline - unplug and replug, or re-run scripts/connect.sh." ;;
            *)            warn "$serial is in state '$state'." ;;
        esac
    done <<< "$lines"

    serials="$(printf '%s\n' "$lines" | awk -F'\t' '$2=="device"{print $1}')"
    count="$(printf '%s\n' "$serials" | grep -c . || true)"

    if [ "$count" -eq 0 ]; then
        die "No device is ready. See the warnings above."
    elif [ "$count" -gt 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then
        err "More than one device is connected:"
        printf '%s\n' "$serials" | sed 's/^/    /' >&2
        die "Pick one: ANDROID_SERIAL=<serial> bash $0 ..."
    elif [ -z "${ANDROID_SERIAL:-}" ]; then
        ANDROID_SERIAL="$(printf '%s\n' "$serials" | head -1)"
        export ANDROID_SERIAL
    fi

    DEV_BRAND="$(prop ro.product.brand)"
    DEV_MODEL="$(prop ro.product.model)"
    DEV_DEVICE="$(prop ro.product.device)"
    DEV_ANDROID="$(prop ro.build.version.release)"
    DEV_SDK="$(prop ro.build.version.sdk)"
    DEV_BUILD="$(prop ro.build.display.id)"
    DEV_SECPATCH="$(prop ro.build.version.security_patch)"
    [ -z "$DEV_MODEL" ] && die "The device answered but reported no model. Is the screen unlocked?"
    return 0
}

describe_device() {
    printf ' Device  : %s %s (%s)\n' "${DEV_BRAND:-?}" "${DEV_MODEL:-?}" "${DEV_DEVICE:-?}"
    printf ' Android : %s (API %s), build %s\n' "${DEV_ANDROID:-?}" "${DEV_SDK:-?}" "${DEV_BUILD:-?}"
    printf ' Serial  : %s\n' "${ANDROID_SERIAL:-?}"
}

# Is the phone still answering? Sends HOME, then checks the package service,
# because a phone that cannot run `cmd package` cannot be restored either.
health_check() {
    sh_ input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    sleep 2
    local probe
    probe="$(sh_ echo cym_alive | tr -d '\r\n')"
    [ "$probe" = "cym_alive" ] || return 1
    sh_ cmd package list packages android >/dev/null 2>&1 || return 1
    return 0
}

# Does any launcher still answer HOME?
home_resolver_count() {
    sh_ "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | grep -c '/'" | tr -d '\r\n'
}

# --------------------------------------------------------------- sessions ----
# One session directory holds the before snapshot, the removal log, the restore
# script and the after snapshot, so the report can always find its pair.
#
#   CYM_SESSION=<name|path>   reuse a specific session
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//'; }

session_dir() {
    if [ -n "${CYM_SESSION:-}" ]; then
        case "$CYM_SESSION" in
            */*|?:*) printf '%s\n' "$CYM_SESSION" ;;
            *)       printf '%s\n' "$CYM_BACKUP_ROOT/$CYM_SESSION" ;;
        esac
        return
    fi
    printf '%s/%s-%s-%s\n' "$CYM_BACKUP_ROOT" \
        "$(slug "${DEV_BRAND:-device}")" \
        "$(slug "${DEV_MODEL:-unknown}")" \
        "$(date +%Y%m%d-%H%M%S)"
}

# Reuse the newest session for this device if there is one, else make a new one.
resume_or_new_session() {
    if [ -n "${CYM_SESSION:-}" ]; then session_dir; return; fi
    local pointer="$CYM_BACKUP_ROOT/.last-session" last
    if [ -f "$pointer" ]; then
        last="$(cat "$pointer")"
        if [ -d "$last" ] && [ "$(cat "$last/device.serial" 2>/dev/null)" = "${ANDROID_SERIAL:-}" ]; then
            printf '%s\n' "$last"; return
        fi
    fi
    session_dir
}

latest_session() {
    local pointer="$CYM_BACKUP_ROOT/.last-session"
    if [ -f "$pointer" ] && [ -d "$(cat "$pointer")" ]; then
        cat "$pointer"; return 0
    fi
    ls -1dt "$CYM_BACKUP_ROOT"/*/ 2>/dev/null | head -1 | sed 's#/$##'
}

init_session() {
    local dir="$1"
    mkdir -p "$dir" "$CYM_BACKUP_ROOT"
    printf '%s\n' "${ANDROID_SERIAL:-}" > "$dir/device.serial"
    printf '%s\n' "$dir" > "$CYM_BACKUP_ROOT/.last-session"
    if [ ! -f "$dir/device.json" ]; then
        cat > "$dir/device.json" <<JSON
{
  "brand": "${DEV_BRAND:-}",
  "model": "${DEV_MODEL:-}",
  "device": "${DEV_DEVICE:-}",
  "android": "${DEV_ANDROID:-}",
  "sdk": "${DEV_SDK:-}",
  "build": "${DEV_BUILD:-}",
  "security_patch": "${DEV_SECPATCH:-}",
  "serial": "${ANDROID_SERIAL:-}",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
    fi
}

# -------------------------------------------------------- essential guard ----
# The hard stop. Anything on the never-touch list is refused, whatever the
# caller asked for. Parsed once into CYM_ESSENTIALS, newline separated.
load_essentials() {
    [ -n "${CYM_ESSENTIALS:-}" ] && return 0
    local f="$CYM_DB_DIR/essential_packages.json"
    [ -f "$f" ] || die "Missing $f - refusing to touch anything without the never-touch list."
    # Array elements only: a key is always followed by a colon, an element is not.
    # Then keep only things shaped like package names - something.something -
    # plus the bare framework package "android". Without that second filter the
    # single-word entries in _meta.categories_protected ("camera", "keyboard",
    # "settings") were landing in the list, which disagreed with the Python and
    # PowerShell guards and would have hidden a real parse failure.
    CYM_ESSENTIALS="$(grep -oE '^[[:space:]]*"[a-zA-Z][a-zA-Z0-9_.]*"[[:space:]]*,?[[:space:]]*$' "$f" \
        | grep -oE '"[^"]+"' | tr -d '"' \
        | grep -xE 'android|[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+' | sort -u)"
    [ -z "$CYM_ESSENTIALS" ] && die "The never-touch list parsed as empty - refusing to continue."
    export CYM_ESSENTIALS
}

is_essential() {
    load_essentials
    printf '%s\n' "$CYM_ESSENTIALS" | grep -qxF "$1"
}

# Package names that mean "do not touch" on their own, for whatever the list
# misses on an unusual ROM. CYM_ALLOW_PROTECTED=1 overrides the name rule only;
# it never overrides the never-touch list.
# The second group covers build-time infrastructure rather than apps: runtime
# resource overlays, framework resources, GPU drivers and graphics layers. A
# OnePlus 10 Pro carries 30+ of these (com.oplus.framework.res.overlay,
# com.oplus.gpudrivers.sm8450.api31, android.frameworkres.overlay and so on).
# None is an app anyone installed, and removing one can cost you the display.
PROTECTED_PATTERNS='(^android$|systemui|^com\.android\.settings|telecom|telephony|dialer|incallui|\.mms|messaging|inputmethod|latin|keyboard|^com\.android\.vending$|^com\.google\.android\.gms|^com\.google\.android\.gsf|setupwizard|provision|keystore|keychain|permissioncontroller|packageinstaller|networkstack|\.wifi|bluetooth|^com\.android\.camera|launcher|\.home$|overlay|\.rro\.|_rro$|frameworkres|gpudrivers|vulkan|\.resources$|^android\.auto_generated)'

is_protected_by_pattern() {
    printf '%s' "$1" | grep -qE "$PROTECTED_PATTERNS"
}

# The final gate. Prints the reason and returns 1 when a package must be kept.
block_reason() {
    local pkg="$1"
    if is_essential "$pkg"; then
        printf 'on the never-touch list\n'; return 1
    fi
    if is_protected_by_pattern "$pkg" && [ "${CYM_ALLOW_PROTECTED:-0}" != "1" ]; then
        printf 'name matches a protected category\n'; return 1
    fi
    return 0
}
