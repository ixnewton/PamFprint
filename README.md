# PamFprint — fingerprint polkit authorization helper to ease privileged access where fprintd is installed (Arch / KDE Plasma)

## What this is

Canonical `/etc/pam.d` configuration plus an installer that keeps
`pam_fprintd` wired into every privileged-access scenario whilst logged into the KDE plasma 6 desktop session:
polkit prompts, `sudo`, `su`, console login, and the SDDM/LightDM display
managers — with a themed `pkexec` wrapper for running KDE/Qt GUI apps with sudo privilege.

Be aware of the security implications of having fingerprint authentication enabled for all these scenarios. Only trusted applications should be run with this configuration. There may be issues on multi-user systems. 

`files/pam.d/` holds the canonical copy of each fingerprint-enabled PAM
file. The installer syncs them to `/etc/pam.d/`, backing up anything it
changes; the uninstaller restores the backups.

## Covered scenarios

| Scenario | `/etc/pam.d` file | Auth behavior |
|----------|-------------------|---------------|
| Polkit prompts — partition tools, pkexec, KDE system settings, device unlocks | `polkit-1` | fingerprint first → password fallback |
| `sudo` | `sudo` | password → fingerprint on failure |
| `su` | `su` | password → fingerprint on failure |
| TTY/console login | `login` | password → fingerprint on failure |
| SDDM login screen | `sddm` | password → fingerprint on failure |
| LightDM login screen | `lightdm` | password → fingerprint on failure |
| GUI apps as root (`pkexec-kde`) | via `polkit-1` | fingerprint first → password fallback |
| Menu-launched root apps (krusader, ksystemlog, zenmap) | `.desktop` → `/usr/local/bin/<app>.sh` → `pkexec-kde` → `polkit-1` | fingerprint first → password fallback |

> **Fingerprint banner color.** The pink banner in the polkit password
> dialog is a `Kirigami.InlineMessage` rendered in the color scheme's
> negative/error colors — its style is compiled into `polkit-kde-agent`
> (the QML lives inside the binary), so it cannot be themed separately.
> Changing `ForegroundNegative`/`BackgroundAlternate` values in the active
> color scheme recolors the banner — but it also recolors every
> error/negative element system-wide, not just this banner.

## Files

| Source (`files/`)   | Target                                  |
|---------------------|-----------------------------------------|
| `pam.d/polkit-1`    | `/etc/pam.d/polkit-1` (override of vendor file at `/usr/lib/pam.d/polkit-1`) |
| `pam.d/lightdm`, `pam.d/login`, `pam.d/sddm`, `pam.d/su`, `pam.d/sudo` | `/etc/pam.d/…` canonical copies of the pam_fprintd-enabled files |
| `pkexec-kde`        | `/usr/local/bin/pkexec-kde` (wrapper to run KDE/Qt GUI apps as root with your theme) |
| `launchscripts/<app>.sh` | `/usr/local/bin/<app>.sh` (per-app root launchers; the app's `.desktop` file is repointed at the script) |

## Install

```bash
git clone https://github.com/ixnewton/PamFprint.git
cd PamFprint
sudo bash install.sh
```

The installer checks every `/etc/pam.d` file that already does `pam_fprintd`
auth: any target that differs from its canonical copy in `files/pam.d/` is
backed up to `<name>.pamfprint-backup` before the canonical copy is
installed (`polkit-1` is always installed — it is this project's override).
Files using `pam_fprintd` that have no canonical copy are reported but left
untouched. The `pkexec-kde` wrapper is installed, and any leftover
auto-unlock plumbing from older installs is removed.

For each `files/launchscripts/<app>.sh`, the script is installed to
`/usr/local/bin/` when the application exists; the app's `.desktop` file in
`/usr/share/applications/` (the one whose `Exec=` invokes the app) is
backed up and repointed at the script, so launching the app from the menu
runs it as root through `pkexec-kde` → polkit → fingerprint prompt.
Package updates restore the vendor `.desktop` files — re-run install.sh to
repoint them again.

## Running GUI apps as root with your KDE theme

`pkexec` strips all environment variables, so root-run Qt/KDE apps can't
find your display or your theme config. The `pkexec-kde` wrapper passes
through the display + KDE config/data dirs so the root process picks up
your application style, color scheme, icons, and window decorations:

```bash
pkexec-kde krusader           # file manager as root, with your theme
pkexec-kde partitionmanager    # etc.
```

Auth goes through polkit → the fingerprint prompt appears (via the PAM
override). Root can read your `~/.config/` despite it being mode 700
because root bypasses file permission checks.

## Uninstall

```bash
sudo bash uninstall.sh
```

Restores every `<file>.pamfprint-backup` (pam.d files and `.desktop` files)
over its target, and removes the `/usr/local/bin` launch scripts. The
`polkit-1` override is removed instead if it has no backup, falling back to
the vendor `/usr/lib/pam.d/polkit-1` — password-only. Also cleans up any
leftover auto-unlock files from older installs.

## Security tradeoffs

1. **Fingerprint is a convenience, not a gate.** Every managed file keeps a
   password path — `sufficient` never `required` — so a wet finger,
   unreadable sensor, or unenrolled account always falls back to a
   passphrase. Nothing here is fingerprint-only.
2. **`/etc/pam.d/polkit-1` override is system-wide.** Every polkit prompt
   (gparted, timeshift, partitionmanager, udisks2 unlocks, …) offers
   fingerprint first. The `sudo`/`su`/`login`/DM files are password-first
   instead, with fingerprint as the fallback — edit `files/pam.d/` and
   re-run install.sh to change either behavior.
3. **Session required for polkit prompts.** The fingerprint dialog only
   works while logged into KDE with the polkit-kde agent running; TTY and
   display-manager prompts are unaffected.
