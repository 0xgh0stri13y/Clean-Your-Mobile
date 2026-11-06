#!/usr/bin/env bash
# Clean Your Mobile - install the Android platform tools (macOS, Linux)
#
#   bash scripts/setup_adb.sh            # install if missing
#   bash scripts/setup_adb.sh --force    # install even if adb is on the PATH
#
# Prefers the system package manager, falls back to Google's official zip.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

banner "ADB setup"

# ------------------------------------------------------------ already there --
if [ "$FORCE" = 0 ] && command -v adb >/dev/null 2>&1; then
    ok "adb is already installed"
    info "   $(command -v adb)"
    info "   $(adb version | head -1)"
    info ""
    info " Nothing to do. Pass --force to reinstall anyway."
    info " Next: bash scripts/connect.sh"
    exit 0
fi

INSTALL_DIR="$HOME/platform-tools"

# install_from_zip <platform-slug>
install_from_zip() {
    local slug="$1"
    local url="https://dl.google.com/android/repository/platform-tools-latest-${slug}.zip"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    step "Downloading Google's official platform-tools"
    info "   $url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp/pt.zip" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp/pt.zip" "$url" || return 1
    else
        err "Neither curl nor wget is available."
        return 1
    fi
    command -v unzip >/dev/null 2>&1 || { err "unzip is not installed."; return 1; }

    step "Extracting"
    unzip -q -o "$tmp/pt.zip" -d "$tmp" || return 1
    [ -x "$tmp/platform-tools/adb" ] || { err "The archive did not contain adb."; return 1; }

    # Replace only a directory that looks like platform-tools.
    if [ -d "$INSTALL_DIR" ]; then
        if [ -e "$INSTALL_DIR/adb" ] || [ -e "$INSTALL_DIR/NOTICE.txt" ]; then
            rm -rf "$INSTALL_DIR"
        else
            err "$INSTALL_DIR exists and does not look like platform-tools."
            info " Move it aside and run this again."
            return 1
        fi
    fi
    mv "$tmp/platform-tools" "$INSTALL_DIR" || return 1
    ok "Installed to $INSTALL_DIR"

    export PATH="$INSTALL_DIR:$PATH"

    # Name the shell's own rc file rather than guessing bash.
    local rc
    case "${SHELL##*/}" in
        zsh)  rc="$HOME/.zshrc" ;;
        fish) rc="$HOME/.config/fish/config.fish" ;;
        *)    rc="$HOME/.bashrc" ;;
    esac
    info ""
    warn "adb is on the PATH for this terminal session only."
    info "   To keep it, add this line to $rc:"
    if [ "${SHELL##*/}" = "fish" ]; then
        info "     fish_add_path $INSTALL_DIR"
    else
        info "     export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
    return 0
}

OS="$(uname -s)"
case "$OS" in
Darwin)
    step "macOS detected"
    if command -v brew >/dev/null 2>&1; then
        info " Installing via Homebrew"
        if brew install --cask android-platform-tools 2>/dev/null \
           || brew install android-platform-tools 2>/dev/null; then
            ok "Installed with Homebrew"
        else
            warn "Homebrew install failed; falling back to the official zip."
            install_from_zip darwin || die "Could not install adb."
        fi
    else
        install_from_zip darwin || die "Could not install adb."
    fi
    ;;
Linux)
    step "Linux detected"
    if command -v apt-get >/dev/null 2>&1; then
        info " Installing via apt"
        sudo apt-get update && sudo apt-get install -y android-tools-adb \
            || install_from_zip linux || die "Could not install adb."
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y android-tools || install_from_zip linux || die "Could not install adb."
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm android-tools || install_from_zip linux || die "Could not install adb."
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y android-tools || install_from_zip linux || die "Could not install adb."
    else
        install_from_zip linux || die "Could not install adb."
    fi
    ;;
MINGW*|MSYS*|CYGWIN*)
    warn "This looks like Git Bash on Windows."
    info " Use the PowerShell script instead, which handles the PATH properly:"
    info "   powershell -ExecutionPolicy Bypass -File scripts/setup_adb.ps1 -Persist"
    exit 1
    ;;
*)
    die "Unsupported platform: $OS. Install the Android platform tools by hand."
    ;;
esac

# ---------------------------------------------------------------- verify -----
info ""
if ! ADB_FOUND="$(adb_path)"; then
    die "adb still is not on the PATH. Open a new terminal and check again."
fi
ok "adb works"
info "   $ADB_FOUND"
info "   $("$ADB_FOUND" version | head -1)"

# Linux only: without a udev rule the phone shows up as "no permissions".
if [ "$OS" = "Linux" ] && [ ! -e /etc/udev/rules.d/51-android.rules ]; then
    info ""
    warn "No Android udev rule found."
    info "   If the phone shows as 'no permissions', add your user to the"
    info "   plugdev group and install the android-udev package for your distro."
fi

info ""
hr
info " On the phone, before you connect:"
info "   Settings > About phone > tap Build number seven times"
info "   Settings > System > Developer options > USB debugging ON"
info ""
info " Then:  bash scripts/connect.sh"
hr
