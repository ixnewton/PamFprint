#!/usr/bin/env bash
# install.sh — enable fingerprint authentication for privileged access by
# installing canonical pam.d files (files/pam.d/): the /etc/pam.d/polkit-1
# override, plus every other /etc/pam.d file already modified for pam_fprintd
# auth, backing up each target first.
#
# The polkit-1 override makes every polkit prompt accept a fingerprint first
# (sufficient), falling back to a password via system-auth — consistent with
# how sudo is already configured on this host.
#
# Run as root:  sudo bash install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)/files"
[ -d "$HERE/pam.d" ] || { echo "missing files/pam.d dir next to $0" >&2; exit 1; }

echo "==> Installing PamFprint (fingerprint auth for privileged access)"

# Migration: rename backups left by the old PamDLuks install.
for b in /etc/pam.d/*.pamdluks-backup; do
	[ -e "$b" ] || continue
	mv -f "$b" "${b%.pamdluks-backup}.pamfprint-backup"
done

# Install canonical pam.d files. polkit-1 (this project's override) is
# installed unconditionally; every other file is only touched when the target
# already does pam_fprintd auth. A modified target is first backed up to
# <name>.pamfprint-backup so uninstall.sh can restore it.
for src in "$HERE/pam.d"/*; do
	name=${src##*/}
	target=/etc/pam.d/$name

	if [ "$name" != polkit-1 ]; then
		[ -f "$target" ] && \
			grep -Eq '^[[:space:]]*auth[[:space:]].*pam_fprintd\.so' "$target" \
			|| continue
	fi

	# Drop a stale backup that only contains our own file — restoring it
	# would silently keep the override on uninstall.
	[ -f "$target.pamfprint-backup" ] && cmp -s "$target.pamfprint-backup" "$src" \
		&& rm -f "$target.pamfprint-backup"

	# Already canonical — nothing to do.
	cmp -s "$target" "$src" 2>/dev/null && continue

	# Back up a pre-existing admin-modified target (never our own file, and
	# only if we haven't already saved one).
	if [ -f "$target" ] && [ ! -f "$target.pamfprint-backup" ]; then
		cp -a "$target" "$target.pamfprint-backup"
		echo "  backed up $target -> $target.pamfprint-backup"
	fi

	install -m 0644 -o root -g root "$src" "$target"
	echo "  installed $target"
done

# Report any other pam.d files doing pam_fprintd auth that we don't manage.
for f in /etc/pam.d/*; do
	[ -f "$f" ] || continue
	case "$f" in *.pamfprint-backup | *.pamdluks-backup) continue ;; esac
	grep -Eq '^[[:space:]]*auth[[:space:]].*pam_fprintd\.so' "$f" || continue
	[ -f "$HERE/pam.d/${f##*/}" ] || \
		echo "  note: $f uses pam_fprintd (not managed — no files/pam.d/${f##*/})"
done

# GUI wrapper for running KDE/Qt apps as root with the user's theme.
install -m 0755 -o root -g root "$HERE/pkexec-kde" /usr/local/bin/pkexec-kde

# --- Launch scripts: install + repoint the app's .desktop file ---
# Each files/launchscripts/<app>.sh is installed to /usr/local/bin when the
# target application exists. The app's system .desktop file (whose Exec=
# invokes the app) is repointed at the script, backed up first so
# uninstall.sh can restore it.
desktop_repointed=0
for src in "$HERE/launchscripts"/*.sh; do
	[ -f "$src" ] || continue
	name=${src##*/}
	app=${name%.sh}
	if ! command -v "$app" >/dev/null 2>&1; then
		echo "  skipping $name ($app not installed)"
		continue
	fi
	target=/usr/local/bin/$name
	if [ ! -f "$target" ] || ! cmp -s "$target" "$src"; then
		install -m 0755 -o root -g root "$src" "$target"
		echo "  installed $target"
	fi
	for d in /usr/share/applications/*.desktop; do
		[ -f "$d" ] || continue
		grep -Eq "^Exec=([^[:space:]]*/)?${app}([[:space:]]|$)" "$d" || continue
		grep -q "/usr/local/bin/$name" "$d" && continue
		[ -f "$d.pamfprint-backup" ] || cp -a "$d" "$d.pamfprint-backup"
		sed -i -E "s|^Exec=([^[:space:]]*/)?${app}([[:space:]].*)?\$|Exec=/usr/local/bin/${name}\2|" "$d"
		echo "  repointed $d -> /usr/local/bin/$name"
		desktop_repointed=1
	done
done
[ "$desktop_repointed" -eq 1 ] && \
	command -v update-desktop-database >/dev/null 2>&1 && \
	update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

# --- Migration: remove any previously-installed auto-unlock plumbing ---
removed=0
for f in /etc/udev/rules.d/99-pamdluks.rules \
         /etc/systemd/system/pamdluks-trigger@.service \
         /usr/share/polkit-1/actions/org.pamdluks.unlock.policy \
         /usr/local/sbin/pamdluks-unlock /usr/local/sbin/pamdluks-enroll \
         /usr/local/lib/pamdluks-check-enrolled; do
	if [ -f "$f" ]; then
		echo "==> Removing legacy $f"
		rm -f "$f"
		removed=1
	fi
done
# User-level trigger service (single-user install).
u="ixnewton"
H=$(getent passwd "$u" | cut -d: -f6 || true)
if [ -n "$H" ] && [ -f "$H/.config/systemd/user/pamdluks-trigger@.service" ]; then
	echo "==> Removing legacy user trigger service for $u"
	systemctl --user -M "${u}@.host" stop 'pamdluks-trigger@*' 2>/dev/null || true
	rm -f "$H/.config/systemd/user/pamdluks-trigger@.service"
	removed=1
fi
[ "$removed" -eq 1 ] && {
	udevadm control --reload-rules
	systemctl daemon-reload
	systemctl --user -M "${u}@.host" daemon-reload 2>/dev/null || true
}

systemctl reload polkit.service 2>/dev/null || systemctl restart polkit.service 2>/dev/null || true

cat <<EOF

Done. Every polkit prompt now offers fingerprint first, falling back to
password; the other pam.d files keep their configured order (password
first, fingerprint fallback). Verify with: pkexec-kde true

To revert: sudo bash uninstall.sh
EOF
