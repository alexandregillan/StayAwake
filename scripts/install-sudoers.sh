#!/bin/bash
# Installs a sudoers rule so StayAwake can toggle lid (clamshell) sleep without
# a password prompt. Scoped to exactly two command lines and nothing else.
#
#   sudo scripts/install-sudoers.sh [username]
#
# The app also runs this itself (bundled in Contents/Resources) when you pick
# "Set Up Once" in its lid-mode dialog.
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Run this with sudo:  sudo $0" >&2
    exit 1
fi

# Username comes from $1, or SUDO_USER, or logname. $1 is needed when this is
# run through the macOS admin dialog, where SUDO_USER is not set.
USER_NAME="${1:-${SUDO_USER:-$(logname)}}"
DEST=/etc/sudoers.d/stayawake
TMP="$(mktemp)"

cat > "$TMP" <<RULE
# Installed by StayAwake (https://github.com/alexandregillan/StayAwake).
# Lets $USER_NAME toggle clamshell sleep without a password prompt.
# Scoped to these two exact command lines and nothing else.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
RULE

# Never install a sudoers file that does not parse.
if ! visudo -cqf "$TMP"; then
    echo "Syntax check failed. Nothing was installed." >&2
    rm -f "$TMP"
    exit 1
fi

install -m 0440 -o root -g wheel "$TMP" "$DEST"
rm -f "$TMP"

echo "Installed $DEST for user '$USER_NAME'."
echo "To undo:  sudo rm $DEST"
