#!/usr/bin/env bash
# uninstall.sh — remove the PamFprint polkit PAM override, restoring the
# vendor password-only polkit authentication. Run as root:  sudo bash uninstall.sh
set -euo pipefail

confirm() {
	read -r -p "$1 [y/N] " ans
	case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
}

echo "PamFprint uninstall — restores password-only polkit auth."

HERE="$(cd "$(dirname "$0")" && pwd)/files"

# Restore every file backed up at install time (new naming first, then the
# legacy PamDLuks naming): pam.d files and repointed .desktop files.
restored_polkit=0
found_backup=0
for b in /etc/pam.d/*.pamfprint-backup /etc/pam.d/*.pamdluks-backup \
         /usr/share/applications/*.pamfprint-backup; do
	[ -f "$b" ] || continue
	orig=${b%.pamfprint-backup}
	orig=${orig%.pamdluks-backup}
	echo "  Restoring backup $b -> $orig"
	mv -f "$b" "$orig"
	found_backup=1
	[ "$orig" = /etc/pam.d/polkit-1 ] && restored_polkit=1
done
[ "$found_backup" -eq 0 ] && echo "  no backups found."

# The polkit-1 override is this project's own file: if it wasn't restored
# from a backup, remove it so polkit falls back to the vendor copy at
# /usr/lib/pam.d/polkit-1 (password-only via system-auth).
if [ "$restored_polkit" -eq 0 ]; then
	if [ -f /etc/pam.d/polkit-1 ]; then
		confirm "  Remove /etc/pam.d/polkit-1 (restores vendor password-only)?"
		rm -f /etc/pam.d/polkit-1
	else
		echo "  /etc/pam.d/polkit-1 not present (already vendor default)."
	fi
fi

# Clean up any leftover auto-unlock plumbing from older installs.
for f in /etc/udev/rules.d/99-pamdluks.rules \
         /etc/systemd/system/pamdluks-trigger@.service \
         /usr/share/polkit-1/actions/org.pamdluks.unlock.policy \
         /usr/local/sbin/pamdluks-unlock /usr/local/sbin/pamdluks-enroll \
         /usr/local/lib/pamdluks-check-enrolled \
         /usr/local/bin/pkexec-kde; do
	[ -f "$f" ] && { echo "  removing leftover $f"; rm -f "$f"; }
done
# Remove installed launch scripts (their .desktop repoints are restored above).
for s in "$HERE"/launchscripts/*.sh; do
	[ -f "$s" ] || continue
	f=/usr/local/bin/${s##*/}
	[ -f "$f" ] && { echo "  removing $f"; rm -f "$f"; }
done
# User-level trigger service (single-user install).
u="ixnewton"
H=$(getent passwd "$u" | cut -d: -f6 || true)
if [ -n "$H" ] && [ -f "$H/.config/systemd/user/pamdluks-trigger@.service" ]; then
	echo "  removing user trigger service for $u"
	systemctl --user -M "${u}@.host" stop 'pamdluks-trigger@*' 2>/dev/null || true
	rm -f "$H/.config/systemd/user/pamdluks-trigger@.service"
fi
echo "Reloading udev, systemd, polkit..."
udevadm control --reload-rules 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl reload polkit.service 2>/dev/null || systemctl restart polkit.service 2>/dev/null || true

echo
echo "Done. Polkit prompts are password-only again."
