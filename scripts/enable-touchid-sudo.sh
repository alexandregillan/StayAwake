#!/bin/bash
# Optional extra, unrelated to the app itself: lets you use Touch ID instead of
# typing a password whenever you run sudo in the terminal.
#
#   sudo scripts/enable-touchid-sudo.sh
#
# Activates the pam_tid line in Apple's own sudo_local template. That file is
# Apple's designated place for this and survives macOS updates.
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Run this with sudo:  sudo $0" >&2
    exit 1
fi

TEMPLATE=/etc/pam.d/sudo_local.template
DEST=/etc/pam.d/sudo_local
LINE='^auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so'

if [ ! -f "$TEMPLATE" ]; then
    echo "No $TEMPLATE on this macOS version. Nothing done." >&2
    exit 1
fi

if [ -f "$DEST" ] && grep -qE "$LINE" "$DEST"; then
    echo "Touch ID for sudo is already enabled."
    exit 0
fi

TMP="$(mktemp)"
sed 's/^#auth\([[:space:]]\)/auth\1/' "$TEMPLATE" > "$TMP"

if ! grep -qE "$LINE" "$TMP"; then
    echo "Could not activate pam_tid in the template. Nothing installed." >&2
    rm -f "$TMP"
    exit 1
fi

# Plain cp rather than install(1): install stages a temp file inside
# /etc/pam.d and renames it, which gets refused there.
cp "$TMP" "$DEST"
chown root:wheel "$DEST"
chmod 0444 "$DEST"
rm -f "$TMP"

echo "Touch ID enabled for sudo."
echo "To undo:  sudo rm $DEST"
