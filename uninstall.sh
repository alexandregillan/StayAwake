#!/bin/bash
# Removes StayAwake and undoes every system change it made.
set -e
cd "$(dirname "$0")"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }

echo
printf '\033[1mStayAwake uninstaller\033[0m\n'
echo

# 1. Quit the app. Quitting normally makes it restore sleep and screensaver itself.
if pgrep -xq StayAwake; then
    osascript -e 'tell application "StayAwake" to quit' >/dev/null 2>&1 || pkill -x StayAwake || true
    sleep 1
    ok "Quit StayAwake"
fi

# 2. Belt and braces: make sure lid sleep and the screensaver are back to normal
#    even if the app was force-killed at some point.
if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
    if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then
        ok "Re-enabled lid sleep"
    else
        info "Re-enabling lid sleep (needs your password)"
        sudo /usr/bin/pmset -a disablesleep 0
        ok "Re-enabled lid sleep"
    fi
fi
original="$(defaults read com.alexandregillan.StayAwake OriginalIdleTime 2>/dev/null || true)"
if [ -n "$original" ]; then
    defaults -currentHost write com.apple.screensaver idleTime -int "$original"
    ok "Restored screensaver to ${original}s"
fi

# 3. Remove the passwordless rule if present.
if [ -f /etc/sudoers.d/stayawake ]; then
    info "Removing /etc/sudoers.d/stayawake (needs your password)"
    sudo rm -f /etc/sudoers.d/stayawake
    ok "Removed passwordless rule"
fi

# 4. Remove the app and its preferences. Deleting the app also drops its
#    Launch at Login entry.
rm -rf "$HOME/Applications/StayAwake.app"
defaults delete com.alexandregillan.StayAwake >/dev/null 2>&1 || true
rm -rf build
ok "Removed app and preferences"

echo
echo "  StayAwake is gone. Your Mac sleeps normally again."
echo
