#!/bin/bash
# StayAwake installer. Builds the app, puts it in ~/Applications and launches it.
#
#   git clone https://github.com/alexandregillan/StayAwake.git
#   cd StayAwake && ./install.sh
set -e
cd "$(dirname "$0")"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }

echo
bold "StayAwake installer"
echo

# 1. macOS 13 or newer (needed for the Launch at Login API).
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 13 ]; then
    echo "StayAwake needs macOS 13 Ventura or newer. You have $(sw_vers -productVersion)." >&2
    exit 1
fi
ok "macOS $(sw_vers -productVersion)"

# 2. Swift compiler from Xcode Command Line Tools.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    warn "Xcode Command Line Tools are missing. Opening the installer."
    echo "    Click Install in the dialog, wait for it to finish, then run ./install.sh again."
    xcode-select --install 2>/dev/null || true
    exit 1
fi
ok "Swift compiler found"

# 3. Build.
echo
bold "Building"
scripts/build.sh
ok "Built"

# 4. Install into ~/Applications, replacing any running copy.
echo
bold "Installing"
DEST="$HOME/Applications/StayAwake.app"
mkdir -p "$HOME/Applications"
if pgrep -xq StayAwake; then
    osascript -e 'tell application "StayAwake" to quit' >/dev/null 2>&1 || true
    # Let it restore settings and fully exit before the bundle is replaced.
    for _ in $(seq 1 10); do pgrep -xq StayAwake || break; sleep 0.5; done
    pkill -x StayAwake 2>/dev/null || true
    sleep 0.5
fi
rm -rf "$DEST"
cp -R build/StayAwake.app "$DEST"
ok "Installed to $DEST"

# 5. Optional: passwordless lid mode. The app also offers this from its menu,
#    so it is fine to skip here.
echo
bold "Lid-closed mode"
echo "  Keeping the Mac awake with the lid closed needs administrator rights."
echo "  Installing a small rule now means the app never asks for your password."
echo "  It is limited to exactly two commands (lid sleep off / on) and nothing else."
echo "  You can also do this later from the app's menu."
echo
if [ -t 0 ]; then
    read -r -p "  Install the passwordless rule now? [y/N] " answer
    case "$answer" in
        [yY]*)
            sudo scripts/install-sudoers.sh "$USER"
            ok "Passwordless lid mode ready"
            ;;
        *) warn "Skipped. The app will offer it when you first use lid mode." ;;
    esac
else
    warn "Non-interactive shell, skipped. The app will offer it when you first use lid mode."
fi

# 6. Launch.
echo
open "$DEST"
ok "Launched. Look for the coffee cup in your menu bar."
echo
bold "Done"
echo "  Click the cup to turn it on. Turn on Launch at Login from the menu to keep it around."
echo "  To remove everything later:  ./uninstall.sh"
echo
