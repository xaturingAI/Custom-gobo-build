#!/bin/bash
# Canonical post-merge LiveCD fixer. Idempotent. Usage: apply-live-fixes.sh <rootfs-tree>
#
# Consolidates every runtime fix discovered while debugging the Pantheon
# gaming ISO in QEMU:
#   1. qt.conf beside sddm-greeter (Qt plugin/QML resolution)
#   2. SddmComponents QML onto Qt import path
#   3. sddm system user + video/input groups + unprivileged `live` user
#   4. /etc/shells (pam_shells denies logins when empty!)
#   5. PAM system-login / system-local-login stacks (missing -> all logins fail)
#   6. REAL sddm.conf at Resources/Defaults/Settings (binary ignores /etc/sddm.conf;
#      /etc/sddm.conf kept as symlink). Greeter login live/live, root visible in box.
#   7. Generic D-Bus system-services Exec-path repair (FHS paths -> /Programs)
#   8. GdkPixbuf loader dir curation (drop stale 2.40 loaders, keep SVG loader,
#      remove stale caches so runtime rescans)
#   9. Xsession: LD_PRELOAD /lib/librsvg-2.so.2 (prevents double RsvgHandle
#      registration panic when pixbuf svg loader + direct link both load rsvg)
#  10. python -> python3 symlink
#  11. Elogind + SeatD boot tasks written into package trees
#  12. BootUp wiring: MessageBus -> Elogind Start, SeatD Start, dhcpcd (all
#      ifaces; survives eth0/ens3 renaming), OpenSSH Start, sddm
#  13. dbus-daemon-launch-helper reachable at common FHS paths
#  14. GLVND EGL vendor files: materialize /usr/share/glvnd/egl_vendor.d with
#      Mesa (+ optional Nvidia) vendor JSON so EGL always initializes
set -u
TREE="${1:?usage: apply-live-fixes.sh <rootfs-tree>}"
[ -d "$TREE/Programs" ] || { echo "not a rootfs tree: $TREE"; exit 1; }
say() { echo "[livefix] $*"; }

SDDM_VER=$(basename "$(readlink "$TREE/Programs/SDDM/Current" 2>/dev/null || echo SDDM/0.18.1)")
ELOGIND_VER=$(basename "$(readlink "$TREE/Programs/Elogind/Current" 2>/dev/null || echo Elogind/257.16)")
SEATD_VER=$(basename "$(readlink "$TREE/Programs/SeatD/Current" 2>/dev/null || echo SeatD/0.6.4)")
say "versions: SDDM=$SDDM_VER Elogind=$ELOGIND_VER SeatD=$SEATD_VER"

# --- 1) qt.conf beside sddm-greeter ---------------------------------------
# Prefix points at the active system Qt. Qt 5.14.1 is baked into the base ISO;
# the 5.15.2 migration replaces it. Resolve Programs/Qt/Current so this keeps
# working regardless of the active Qt version.
QTACTIVE=$(readlink "$TREE/Programs/Qt/Current" 2>/dev/null || echo 5.15.2)
for sddmbin in "$TREE"/Programs/SDDM/*/bin; do
    [ -x "$sddmbin/sddm-greeter" ] || continue
    if [ ! -f "$sddmbin/qt.conf" ]; then
        printf '[Paths]\nPrefix=/Programs/Qt/%s\n' "$QTACTIVE" > "$sddmbin/qt.conf"
        say "created ${sddmbin#$TREE/}/qt.conf (Qt $QTACTIVE)"
    fi
done

# --- 2) SddmComponents QML module onto Qt import path ----------------------
mkdir -p "$TREE"/Programs/Qt/*/qml 2>/dev/null
for qtdir in "$TREE"/Programs/Qt/5*/qml; do
    [ -d "$qtdir" ] || continue
    if [ ! -e "$qtdir/SddmComponents" ] && [ ! -L "$qtdir/SddmComponents" ] && [ -d "$TREE/Programs/SDDM/$SDDM_VER/qml/SddmComponents" ]; then
        ln -s "/Programs/SDDM/$SDDM_VER/qml/SddmComponents" "$qtdir/SddmComponents"
        say "linked ${qtdir#$TREE/}/SddmComponents"
    fi
done

# --- 3) users and groups ----------------------------------------------------
grep -q '^video:' "$TREE/etc/group" || echo 'video:x:103:' >> "$TREE/etc/group"
grep -q '^input:'  "$TREE/etc/group" || echo 'input:x:24:'  >> "$TREE/etc/group"
if ! grep -q '^sddm:' "$TREE/etc/passwd"; then
    grep -q '^sddm:' "$TREE/etc/group" || echo 'sddm:x:63:' >> "$TREE/etc/group"
    echo 'sddm:x:63:63:SDDM Display Manager:/var/lib/sddm:/bin/false' >> "$TREE/etc/passwd"
    grep -q '^sddm:' "$TREE/etc/shadow" || echo 'sddm:!:19700:0:99999:7:::' >> "$TREE/etc/shadow"
    say "created sddm user 63:63"
fi
if ! grep -q '^live:' "$TREE/etc/passwd"; then
    grep -q '^live:' "$TREE/etc/group" || echo 'live:x:1000:' >> "$TREE/etc/group"
    echo 'live:x:1000:1000:Live User:/Users/live:/bin/zsh' >> "$TREE/etc/passwd"
    echo "live:\$1\$YkWcMQvG\$srpADXE5KqFZDh8H1F./0/:19700:0:99999:7:::" >> "$TREE/etc/shadow"
    say "created live user 1000:1000"
fi
# membership pass (idempotent, comma-safe)
python3 - "$TREE/etc/group" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
out = []
for l in lines:
    f = l.split(':')
    if len(f) >= 4 and f[0] in ('video', 'input'):
        members = [m for m in f[3].split(',') if m]
        for u in ('live', 'sddm'):
            if u not in members:
                members.append(u)
        f[3] = ','.join(members)
        l = ':'.join(f)
    out.append(l)
open(p, 'w').write('\n'.join(out) + '\n')
PYEOF
mkdir -p "$TREE/var/lib/sddm" "$TREE/Users/live"
chown 63:63 "$TREE/var/lib/sddm" 2>/dev/null || true
chown 1000:1000 "$TREE/Users/live" 2>/dev/null || true

# --- 4) /etc/shells (pam_shells requirement) --------------------------------
# /etc/shells is usually a host-dangling symlink into the ISO tree; -s follows
# it, so without a fsync guard we'd "fix" a file whose target only exists in
# the ISO.  Replace any non-regular /etc/shells with a real one.
if [ ! -s "$TREE/etc/shells" ] || [ -L "$TREE/etc/shells" ]; then
    rm -f "$TREE/etc/shells"
    cat > "$TREE/etc/shells" <<'EOF'
/bin/sh
/bin/bash
/bin/zsh
/usr/bin/bash
/usr/bin/zsh
/System/Index/bin/zsh
/System/Index/bin/bash
EOF
    say "populated /etc/shells"
fi

# --- 5) PAM system-login + system-local-login --------------------------------
pamd="$TREE/etc/pam.d"
mkdir -p "$pamd"
if [ ! -e "$pamd/system-login" ]; then
    cat > "$pamd/system-login" <<'EOF'
#%PAM-1.0
auth       required     pam_nologin.so
auth       required     pam_env.so
auth       include      system-auth
account    required     pam_nologin.so
account    include      system-account
password   include      system-password
session    required     pam_loginuid.so
 session    required     pam_env.so
 session    optional     pam_lastlog.so
 session    optional     pam_elogind.so
 session    include      system-session
EOF
    say "created etc/pam.d/system-login"
fi
if [ ! -e "$pamd/system-local-login" ]; then
    {
        echo '#%PAM-1.0'
        echo 'auth     include system-login'
        echo 'account  include system-login'
        echo 'password include system-login'
        echo 'session  include system-login'
    } > "$pamd/system-local-login"
    say "created etc/pam.d/system-local-login"
fi
# Ensure an elogind session is created for every PAM login (this is what gives
# sddm/seatd switcheroo a real logind seat + XDG_RUNTIME_DIR on non-systemd).
# The "only if missing" guard above means a re-run skips rewriting system-login,
# so apply the optional elogind module idempotently against the actual file.
if ! grep -q 'pam_elogind.so' "$pamd/system-login" 2>/dev/null; then
    sed -i '/^session.*pam_lastlog.so/a session    optional     pam_elogind.so' "$pamd/system-login"
    say "added pam_elogind.so to system-login"
fi

# --- 6) REAL sddm.conf --------------------------------------------------------
# SDDM config layout moved between 0.18.1 and 0.20.0:
#   0.18.1: reads Resources/Defaults/Settings/sddm.conf (Gobo default-settings tree)
#   0.20.0: CONFIG_FILE=<sysconfdir>/sddm.conf ; SYSTEM_CONFIG_DIR=<prefix>/lib/sddm/sddm.conf.d
# We write the canonical config into BOTH locations so the daemon finds it
# regardless of version, and always provide /etc/sddm.conf.
# DisplayServer=wayland is only honored by 0.20.0+ (0.18.1/0.19.0 hard-code Xorg);
# it is harmless on older builds but only takes effect on 0.20.0.
sddm_maj=$(printf '%s' "$SDDM_VER" | cut -d. -f1)
if [ "$sddm_maj" -ge 20 ] || [ "$SDDM_VER" = "0.20.0" ]; then
    sddm_conf_dir="$TREE/Programs/SDDM/$SDDM_VER/Resources/Defaults/Settings"
    mkdir -p "$sddm_conf_dir"
    SYSTEMDDM_SYSCONF="$TREE/etc/sddm.conf"
    mkdir -p "$TREE/etc"
    # 0.20.0 also reads /etc/sddm.conf.d pieces; keep an empty dir so the
    # precedence search does not warn.
    mkdir -p "$TREE/etc/sddm.conf.d"
else
    sddm_conf_dir="$TREE/Programs/SDDM/$SDDM_VER/Resources/Defaults/Settings"
    mkdir -p "$sddm_conf_dir"
    SYSTEMDDM_SYSCONF="$TREE/etc/sddm.conf"
    mkdir -p "$TREE/etc"
fi

# --- 6a) Runtime log wrapper for greeter compositor + session -----------------
# All Pantheon-under-Wayland debugging happens in QEMU where the console is
# black after sddm starts.  Tee stdout/stderr of the greeter compositor and of
# the launched Wayland/X11 session into /Data/Variable/log so the failure point
# (weston, dbus-launch, gnome-session, gala, mutter) can be read back from the
# live filesystem.  Idempotent; wrapper is a plain sh script.
sddm_scripts="$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts"
mkdir -p "$sddm_scripts"
mkdir -p "$TREE/Data/Variable/log"
chmod 1777 "$TREE/Data/Variable/log" 2>/dev/null || true
gobo_log_run="$sddm_scripts/gobo-log-run"
if [ ! -x "$gobo_log_run" ] || ! grep -q "XDG_RUNTIME_DIR" "$gobo_log_run" 2>/dev/null; then
    cat > "$gobo_log_run" <<'GLR'
#!/bin/sh
# gobo-log-run <logfile> <command...>
# Runs <command...> with stdout+stderr teed (and appended) to <logfile>.
# Used by sddm.conf CompositorCommand and the SDDM Xsession/wayland-session
# launchers so Gala/Weston/gnome-session boot output is captured for debugging.
log="${1:?usage: gobo-log-run <logfile> <command...>}"
shift
[ -n "$log" ] || exit 0
mkdir -p "$(dirname "$log")"
# Every Wayland client/compositor (weston, sway, mutter/gala) and SDDM's own
# greeter need XDG_RUNTIME_DIR pointing at a user-owned 0700 dir.  The live
# system has no systemd-logind, so nothing creates /run/user/UID at login:
# refuse to run without one and fall back to a per-uid dir in /tmp (tmpfs).
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    uid="$(id -u)"
    for base in /run/user /tmp; do
        [ -d "$base" ] && [ -w "$base" ] || continue
        if mkdir -p "$base/$uid" 2>/dev/null && chmod 700 "$base/$uid" 2>/dev/null; then
            chown "$uid" "$base/$uid" 2>/dev/null || true
            XDG_RUNTIME_DIR="$base/$uid"
            export XDG_RUNTIME_DIR
            break
        fi
    done
    [ -n "$XDG_RUNTIME_DIR" ] || { echo "gobo-log-run: no writable XDG_RUNTIME_DIR base" >&2; exit 1; }
fi
printf '\n==== %s : %s ====\n' "$(date '+%F %T')" "$*" >> "$log"
exec "$@" 2>&1 | tee -a "$log"
GLR
    chmod 755 "$gobo_log_run"
    say "created greeter/session log wrapper ${gobo_log_run#$TREE/}"
fi

# waitdrm <command...>: wait up to 30s for /dev/dri/card0, then exec <command...>.
# On QEMU the virtio-gpu node appears a couple seconds AFTER sddm launches the
# greeter compositor; weston's auto-selected backend then silently falls back to
# headless-backend (Output 'headless', no cursor planes) and the login screen is
# blank.  The compositor is started with an explicit --backend=drm below, but
# only AFTER the DRM card exists.
waitdrm="$sddm_scripts/waitdrm"
if [ ! -x "$waitdrm" ]; then
    cat > "$waitdrm" <<'WAIT'
#!/bin/bash
for i in $(seq 1 30); do
    [ -e /dev/dri/card0 ] && break
    sleep 1
done
exec "$@"
WAIT
    chmod 755 "$waitdrm"
    say "created greeter compositor guard ${waitdrm#$TREE/}"
fi

# Emit the canonical body once, then copy it to every config location.
cat > "$sddm_conf_dir/sddm.conf" <<EOF
[General]
HaltCommand=/System/Index/bin/poweroff
RebootCommand=/System/Index/bin/reboot
# Native Wayland greeter (SDDM >= 0.20.0). Valid: x11, x11-user, wayland.
DisplayServer=wayland
# SDDM 0.20.0's build-DEFAULT is InputMethod=qtvirtualkeyboard; when the theme
# failed earlier it rendered an on-screen keyboard no one asked for (and which
# the maya theme does not need).  Explicitly disable it.
InputMethod=
# SDDM 0.20.0 hardcodes its initial VT to tty1 at compile time ("Using VT
# 1" in sddm.log); the [General] VT option is ignored on the Wayland build.
# tty1 must therefore stay getty-free (see block 6b): an inittab AutoLogin
# console on tty1 makes that console the controlling terminal of /dev/tty1,
# so sddm's VT control fails EPERM and sddm crash-loops with
# "Failed to take control of /dev/tty1" / "sddm-helper exited with 5".

[Theme]
# SDDM 0.20.0's sddm-greeter here is built against Qt 5.15.2, so the Plasma 6
# Breeze SDDM theme can NEVER load: its QML uses versionless imports
# (`import QtQuick.Controls`, `org.kde.plasma.components`, `org.kde.kirigami`)
# which are Qt6-only -> every import fails -> "Fallback to embedded theme" ->
# a near-black screen with only the qtvirtualkeyboard overlay (no wallpaper,
# no username/password fields).  Don't chase this: use one of SDDM's OWN
# Qt5-compatible themes (elarun/maldives/maya ship in the SDDM install prefix
# and render fine under the Qt5 greeter).  maya is full-screen, has the
# session/user/password UI, and was validated by logging into Plasma from it.
# ThemeDir defaults to the SDDM prefix dir; keep it explicit ($SDDM_VER expands
# because this heredoc is unquoted).
ThemeDir=/Programs/SDDM/$SDDM_VER/share/sddm/themes
Current=maya

[Users]
MinimumUid=0
MaximumUid=65534
RememberLastSession=true

[X11]
SessionDir=/usr/share/xsessions
# Redirect SDDM's own per-user session log to the centralized var-log too.
SessionLogFile=/Data/Variable/log/sddm-x11-session.log

[Wayland]
SessionDir=/usr/share/wayland-sessions
SessionLogFile=/Data/Variable/log/sddm-wayland-session.log
# Compositor that hosts the Wayland greeter (weston fullscreen shell plugin).
# --shell=kiosk is a cleaner alternative if it proves out in QEMU; the default
# fullscreen-shell.so is what SDDM 0.20.0 expects by default.  Output is teed
# to /Data/Variable/log/sddm-weston.log for QEMU debugging.  --backend=drm is
# mandatory: weston's auto-backend silently selects headless (blank screen, no
# cursor) when /dev/dri/card0 is not ready yet, so waitdrm gates it instead.
CompositorCommand=/usr/share/sddm/scripts/gobo-log-run /Data/Variable/log/sddm-weston.log /usr/share/sddm/scripts/waitdrm weston --backend=drm --seat=seat0 --shell=fullscreen-shell.so

# Login screen, no autologin: the LiveCD boots to the SDDM greeter where the
# user logs in as `live` (password `live`, NOPASSWD sudo -> root for
# GParted / Gobo installer).  Re-enable for a touch-free desktop boot.
# [Autologin]
# User=live
# Session=plasma.desktop
# Relogin=true
EOF
cp -f "$sddm_conf_dir/sddm.conf" "$SYSTEMDDM_SYSCONF"
[ -e "$TREE/etc/sddm.conf" ] || ln -s "/Programs/SDDM/$SDDM_VER/Resources/Defaults/Settings/sddm.conf" "$TREE/etc/sddm.conf"
# sddm persists the last-session name (and autologin pact) in /var/lib/sddm;
# a leftover state.conf/Users stash from an earlier pantheon-autologin boot
# overrides our Session=plasma.desktop on the NEXT boot (RememberLastSession).
# Purge the record so the first Plasma boot starts from our canonical config.
rm -f "$TREE/var/lib/sddm/state.conf" "$TREE/Data/Variable/lib/sddm/state.conf" 2>/dev/null || true
rm -rf "$TREE/var/lib/sddm/Users" "$TREE/Data/Variable/lib/sddm/Users" 2>/dev/null || true
# Seed the daemon's state (~sddm/state.conf, sddm user HOME is /var/lib/sddm):
# without it the greeter's session combo falls back to the alphabetically first
# entry (gnome-wayland) and the username field starts empty.  Preselecting
# Plasma (Wayland) + `live` means the only thing a LiveCD user has to do is
# type the password (also avoids the bogus empty-username PAM failure).
SDDM_STATE="$TREE/var/lib/sddm/state.conf"
mkdir -p "$(dirname "$SDDM_STATE")"
cat > "$SDDM_STATE" <<EOF
[Last]
Session=plasma.desktop
User=live
EOF
say "sddm: seeded state.conf (Session=plasma.desktop, User=live) so the greeter preselects Plasma for user live"
say "wrote sddm.conf (DisplayServer=wayland, Session=plasma.desktop in state, Theme=maya, InputMethod off), purged old sddm state"

# --- 6a) udev: expose input devices to the input group -------------------------
# devtmpfs (the kernel) creates /dev/input/* as 0600 root:root at EVERY boot,
# so neither the sddm greeter user nor the `live` plasma session can open them
# -> no mouse cursor and no keyboard, even though udevd is running.  (The
# greeter compositor sneaks input through libseat fd-passing, but kwin_wayland
# and plasma open /dev/input/event* DIRECTLY via libinput, so these MUST be
# readable by the input group.)  The tree ships no generic input rule (only
# 50-drm-access / 60-steam-*).  Install one:
#   - numeric GID 24, NOT the name "input": this LiveCD's udevd runs with
#     --resolve-names=never, so a GROUP="input" rule silently leaves the node
#     owned group root at coldplug (blamed a missing udev for a week);
#     GID=24 resolves unconditionally.
#   - `NAME="input/%k"` keeps nodes under /dev/input (belt & braces).
INPUT_RULE="$TREE/etc/udev/rules.d/60-input.rules"
if [ ! -f "$INPUT_RULE" ]; then
    mkdir -p "$TREE/etc/udev/rules.d"
    cat > "$INPUT_RULE" <<'INR'
KERNEL=="event*", NAME="input/%k", MODE="0660", GROUP="24"
KERNEL=="mouse*", MODE="0660", GROUP="24"
SUBSYSTEM=="input", MODE="0660", GROUP="24"
INR
    say "udev: wrote 60-input.rules (input gid 24 -> 0660 on /dev/input/*, numeric-GID for --resolve-names=never)"
fi

# --- 6a2) cursor theme: make the weston greeter's pointer visible -------------
# weston draws the cursor with the 'default' xcursor theme, and there is NO
# /usr/share/icons/default/index.theme in the tree -> weston resolves no cursor
# -> the pointer moves but is INVISIBLE (a "wrong input perms" red herring).
# Point 'default' at the Breeze cursor set (breeze_cursors, from the Breeze/
# 6.7.4 program) so the greeter shows a pointer.  The plasma session draws its
# own cursors from Breeze_Light/breeze anyway; this only affects the greeter.
DEFAULT_ICON_THEME="$TREE/usr/share/icons/default/index.theme"
mkdir -p "$(dirname "$DEFAULT_ICON_THEME")"
cat > "$DEFAULT_ICON_THEME" <<'ICT'
[Icon Theme]
Name=Default
Inherits=breeze_cursors
ICT
say "cursor: wrote /usr/share/icons/default/index.theme -> breeze_cursors (visible greeter pointer)"

# --- 6b) inittab: main tty tty1 belongs to sddm, drop the tty1 console -------
# Main tty change (PROGRESS.md): "inittab line 12 -- tty1 agetty replaced with
# sddm".  SDDM 0.20.0 (Wayland build) hardcodes its initial VT to tty1 at
# compile time and IGNORES [General] VT=, so a tty1 console agetty makes the
# AutoLogin console the controlling terminal of /dev/tty1 and sddm's VT
# takeover fails EPERM -> HELPER_TTY_ERROR loop ("Failed to take control of
# /dev/tty1 (root): Operation not permitted", "sddm-helper exited with 5").
# This is NOT a rework of the tty1 getty (NOTES.md: that was paused/broken) --
# the console agetty on the main tty is simply deleted; consoles stay on
# tty2-6 and any spare gettys (e.g. a pre-existing tty7) are untouched.
# Deleting the tty1 line ALSO clears the broken duplicate inittab id "1:"
# (a stray "1:...tty7" next to "1:...tty1").  Idempotent, delete-only.
inittab_src="$TREE/Programs/LiveCD/Settings/inittab"
if [ -f "$inittab_src" ]; then
    sed -i -E '/^[0-9]+:2345:respawn:.*tty1([^0-9]|$)/d' "$inittab_src"
    if grep -qE '^[0-9]+:2345:respawn:.*tty1([^0-9]|$)' "$inittab_src"; then
        say "inittab: WARNING tty1 getty still present (manual fix needed)"
    else
        say "inittab: tty1 console getty removed (tty1 = sddm main tty)"
    fi
    grep -E '^[0-9]+:2345:respawn:.*AutoLogin' "$inittab_src" | sed 's/^/    /'
fi
python3 - "$TREE" <<'PYEOF'
import os, sys, glob, subprocess
tree = sys.argv[1]
for svc in glob.glob(os.path.join(tree, 'usr/share/dbus-1/system-services/*.service')):
    real = os.path.realpath(svc)
    if not real.startswith(tree) or not os.path.isfile(real):
        continue
    lines = open(real).read().splitlines()
    changed = False
    out = []
    for l in lines:
        if l.startswith('Exec='):
            exe = l[5:].split()[0]
            if exe.startswith('/Programs/') or exe.startswith('/System/'):
                out.append(l); continue
            cand = None
            try:
                r = subprocess.run(['find', os.path.join(tree, 'Programs'),
                                    '-name', os.path.basename(exe), '-type', 'f'],
                                   capture_output=True, text=True, timeout=60)
                cands = [c for c in r.stdout.splitlines() if c.strip()]
                if cands:
                    cand = sorted(cands, key=len)[0][len(tree):]
            except Exception:
                pass
            if cand:
                out.append('Exec=' + l[5:].replace(exe, cand, 1))
                changed = True
                continue
        out.append(l)
    if changed:
        open(real, 'w').write('\n'.join(out) + '\n')
        print('[livefix] dbus Exec repaired:', os.path.basename(svc))
PYEOF

# --- 8) GdkPixbuf loader dir curation -----------------------------------------
LD="$TREE/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
NEW="$TREE/Programs/GdkPixbuf/2.42.12/lib/gdk-pixbuf-2.0/2.10.0/loaders"
SVG="$TREE/Programs/LibRSVG/2.46.4/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so"
if [ -d "$NEW" ]; then
    rm -f "$LD"/libpixbufloader-*
    for f in "$NEW"/libpixbufloader-*.so; do
        [ -e "$f" ] && ln -sf "${f#$TREE}" "$LD/$(basename "$f")"
    done
    [ -e "$SVG" ] && ln -sf "${SVG#$TREE}" "$LD/libpixbufloader-svg.so"
    rm -f "$LD/loaders.cache" \
          "$TREE/Programs/GdkPixbuf/2.42.12/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
    say "loaders dir curated (svg kept), stale caches removed (runtime rescan)"
fi

# --- 9) Xsession: preload librsvg (gala double-registration guard) -------------
XS="$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/Xsession"
if [ -f "$XS" ] && ! grep -q 'librsvg' "$XS"; then
    sed -i '2i export LD_PRELOAD="/lib/librsvg-2.so.2${LD_PRELOAD:+ $LD_PRELOAD}"' "$XS"
    say "Xsession: LD_PRELOAD librsvg added"
fi
sed -i '/GDK_PIXBUF_MODULE_FILE/d' "$XS" 2>/dev/null || true

# Wayland/X11 session scripts: SDDM 0.20.x hands the entire session command
# (e.g. "gnome-session --session=pantheon-wayland") to the script as a SINGLE
# argv element, and the script forwards "$@" quoted to `dbus-launch
# --exit-with-session`, so dbus-launch tries to exec one filename containing a
# space: "Couldn't exec gnome-session --session=pantheon-wayland: No such file
# or directory" and the session dies immediately.  Unquote so the shell
# word-splits the token into the real command + args.
for SC in \
    "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/wayland-session" \
    "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/Xsession"
do
    if [ -f "$SC" ] && grep -q -- '--exit-with-session "$@"' "$SC"; then
        sed -i 's/--exit-with-session "$@"/--exit-with-session $@/' "$SC"
        say "session script: unquoted \$@ for dbus-launch (${SC#$TREE/})"
    fi
done

# --- 10) python symlink ---------------------------------------------------------
if [ ! -e "$TREE/System/Index/bin/python" ]; then
    ln -s python3 "$TREE/System/Index/bin/python" 2>/dev/null && say "python -> python3"
fi

# --- 11) Boot tasks -------------------------------------------------------------
elogind_task="$TREE/Programs/Elogind/$ELOGIND_VER/Resources/Tasks/Elogind"
mkdir -p "$(dirname "$elogind_task")"
cat > "$elogind_task" <<'EOF'
#!/bin/sh
 ELG="$(readlink -f /Programs/Elogind/Current)/libexec/elogind"
 ELG_LIB="$(readlink -f /Programs/Elogind/Current)/lib/elogind"
 # elogind NEEDED libelogind-shared-257.so lives in its private lib/elogind
 # dir. Gobo's /System/Index/lib/<Program> convention is dlopen-only; the
 # dynamic loader does NOT search it for NEEDED, so without LD_LIBRARY_PATH the
 # exec fails (exit 127, loader "cannot open shared object file") and elogind
 # never starts ("elogind=0" in the live-boot report).
 export LD_LIBRARY_PATH="$ELG_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
 ELOG=/Data/Variable/log/elogind.log
mkdir -p /Data/Variable/log
    # sddm session scripts (wayland-session/Xsession -> gobo-log-run) run as
    # uid 1000 ("live"); /Data/Variable/log is root-owned 755 by default, so
    # the pantheon-*-session.log writes fail with EACCES and the session dies
    # before gnome-session even starts.
    chmod 1777 /Data/Variable/log

case "$1" in
[Ss]tart)
    # Guard on a resolvable, executable binary. If readlink fails / the Current
    # link is missing, ELG is empty and `pgrep -f ""` matches EVERY process ->
    # old guard returned 0 -> StartTask reported OK while nothing ran.
    if [ -z "$ELG" ] || [ ! -x "$ELG" ]; then
        printf '!! elogind START skipped: binary missing/unresolvable ELG=%s\n' "$ELG" >> "$ELOG"
        exit 1
    fi
    pgrep -xc elogind >/dev/null 2>&1 && exit 0
    mkdir -p /run/user
    # elogind --daemon self-daemonizes (double-fork, detaches session/fds);
    # background it so the boot Exec line returns instead of blocking. Plain &
    # + elogind's own --daemon keeps it alive (matches how OpenSSH survives).
    # Capture elogind's own stderr/stdout so its "Not setting XDG_RUNTIME_DIR"
    # and runtime-dir mount decisions are visible post-boot in $ELOG.
    printf '==== elogind start %s ====\n' "$(date '+%F %T')" >> "$ELOG"
    "$ELG" --daemon >>"$ELOG" 2>&1 &
    # D-Bus may still be coming up (MessageBus is backgrounded right before us);
    # --daemon can exit if it cannot register on the system bus on first try.
    # Give it a short window and verify it actually survived, then retry once.
    for _e in 1 2 3 4 5 6 7 8; do
        pgrep -xc elogind >/dev/null 2>&1 && break
        sleep 1
    done
    if ! pgrep -xc elogind >/dev/null 2>&1; then
        printf '  !! elogind not running after start; log tail:\n' >> "$ELOG"
        tail -n 30 "$ELOG" >> "$ELOG"
        exit 1
    fi
    printf '  elogind running (pid %s)\n' "$(pgrep -xc elogind)" >> "$ELOG"
    # elogind normally creates /run/user/<uid> for logged-in users via a login
    # manager, but the LiveCD has no logind session manager, so pre-create the
    # `live` user's XDG_RUNTIME_DIR ourselves (sway/gala/weston refuse to start
    # without one). Re-doing it here stays idempotent and matches what
    # pam_elogind will require (absolute, a directory, owned by uid 1000).
    if uid="$(id -u live 2>/dev/null)"; then
        gid="$(id -g live 2>/dev/null)"
        mkdir -p "/run/user/$uid"
        chmod 700 "/run/user/$uid"
        chown "$uid:$gid" "/run/user/$uid" 2>/dev/null || { rmdir "/run/user/$uid" 2>/dev/null; mkdir -p "/run/user/$uid"; chmod 700 "/run/user/$uid"; }
        printf '  pre-created /run/user/%s owned %s:%s mode 700\n' "$uid" "$uid" "$gid" >> "$ELOG"
    fi
    ;;
[Ss]top)
    pkill -f "$ELG"
    ;;
esac
EOF
chmod 755 "$elogind_task"

seatd_task="$TREE/Programs/SeatD/$SEATD_VER/Resources/Tasks/SeatD"
mkdir -p "$(dirname "$seatd_task")"
cat > "$seatd_task" <<'EOF'
#!/bin/sh
case "$1" in
[Ss]tart)
    pgrep -x seatd >/dev/null 2>&1 && exit 0
mkdir -p /Data/Variable/log /run
    chmod 1777 /Data/Variable/log
    # Background seatd directly. seatd is a long-running daemon; keep it in
    # the boot shell's group like OpenSSH (which survives boot) rather than a
    # setsid wrapper that could fail under the boot shell and silently not
    # start the daemon at all.
    seatd -g video >>/Data/Variable/log/seatd.log 2>&1 &
    ;;
[Ss]top)
    pkill -x seatd
    ;;
esac
EOF
chmod 755 "$seatd_task"

# SDDM display-manager start task: pgrep-guarded (StartLiveCD and BootUp both
# launch it, and a bare second sddm would fight for tty1 and crash-loop with
# HELPER_TTY_ERROR), setsid-detached/backgrounded like the BootUp line so it
# survives the boot shell teardown.
sddm_task="$TREE/Programs/SDDM/$SDDM_VER/Resources/Tasks/SDDM"
mkdir -p "$(dirname "$sddm_task")"
cat > "$sddm_task" <<'EOF'
#!/bin/bash
case "$1" in
[Ss]tart)
    pgrep -x sddm >/dev/null 2>&1 && exit 0
    mkdir -p /Data/Variable/log
    setsid -f /usr/bin/sddm >>/Data/Variable/log/sddm.log 2>&1 &
    ;;
[Ss]top)
    pkill -x sddm
    ;;
esac
EOF
chmod 755 "$sddm_task"
for t in "Elogind:$elogind_task" "SeatD:$seatd_task" "SDDM:$sddm_task"; do
    name="${t%%:*}"; path="${t#*:}"
    # -e follows the link: an existing link to an ISO-only task is host-dangling,
    # so a plain -e guard would re-ln and hit "File exists".
    [ -e "$TREE/System/Tasks/$name" ] || [ -L "$TREE/System/Tasks/$name" ] || \
        { mkdir -p "$TREE/System/Tasks"; ln -s "${path#$TREE}" "$TREE/System/Tasks/$name"; }
done
say "Elogind + SeatD + SDDM tasks installed"

# Ensure elogind config is accessible at /etc/elogind (elogind looks here).
# /etc/elogind is usually an absolute symlink into the ISO tree (host-dangling);
# only create real links when the ISO-visible target is actually missing, to
# avoid ENOENT spam on the host while keeping the tree ISO-correct.
elf_base="$TREE/etc/elogind"
elf_defaults="$TREE/Programs/Elogind/$ELOGIND_VER/Resources/Defaults/Settings/elogind"
if [ -L "$elf_base" ]; then
    iso_target="$TREE$(readlink "$elf_base")"
    if [ -e "$iso_target/logind.conf" ]; then
        say "elogind /etc/elogind resolves in-tree; skipping host create"
    else
        say "elogind /etc/elogind dangling; re-linking from $ELOGIND_VER defaults"
        rm -f "$elf_base"
        mkdir -p "$elf_base"
        ln -sf "/${elf_defaults#$TREE/}/logind.conf" "$elf_base/logind.conf"
        ln -sf "/${elf_defaults#$TREE/}/logind.conf.d" "$elf_base/logind.conf.d" 2>/dev/null || true
    fi
else
    mkdir -p "$elf_base"
    [ -e "$elf_base/logind.conf" ] || ln -sf "/${elf_defaults#$TREE/}/logind.conf" "$elf_base/logind.conf"
    [ -d "$elf_base/logind.conf.d" ] || \
        ln -sf "/${elf_defaults#$TREE/}/logind.conf.d" "$elf_base/logind.conf.d" 2>/dev/null || true
    say "elogind /etc/elogind symlink created"
fi

# pam_env.so is used with 'required' in sddm-greeter, sddm-autologin and
# system-auth; a missing /etc/environment makes it log an error.  Provision a
# minimal file (comments only; XDG_RUNTIME_DIR stays per-uid, never global).
if [ ! -e "$TREE/etc/environment" ]; then
    printf '# /etc/environment - system-wide PAM environment (see pam_env(8))\n' > "$TREE/etc/environment"
    say "provisioned minimal /etc/environment for pam_env.so"
fi

# --- 12) BootUp wiring -----------------------------------------------------------
bdir="$TREE/Programs/BootScripts/Settings/BootScripts"
def="$TREE/Programs/BootScripts/017.01/Resources/Defaults/Settings/BootScripts/BootUp"
mkdir -p "$bdir"
[ -f "$bdir/BootUp" ] || { cp "$def" "$bdir/BootUp"; chmod 644 "$bdir/BootUp"; }
bootup="$bdir/BootUp"
# remove raw daemon invocations superseded by task-style lines
sed -i '/libexec\/elogind --daemon/d; /^Daemon .*seatd/d; /^[[:space:]]*Daemon "Starting seat/d' "$bootup"
# insert task lines right after message bus startup
if ! grep -q '^Exec .*Elogind Start' "$bootup"; then
    sed -i '/^Exec "Starting message bus/a Exec "Starting logind daemon..."           Elogind Start\nExec "Starting seat daemon..."             SeatD Start\nExec "Requesting network address..."       dhcpcd' "$bootup"
fi
grep -q '^Exec .*OpenSSH Start' "$bootup" || \
    printf 'Exec "Starting ssh daemon..."               OpenSSH Start\n' >> "$bootup"
# sddm is a long-running foreground display manager: if BootUp launches it via
# ExecBackend's $(...) it blocks the boot shell forever and gets SIGHUP'd (with
# elogind/seatd in the same process group) when the runlevel-2 shell is torn
# down. Launch it fully detached (setsid, backgrounded) so it survives. pgrep
# guards the case where StartLiveCD already started it on a LiveCD boot.
if grep -q '^Exec .*display manager' "$bootup"; then
    sed -i '/^Exec .*display manager/c\Exec "Starting display manager..."          sh -c '\''pgrep -x sddm >/dev/null || setsid -f /usr/bin/sddm >>/Data/Variable/log/sddm.log 2>&1 &'\'' ' "$bootup"
else
    printf 'Exec "Starting display manager..."          sh -c '\''pgrep -x sddm >/dev/null || setsid -f /usr/bin/sddm >>/Data/Variable/log/sddm.log 2>&1 &'\'' \n' >> "$bootup"
fi
chmod 644 "$bootup"
say "BootUp wired: Elogind/SeatD tasks, dhcpcd, OpenSSH, sddm"

# --- 12b) resolv.conf nameservers (HW-neutral static fallback) -----------------
# dhcpcd ships its 20-resolv.conf hook here, so a granted lease rewrites
# resolv.conf with the server's DNS; this file only covers the pre-lease
# window.  The earlier baked set put 10.0.2.3 (QEMU slirp's *internal*
# forwarder) first -- unreachable on real hardware.  1.1.1.1 works through
# slirp AND on a physical NIC, so bake public resolvers only.
G_RESOLV="$TREE/etc/resolv.conf"
_G_RESOLV_IS_SYMLINK=
if [ -L "$G_RESOLV" ]; then _G_RESOLV_IS_SYMLINK=yes; fi
# /etc/resolv.conf on Gobo is a symlink INTO the system Settings tree
# (check resolves /System/Settings/resolv.conf).  Baking only the link itself
# ("$TREE/etc/resolv.conf") leaves the TRUE target empty, so on real hardware
# -- where no 10.0.2.3 NAT lease ever shows up to repopulate it -- DNS stays
# dead on every boot (hg-bug: "no Internet / can't update / Can't resolve host"
# despite the link working).  Write the SAME resolvers into the symlink target
# AND keep the link path populated; verify both now have a live nameserver.
if [ -s "$G_RESOLV" ] && ! grep -q '^nameserver' "$G_RESOLV"; then :; fi
if [ -s "$G_RESOLV" ] && [ -s "$(readlink -f "$G_RESOLV" 2>/dev/null || echo /nonexistent)" ]; then
    if grep -q '^nameserver' "$G_RESOLV" &&        grep -q '^nameserver' "$(readlink -f "$G_RESOLV")"; then
        :  # both already have resolvers - idempotent no-op
    fi
fi
if [ -L "$G_RESOLV" ]; then
    _G_RESOLV_TARGET="$(readlink -f "$G_RESOLV")"
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$_G_RESOLV_TARGET"
    chmod 644 "$_G_RESOLV_TARGET"
    say "resolv.conf: baked public resolvers 1.1.1.1 + 9.9.9.9 into symlink TARGET $_G_RESOLV_TARGET (real-hw lease-less boot DNS fix)"
fi
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$G_RESOLV"
chmod 644 "$G_RESOLV"
say "resolv.conf: link + target both carry public resolvers (VM QEMU-NAT + real hw)"


# On a `Boot=LiveCD` boot init short-circuits the S-stage BootUp to the
# StartLiveCD wizard, so StartLiveCD ends up as the *primary* daemon-launch
# site (runlevel-2 BootUp may or may not follow). MessageBus is already started
# at StartLiveCD line 112 before this point; start elogind + seatd + OpenSSH
# right after it too, so the seat/session stack and the ssh fallback are up
# regardless of which boot phase runs. SDDM is started LAST (after
# ConfigureLiveCD), so the interactive language/keymap dialog keeps tty1 for
# as long as the user needs it -- an early sddm steals tty1 and the dialog
# auto-finishes en_US in ~half a second (seen on the re-merged ISO). The tasks
# are all pgrep-guarded, so a later BootUp launch is a safe no-op.
sld="$TREE/Programs/LiveCD/$(basename "$(readlink "$TREE/Programs/LiveCD/Current" 2>/dev/null || echo 017.01)")/bin/StartLiveCD"
if [ -f "$sld" ]; then
    # Remove any earlier elogind/seatd/OpenSSH/SDDM lines so each block appears
    # exactly once no matter how many merges touched the file before.
    perl -0pi -e 's/\nmsg "Starting logind daemon"\s*\nStartTask Elogind\n/\n/; s/\nmsg "Starting seat daemon"\s*\nStartTask SeatD\n/\n/; s/\nmsg "Starting ssh daemon"\s*\nStartTask OpenSSH\n/\n/; s/\nmsg "Starting display manager"\s*\nStartTask SDDM\n/\n/' "$sld"
    # Early daemons right after 'StartTask MessageBus' (ssh fallback ASAP).
    if ! grep -q 'StartTask OpenSSH' "$sld"; then
        sed -i '/^StartTask MessageBus/a\msg "Starting logind daemon"\nStartTask Elogind\nmsg "Starting seat daemon"\nStartTask SeatD\nmsg "Starting ssh daemon"\nStartTask OpenSSH' "$sld"
    fi
    # Greeter LAST: after the language/keymap dialog and all the wizard steps,
    # so tty1 stays with the interactive dialog until the user is done.
    if ! grep -q 'StartTask SDDM' "$sld"; then
        cat >> "$sld" <<'EOF'

########################################
# Start the display manager (greeter)
########################################
msg "Starting display manager"
StartTask SDDM
echo "  live-boot report: sshd=$(pgrep -xc sshd || echo 0) sddm=$(pgrep -xc sddm || echo 0) seatd=$(pgrep -xc seatd || echo 0) elogind=$(pgrep -xc elogind || echo 0)"
echo "  overlay /run free: $(df -P /run 2>/dev/null | awk 'NR==2{print $4}') K"
EOF
        say "  greeter startup appended to ${sld#$TREE/}"
    fi
    chmod 755 "$sld"
    say "StartLiveCD: early Elogind+SeatD+OpenSSH, greeter last (idempotent)"
else
    say "WARNING: StartLiveCD not found ($sld)"
fi

# --- 12b) Boot debug setup (BootScripts.log + runtime/XDG state readback) ---------
# GoboLinux records a full boot trace when DEBUG is set in BootOptions
# (BootDriver -> bootlogd -l /Data/Variable/log/BootScripts.log). Enable it so
# every boot writes the log we read back from the live FS while diagnosing the
# elogind/seatd/sddm/sway stack. ASCII lower-case '=' separator comment.
bo_opt="$TREE/Programs/BootScripts/Settings/BootOptions"
if [ -f "$bo_opt" ]; then
    grep -q '^DEBUG=' "$bo_opt" || sed -i '1i # Debug boot: write /Data/Variable/log/BootScripts.log\nDEBUG=1' "$bo_opt"
    say "boot debug: DEBUG=1 set in $bo_opt (BootScripts.log)"
else
    say "WARNING: BootOptions not found ($bo_opt) - cannot enable boot debug"
fi

# Runtime-dir / seatd state readback. Writes a snapshot of /run/user, the
# elogind/seatd daemons and XDG_RUNTIME_DIR to a log we can read post-boot.
# Installed as a boot task so it runs after Elogind/SeatD/Messages start.
task_rt="$TREE/System/Tasks/BootDiagnostics"
cat > "$task_rt" <<'EOF'
#!/bin/sh
# BootDiagnostics: snapshot seat/logind/runtime-dir state for post-boot reading.
L=/Data/Variable/log/boot-diagnostics.log
mkdir -p /Data/Variable/log /run/user
{
    echo "==== boot-diagnostics $(date +%F_%T) ===="
    echo "-- /run/user --"; ls -ld /run/user /run/user/* 2>&1
    echo "-- /run/user mounts --"; mount | grep -E " /run" || echo "(no /run mounts)"
    echo "-- /run/user/1000 space --"; df -h /run/user/1000 2>&1
    echo "-- elogind --"; pgrep -a elogind || echo "(elogind not running)"
    echo "-- seatd --"; pgrep -a seatd || echo "(seatd not running)"
    echo "-- cgroup self-mount --"; findmnt /sys/fs/cgroup/elogind 2>/dev/null || mount | grep -E " /sys/fs/cgroup" || echo "(no cgroup mount)"
    echo "-- dbus login1 name owner --"; dbus-send --system --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.GetNameOwner string:org.freedesktop.login1 2>&1
    echo "-- loginctl sessions --"; loginctl list-sessions --no-legend 2>&1
    echo "-- XDG_RUNTIME_DIR --"; echo "${XDG_RUNTIME_DIR:-<unset>}"
    echo "-- /run/seatd.sock --"; ls -l /run/seatd.sock 2>&1
    echo "-- /dev/dri (need video-group 0660 for sway/gala) --"; ls -l /dev/dri/* 2>&1 | head
    echo "==== end ===="
} > "$L" 2>&1
echo "boot-diagnostics: wrote $L"
EOF
chmod 755 "$task_rt"
mkdir -p "$TREE/System/Tasks"
grep -q '^Exec .*BootDiagnostics' "$bootup" || \
    printf 'Exec "Writing boot diagnostics..."          BootDiagnostics\n' >> "$bootup"
say "installed BootDiagnostics task + DEBUG=1"

# --- 13) dbus launch helper at common FHS locations -------------------------------
helper_target="$TREE/System/Index/lib/dbus-daemon-launch-helper"
if [ -e "$helper_target" ]; then
    for d in usr/lib/dbus-1.0 usr/lib/dbus-1 lib/dbus-1; do
        mkdir -p "$TREE/$d"
        [ -e "$TREE/$d/dbus-daemon-launch-helper" ] || ln -s /System/Index/lib/dbus-daemon-launch-helper "$TREE/$d/dbus-daemon-launch-helper"
    done
    say "dbus launch helper linked into FHS paths"
fi

# --- 13b) Mutter/Gala/Pantheon library + session fixes -------------------------
# Fix the broken mutter-16 symlink in the Index (points to wrong relative path).
# The mutter-clutter/cogl/mtk libs live in lib/mutter-16/ subdirectory which the
# dynamic linker cannot find; create direct symlinks in the main lib dir.
mutter_ver=$(basename "$(readlink "$TREE/Programs/Mutter/Current" 2>/dev/null || echo Mutter/48.7)")
gala_ver=$(basename "$(readlink "$TREE/Programs/Gala/Current" 2>/dev/null || echo Gala/8.5.1)")
mutter_lib="$TREE/Programs/Mutter/$mutter_ver/lib"
mutter_sub="$mutter_lib/mutter-16"
idx_lib="$TREE/System/Index/lib"

# Re-create the mutter-16 Index symlink (may be broken from prior run)
if [ -d "$mutter_sub" ]; then
    rm -f "$idx_lib/mutter-16"
    ln -s "/Programs/Mutter/$mutter_ver/lib/mutter-16" "$idx_lib/mutter-16"
    # Direct symlinks for clutter/cogl/mtk so the linker finds them.  -sf, not
    # -e guarded: an earlier run's links are host-dangling (ISO-only targets),
    # so -e reads false and a guarded ln -s would hit "File exists".
    for so in libmutter-clutter-16.so libmutter-clutter-16.so.0 \
              libmutter-cogl-16.so libmutter-cogl-16.so.0 \
              libmutter-mtk-16.so libmutter-mtk-16.so.0; do
        ln -sf "/Programs/Mutter/$mutter_ver/lib/mutter-16/$so" "$idx_lib/$so"
    done
    say "mutter-16 sub-library symlinks fixed"
fi

# Ensure libgala and libmutter-16 are in the Index (should already exist from
# Compile, but be idempotent).
for so in libgala.so libgala.so.0 libmutter-16.so libmutter-16.so.0; do
    [ -e "$idx_lib/$so" ] || \
        ln -s "/Programs/Gala/$gala_ver/lib/$so" "$idx_lib/$so" 2>/dev/null || \
        ln -s "/Programs/Mutter/$mutter_ver/lib/$so" "$idx_lib/$so" 2>/dev/null || true
done

# Create pantheon.desktop session file if missing.  SDDM needs this to find the
# session; the base ISO ships SessionSettings but the xsessions/wayland-sessions
# symlinks may not resolve.
for d in "$TREE/usr/share/xsessions" "$TREE/usr/share/wayland-sessions"; do
    mkdir -p "$d"
    # -e follows symlinks: a host-dangling SessionSettings symlink reads as
    # missing here, but `cat >` through it would ENOENT.  Drop the stale entry
    # first so we always end with a real, writable file in the ISO.
    if [ ! -e "$d/pantheon.desktop" ]; then
        rm -f "$d/pantheon.desktop"
        cat > "$d/pantheon.desktop" <<'DESK'
[Desktop Entry]
Name=Pantheon
Comment=This session logs you into Pantheon
Exec=gnome-session --session=pantheon
Type=Application
DesktopNames=Pantheon
DESK
        say "created ${d#$TREE/}/pantheon.desktop"
    fi
done

# gnome-session can't find gsd-* binaries because they live in libexec which
# is NOT in PATH on GoboLinux.  Create symlinks in the Index bin directory so
# gnome-session's RequiredComponents resolution works.
gsd_dir="$TREE/System/Index/libexec"
idx_bin="$TREE/System/Index/bin"
if [ -d "$gsd_dir" ]; then
    gsd_count=0
    for bin in "$gsd_dir"/gsd-*; do
        [ -x "$bin" ] || continue
        bn=$(basename "$bin")
        [ -e "$idx_bin/$bn" ] || { ln -sf "/System/Index/libexec/$bn" "$idx_bin/$bn" && gsd_count=$((gsd_count + 1)); }
    done
    say "gsd-* symlinks created in Index/bin: $gsd_count"
fi

# --- 13c) libgsd.so — critical Pantheon fix -----------------------------------
# 13 of 16 gsd-* plugins (xsettings, power, keyboard, sound, etc.) link against
# libgsd.so which lives in a private subdir of GnomeSettingsDaemon.  The binaries
# have empty RPATH and libgsd.so is not in the ld.so.cache, so every
# RequiredComponent gsd-* crashes on load → gnome-session kills the session.
gsd_lib=$(find "$TREE/Programs/GnomeSettingsDaemon"/*/lib/gnome-settings-daemon-*/libgsd.so 2>/dev/null | head -1)
if [ -n "$gsd_lib" ]; then
    target="/${gsd_lib#$TREE/}"
    [ -e "$TREE/System/Index/lib/libgsd.so" ] || \
        ln -sf "$target" "$TREE/System/Index/lib/libgsd.so"
    say "libgsd.so linked into Index/lib (target: $target)"
else
    say "WARNING: libgsd.so not found — gsd-* plugins will crash"
fi

# --- 13d) D-Bus session bus for SDDM sessions ---------------------------------
# SDDM 0.18.1 does not auto-start the D-Bus session bus.  gnome-session 45+
# requires DBUS_SESSION_BUS_ADDRESS to be set, otherwise it fails immediately.
# Patch BOTH the Xsession (X11) and wayland-session (Wayland) launchers to wrap
# the session command with dbus-launch.
# NB: the Xsession script indents the final line (`    exec $@`); the
# wayland-session script does not.  Do NOT anchor at column 0 (`^exec ...`) or
# the Xsession patch silently never matches.
for scr in "Xsession" "wayland-session"; do
    sddm_scr="$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/$scr"
    [ -f "$sddm_scr" ] || continue
    # Per-type log so the X11 vs Wayland failure can be told apart.
    case "$scr" in
        Xsession)      sess_log="/Data/Variable/log/pantheon-x11-session.log" ;;
        wayland-session) sess_log="/Data/Variable/log/pantheon-wayland-session.log" ;;
        *)             sess_log="/Data/Variable/log/pantheon-session.log" ;;
    esac
    # Wrap the final launch so D-Bus is started AND output is captured.  The
    # Xsession script indents its last line with spaces; wayland-session does
    # not, so anchor on the enclosing whitespace-optional `exec $@`.
    if ! grep -q "dbus-launch.*exit-with-session" "$sddm_scr" 2>/dev/null; then
        # Replace the bare `exec $@` at the end with dbus-launch + log wrapper
        sed -i "s|^[[:space:]]*exec \\\$@\$|exec /usr/share/sddm/scripts/gobo-log-run $sess_log /System/Index/bin/dbus-launch --exit-with-session \"\$@\"|" "$sddm_scr"
        say "Patched SDDM $scr to start D-Bus bus + log to $sess_log"
    elif ! grep -q "gobo-log-run" "$sddm_scr" 2>/dev/null; then
        # Already dbus-launch-wrapped; add capture around it (idempotent guard).
        sed -i "s|^[[:space:]]*exec /System/Index/bin/dbus-launch --exit-with-session|exec /usr/share/sddm/scripts/gobo-log-run $sess_log /System/Index/bin/dbus-launch --exit-with-session|" "$sddm_scr"
        say "SDDM $scr already D-Bus; added log wrapper -> $sess_log"
    else
        say "SDDM $scr already patched for D-Bus + logging"
    fi
done

# --- 13e) D-Bus system policy: elogind + polkit own their bus names ------------
# The running dbus reads /System/Settings/dbus-1/system.d (this ISO's
# system.conf includedir) — NOT /etc/dbus-1 or Index/share/dbus-1.  Both
# elogind and polkit install their <name>.conf into Programs/<prog>/<ver>/share/
# but nothing links them where the bus scans, so:
#   * elogind: cannot own org.freedesktop.login1 -> bus disconnect -> silent
#              exit; sddm-helper then fails VT takeover ("Operation not
#              permitted") because no logind manages the seat.
#   * polkitd: cannot own org.freedesktop.PolicyKit1 -> pkexec/agent dead.
# Link each into its Program Settings tree (so a future merge repopulates the
# includedir) and directly into System/Settings/dbus-1/system.d.
for pair in \
    "Elogind:org.freedesktop.login1" \
    "Polkit:org.freedesktop.PolicyKit1"; do
    prog=${pair%%:*}; name=${pair#*:}
    ver=$(basename "$(readlink "$TREE/Programs/$prog/Current" 2>/dev/null)")
    src="$TREE/Programs/$prog/$ver/share/dbus-1/system.d/$name.conf"
    [ -f "$src" ] || { say "WARNING: $src missing - cannot install $prog dbus policy"; continue; }
    relsrc="/${src#$TREE/}"
    for d in "$TREE/Programs/$prog/Settings/dbus-1/system.d" "$TREE/System/Settings/dbus-1/system.d"; do
        mkdir -p "$d"
        ln -sfn "$relsrc" "$d/$name.conf"
    done
    say "$name.conf dbus policy linked for $prog (own=$name)"
done

# Guard: machine-id is absent on the base ISO; dbus/elogind/sd_id128 want it.
[ -s "$TREE/etc/machine-id" ] || \
    printf '%s\n' "$(umask 077 >/dev/null; od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" > "$TREE/etc/machine-id"

# --- 13f) VT1 console: only ENSURE the tty1 agetty when NO display manager ----
# On a `Boot=LiveCD` boot, BootDriver short-circuits with
#   [ "$modescript" = "LiveCD" ] && exec /bin/StartLiveCD
# at the S (PREVLEVEL=N) stage, replacing itself with StartLiveCD.
#
# The SDDM/Plasma6 ISO is the current target: SDDM 0.20.0 (Wayland build)
# HARDCODES its initial VT to tty1 at compile time and ignores [General] VT=,
# so block 6b deletes the tty1 agetty line to leave VT1 to the display manager
# (an inittab AutoLogin console on tty1 makes the console the controlling
# terminal of /dev/tty1 -> sddm's VT takeover fails EPERM and it crash-loops:
# "Failed to take control of /dev/tty1" / "sddm-helper exited with 5").  That
# restored in the VM session repeatedly and the fix only survived after the
# tty1 line was deleted AGAIN post-boot.  So when SDDM is present, 13f must be
# a no-op; the old "ensure tty1 agetty" behavior only applies when NO display
# manager exists (headless console ISO), to avoid a black frozen VT1.
if [ ! -d "$TREE/Programs/SDDM/$SDDM_VER" ]; then
live_inittab="$TREE/Programs/LiveCD/Settings/inittab"
if [ -f "$live_inittab" ]; then
    # Un-comment the tty1 getty line (removes any leading '#')
    if grep -qE '^[[:space:]]*#+[[:space:]]*1:2345:respawn:.*tty1 9600' "$live_inittab"; then
        sed -i -E 's|^([[:space:]]*)#+([[:space:]]*1:2345:respawn:.*tty1 9600)|\1\2|' "$live_inittab"
        say "inittab: re-enabled tty1 agetty+AutoLogin (VT1 console shell restored)"
    fi
    # Ensure it is actually present (guards against a mangled stock line)
    if ! grep -qE '^[[:space:]]*1:2345:respawn:.*tty1 9600' "$live_inittab"; then
        sed -i '/^[[:space:]]*#*[[:space:]]*1:2345:respawn:.*tty1 9600/d' "$live_inittab"
        sed -i '/^2:2345:respawn:.*tty2 9600/i\1:2345:respawn:/System/Index/bin/agetty --noclear -n -l /Programs/LiveCD/Current/bin/AutoLogin tty1 9600' "$live_inittab"
        say "inittab: inserted missing tty1 agetty line"
    fi
    grep -qE '^[[:space:]]*1:2345:respawn:.*tty1 9600' "$live_inittab" \
        && say "inittab: tty1..tty6 agetty+AutoLogin present (VT1 console shell OK)" \
        || say "WARNING: could not ensure tty1 agetty in $live_inittab"
fi
else
    say "inittab: NOT restoring tty1 agetty (SDDM owns VT1 on the Plasma ISO; 6b left it free)"
fi

# --- 14) 32-bit library symlink farm + ld.so.conf registration ----------------
# All Lib32 packages install .so files into Programs/Lib32-*/<ver>/lib32/.
# The dynamic linker needs a unified search path.  Create System/Index/lib32/
# with symlinks to every .so* in every Lib32/Glibc-32/Nvidia lib32 directory,
# then register it with ld.so.conf.d so both ld-linux.so.2 and ld-linux-x86-64.so.2 find them.
lib32_index="$TREE/System/Index/lib32"
mkdir -p "$lib32_index"
lib32_count=0
for libdir in "$TREE"/Programs/Lib32-*/*/lib32 \
              "$TREE"/Programs/Glibc-32/*/lib32 \
              "$TREE"/Programs/Nvidia/*/lib32; do
    [ -d "$libdir" ] || continue
    for f in "$libdir"/lib*.so*; do
        [ -e "$f" ] || continue
        bn=$(basename "$f")
        # Symlink target must be relative to / (the live rootfs), not $TREE.
        relpath="/${f#$TREE/}"
        [ -e "$lib32_index/$bn" ] || { ln -sf "$relpath" "$lib32_index/$bn" && lib32_count=$((lib32_count + 1)); }
    done
done
# Register with the dynamic linker
confd="$TREE/etc/ld.so.conf.d"
mkdir -p "$confd"
echo "/System/Index/lib32" > "$confd/00-lib32.conf"

# Create the i386-linux-gnu symlink the 32-bit ld-linux.so.2 searches as a
# hardcoded fallback path.  Without this, the 32-bit dynamic linker cannot
# find ANY lib32 library because the ld.so.cache doesn't include them and
# GoboLinux has no /lib/i386-linux-gnu or /usr/lib/i386-linux-gnu.
mkdir -p "$TREE/usr/lib"
[ -e "$TREE/usr/lib/i386-linux-gnu" ] || \
    ln -sf /System/Index/lib32 "$TREE/usr/lib/i386-linux-gnu"

# Also rebuild the ld.so.cache so 64-bit processes can find lib32 libs too.
# GoboLinux's ld.so.conf -> Programs/Glibc/Settings/ld.so.conf only lists
# /System/Links/Libraries (which doesn't exist in the rootfs).  Temporarily
# replace it with a conf that includes the standard paths + lib32, rebuild
# the cache with -r, then restore the original.
ld_so_conf="$TREE/etc/ld.so.conf"
ld_so_conf_bak="${ld_so_conf}.ldconfig-bak"
if [ -f "$ld_so_conf" ]; then
    cp "$ld_so_conf" "$ld_so_conf_bak"
    printf '/System/Index/lib\n/System/Index/lib64\n/System/Index/lib32\n' > "$ld_so_conf"
fi
ldconfig -r "$TREE" 2>/dev/null || true
if [ -f "$ld_so_conf_bak" ]; then
    mv "$ld_so_conf_bak" "$ld_so_conf"
fi
say "32-bit lib32 symlink farm created: $lib32_count symlinks in $lib32_index"

# --- 14b) Missing .desktop files and icons for user apps ----------------------
# Manifest recipes stage their .desktop/icon into the build Sources dir, but
# the manifest install only places manifest= entries, so Discord, Ren'Py and
# XIVLauncher never get menu entries.  The Gobo Installer entry ships only
# under the LiveCD's Users_gobo data (ISO session user is 'live', not 'gobo').
# Fix all four system-wide, plus Heroic and NVIDIA Settings; XDG menus read these.
say "Fixing missing .desktop files and icons..."

# Sources staging dir lives in the chroot rootfs -- the SIBLING of the merged
# tree (TREE/work/rootfs).  The old "$TREE/../rootfs" pointed back into the
# (empty) merged tree and made the Discord fix a silent no-op.
ISOSRC="$(dirname "$(dirname "$TREE")")/rootfs/Data/Compile/Sources"

# Discord — recipe stages Discord/discord.{desktop,png} in the source dir
discord_src="$ISOSRC/discord-1.0.152/Discord"
if [ ! -e "$TREE/usr/share/applications/discord.desktop" ]; then
    mkdir -p "$TREE/usr/share/applications" "$TREE/usr/share/pixmaps"
    [ -f "$discord_src/discord.desktop" ] && \
        cp "$discord_src/discord.desktop" "$TREE/usr/share/applications/discord.desktop"
    [ -f "$discord_src/discord.png" ] && \
        cp "$discord_src/discord.png" "$TREE/usr/share/pixmaps/discord.png"
    say "Discord .desktop + icon installed"
fi

# Ren'Py — same pattern, staged under usr/share/ by the recipe's pre_install
renpy_src="$ISOSRC/renpy-8.5.3-sdk/usr/share"
if [ ! -e "$TREE/usr/share/applications/renpy.desktop" ]; then
    mkdir -p "$TREE/usr/share/applications" "$TREE/usr/share/pixmaps"
    [ -f "$renpy_src/applications/renpy.desktop" ] && \
        cp "$renpy_src/applications/renpy.desktop" "$TREE/usr/share/applications/renpy.desktop"
    [ -f "$renpy_src/pixmaps/renpy.png" ] && \
        cp "$renpy_src/pixmaps/renpy.png" "$TREE/usr/share/pixmaps/renpy.png"
    say "Ren'Py .desktop + icon installed"
fi

# XIVLauncher (FFXIV) — same pattern: pre_install stages xivlauncher.{desktop,
# png} into the nupkg source dir (usr/share), but the manifest= list only
# installs lib + bin, so the menu entry/icon never reach the merged tree.
ffxiv_src="$ISOSRC/XIVLauncher-7.0.20-full.nupkg/usr/share"
if [ ! -e "$TREE/usr/share/applications/xivlauncher.desktop" ]; then
    mkdir -p "$TREE/usr/share/applications" "$TREE/usr/share/pixmaps"
    [ -f "$ffxiv_src/applications/xivlauncher.desktop" ] && \
        cp "$ffxiv_src/applications/xivlauncher.desktop" "$TREE/usr/share/applications/xivlauncher.desktop"
    [ -f "$ffxiv_src/pixmaps/xivlauncher.png" ] && \
        cp "$ffxiv_src/pixmaps/xivlauncher.png" "$TREE/usr/share/pixmaps/xivlauncher.png"
    say "XIVLauncher .desktop + icon installed"
fi

# Gobo Linux installer — the base ISO ships "Install GoboLinux.desktop" only
# under /Programs/LiveCD/.../Users_gobo (home of user 'gobo'), so it never
# appears for the 'live' session.  Surface it system-wide (Exec=/bin/Installer
# auto-picks the graphical Qt frontend under a display) with the installer's
# own que.png icon from the Installer program tree.
if [ ! -e "$TREE/usr/share/applications/install-gobolinux.desktop" ]; then
    mkdir -p "$TREE/usr/share/applications" "$TREE/usr/share/pixmaps"
    cat > "$TREE/usr/share/applications/install-gobolinux.desktop" <<'INSTALLEOF'
[Desktop Entry]
Name=Install GoboLinux
Comment=GoboLinux installer (graphical when run from a desktop session)
Exec=/bin/Installer
Icon=install-gobolinux
Terminal=false
Type=Application
Categories=System;Settings;
INSTALLEOF
    installer_icon="$TREE/Programs/Installer/Current/share/Installer/Images/que.png"
    [ -f "$installer_icon" ] && \
        cp "$installer_icon" "$TREE/usr/share/pixmaps/install-gobolinux.png"
    say "Install GoboLinux .desktop + icon installed"
fi

# Heroic — .desktop created by Recipe pre_install, icon in Program dir
heroic_icon="$TREE/Programs/Heroic/2.22.0/lib/heroic/resources/app.asar.unpacked/build/icon.png"
if [ ! -e "$TREE/usr/share/applications/heroic.desktop" ]; then
    mkdir -p "$TREE/usr/share/applications" "$TREE/usr/share/pixmaps"
    cat > "$TREE/usr/share/applications/heroic.desktop" <<'HEROICEOF'
[Desktop Entry]
Name=Heroic Games Launcher
Comment=Games launcher for GOG, Epic Games and Amazon Games
Exec=heroic
Icon=heroic
Terminal=false
Type=Application
Categories=Game;Network;
HEROICEOF
    [ -f "$heroic_icon" ] && \
        cp "$heroic_icon" "$TREE/usr/share/pixmaps/heroic.png"
    say "Heroic .desktop + icon installed"
fi

# NVIDIA Settings — .desktop and icon exist in Programs but aren't linked
nvidia_desktop="$TREE/Programs/Nvidia/580.159.04/Shared/applications/nvidia-settings.desktop"
nvidia_icon="$TREE/Programs/Nvidia/580.159.04/Shared/pixmaps/nvidia-settings.png"
if [ -f "$nvidia_desktop" ] && [ ! -e "$TREE/usr/share/applications/nvidia-settings.desktop" ]; then
    mkdir -p "$TREE/usr/share/applications" "$TREE/usr/share/pixmaps"
    ln -sf "/${nvidia_desktop#$TREE/}" "$TREE/usr/share/applications/nvidia-settings.desktop"
    [ -f "$nvidia_icon" ] && \
        ln -sf "/${nvidia_icon#$TREE/}" "$TREE/usr/share/pixmaps/nvidia-settings.png"
    say "NVIDIA Settings .desktop + icon linked"
fi

# --- 14b2) NVIDIA runtime enablement (pre-580-fix ISOs) ----------------------
# The 580 recipe's modprobe blacklist/options, boot-time module load rule and
# Xorg OutputClass used to live in the program's Settings/ dir, which
# CreatePackage never ships -- so the ISO boots WITHOUT loading the driver:
# nvidia-smi finds nothing and nvidia-settings shows no GPU on any NVIDIA box.
# Current recipes package them (do_install -> Resources/Unmanaged); for trees
# merged from older packages, lay the same three files down here (idempotent).
say "NVIDIA runtime enablement (enable driver at boot)"
if [ ! -s "$TREE/etc/modprobe.d/nvidia.conf" ] || \
   ! grep -q '^options nvidia-drm modeset=1' "$TREE/etc/modprobe.d/nvidia.conf" 2>/dev/null; then
    mkdir -p "$TREE/etc/modprobe.d"
    printf 'blacklist nouveau\noptions nvidia-drm modeset=1 fbdev=1\n' \
        > "$TREE/etc/modprobe.d/nvidia.conf"
    say "NVIDIA /etc/modprobe.d/nvidia.conf written (nouveau blacklist + modeset)"
fi
if [ ! -e "$TREE/etc/udev/rules.d/60-nvidia.rules" ] || \
   ! grep -q '0x10de' "$TREE/etc/udev/rules.d/60-nvidia.rules" 2>/dev/null; then
    mkdir -p "$TREE/etc/udev/rules.d"
    [ -e "$TREE/etc/udev/rules.d/60-nvidia.rules" ] || : > "$TREE/etc/udev/rules.d/60-nvidia.rules"
    cat >> "$TREE/etc/udev/rules.d/60-nvidia.rules" <<'NVRU'
# Boot-time load of the nvidia driver stack on real NVIDIA hardware (missing
# in pre-580-fix packages; the KERNEL== rules below only fire post-insert).
PCIEVENT="/bin/sh -c '/usr/bin/nvidia-modprobe -c 0 -m -u -d >/dev/null 2>&1 || true'"
SUBSYSTEM=="pci", ACTION=="add", ATTRS{vendor}=="0x10de", ATTR{class}=="0x030000", RUN+=$PCIEVENT
SUBSYSTEM=="pci", ACTION=="add", ATTRS{vendor}=="0x10de", ATTR{class}=="0x030200", RUN+=$PCIEVENT
NVRU
    say "NVIDIA udev PCI auto-load rules appended to 60-nvidia.rules"
fi
if [ ! -e "$TREE/usr/share/X11/xorg.conf.d/10-nvidia.conf" ]; then
    mkdir -p "$TREE/usr/share/X11/xorg.conf.d"
    cat > "$TREE/usr/share/X11/xorg.conf.d/10-nvidia.conf" <<'NVC'
Section "OutputClass"
    Identifier    "nvidia"
    MatchDriver   "nvidia-drm"
    Driver        "nvidia"
    Option        "AllowEmptyInitialConfiguration" "true"
    Option        "NoLogo" "true"
    Option        "ForceFullCompositionPipeline" "true"
    Option        "TripleBuffer" "true"
EndSection
NVC
    say "NVIDIA Xorg OutputClass written to /usr/share/X11/xorg.conf.d/10-nvidia.conf"
fi

# --- 14c) Update desktop database -----------------------------------------------------------------
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$TREE/usr/share/applications/" 2>/dev/null || true
    say "Desktop database updated"
fi

# --- 14d) Qt5Wayland integration --- (DISABLED: obsolete under Qt 5.15.2)
# The standalone Qt5Wayland 5.14.1 package this section used to wire up was
# built for the OLD Qt 5.14.1 stack. The ISO now runs Qt 5.15.2, which BUNDLES
# its own qtwayland module (libQt5WaylandClient/Compositor.so.5.15.2) AND its
# own wayland QPA platform plugins:
#   $TREE/Programs/Qt/5.15.2/plugins/platforms/libqwayland-{egl,generic,...}.so
# These self-consistent modules already satisfy the SDDM wayland greeter.
#
# Repointing /usr/lib/libQt5WaylandClient.so.5 at the OLD 5.14.1 module (as this
# section used to) caused a cross-version ABI mismatch: Qt 5.15.2's
# libqwayland-egl.so plugin NEEDs libQt5WaylandClient.so.5 and would load the
# incompatible 5.14.1 build -> greeter crash / undefined behaviour. Qt 5.15.2's
# own install already lands the correct .so.5 -> .so.5.15.2 link in /usr/lib.
say "Qt5Wayland: skipped (Qt 5.15.2 provides its own wayland modules + platform plugins)"

# --- 14e) Vulkan ICD registration + portal/libinput fixes ---------------------
# The Vulkan loader scans /usr/share/vulkan/icd.d/ for driver JSONs (Nvidia
# ships them under Resources/Unmanaged/usr).  EGL/glvnd vendor JSONs are owned
# by block 19 (authoritative /usr/share materialization), NOT here: /usr/share
# and glvnd are absolute symlinks that only resolve inside the ISO, so any
# ln/cp through them fails ENOENT on the host.  Vulkan JSONs are symlinked in.

icd_dir="$TREE/usr/share/vulkan/icd.d"             # -> /System/Index/share/vulkan/icd.d
mkdir -p "$icd_dir"
icd_count=0
for json in nvidia_icd.json nvidia_icd.x86_64.json nvidia_icd.i686.json; do
    f="$TREE"/Programs/Nvidia/*/Resources/Unmanaged/usr/share/vulkan/icd.d/$json
    if [ -f "$f" ]; then
        ln -sf "/${f#$TREE/}" "$icd_dir/$json"
        icd_count=$((icd_count + 1))
    fi
done
[ "$icd_count" -gt 0 ] && say "Vulkan ICDs linked ($icd_count)"

# xdg-desktop-portal-gtk: built as a libexec-only program; mother processes on
# a Wayland session look up the backend in /System/Index/libexec.
portal_gtk=$(find "$TREE/Programs/XDG-Desktop-Portal-GTK" -maxdepth 3 -name xdg-desktop-portal-gtk -type f 2>/dev/null | head -1)
if [ -n "$portal_gtk" ] && [ ! -e "$TREE/System/Index/libexec/xdg-desktop-portal-gtk" ]; then
    mkdir -p "$TREE/System/Index/libexec"
    ln -sf "/${portal_gtk#$TREE/}" "$TREE/System/Index/libexec/xdg-desktop-portal-gtk"
    say "xdg-desktop-portal-gtk linked into System/Index/libexec"
fi

# libinput: its udev rules (device groups + fuzz override) never made it to a
# live path. Mutter/Gala rely on libinput via udev for touchpads/input naming.
input_rules="$(find "$TREE"/Programs/LibInput -maxdepth 4 -path '*udev/rules.d' -type d 2>/dev/null | head -1)"
if [ -n "$input_rules" ]; then
    mkdir -p "$TREE/etc/udev/rules.d"
    for r in "$input_rules"/*.rules; do
        [ -f "$r" ] || continue
        ln -sf "/${r#$TREE/}" "$TREE/etc/udev/rules.d/$(basename "$r")"
    done
    say "libinput udev rules linked into /etc/udev/rules.d"
fi

# DRM device nodes: seatd grants a logind-style seat, and weston honors that
# seatd FD, but sway/gala/mutter's Mesa DRI2/EGL path re-opens /dev/dri/card0
# *directly* (libEGL: "failed to open /dev/dri/card0: Permission denied"). The
# default udev node is 0600 root:root, so the LCD's `live`/`sddm` users can't
# create an EGL context. Give the video group access (they are already in it).
mkdir -p "$TREE/etc/udev/rules.d"
drm_rules_file="$TREE/etc/udev/rules.d/50-drm-access.rules"
if [ ! -e "$drm_rules_file" ]; then
    cat > "$drm_rules_file" <<'EOF'
# DRM card + render nodes readable/writable by the video group so non-root
# Wayland compositors (sway, gala/mutter via EGL/DRI) can open them.
# NOTE: must use the NUMERIC gid (103) here, NOT the group NAME "video":
# udevd runs with --resolve-names=never, so it cannot resolve group names at
# runtime and the daemon would leave the node root:root. udevadm test shows
# gid=103 because it forces resolution, masking the real miss.
KERNEL=="card*", SUBSYSTEM=="drm", GROUP="103", MODE="0660", OPTIONS+="static_node=card0"
KERNEL=="renderD*", SUBSYSTEM=="drm", GROUP="103", MODE="0660"
EOF
    say "created 50-drm-access.rules (numeric gid 103/video owns DRM card/render nodes)"
fi

# ------------------------------------------------------------- 15. SSHD setup
# Enable password-based SSH login for the live ISO so users can ssh in.
# root password = 'root'
ROOT_HASH=$(openssl passwd -1 "root" 2>/dev/null || echo '$1$YkWcMQvG$srpADXE5KqFZDh8H1F./0/')
# live user password = 'live' (greeter login only; sudo is NOPASSWD below)
LIVE_HASH=$(openssl passwd -1 "live" 2>/dev/null || echo '$1$2uukQoHf$Hnryicp1FcOdoY6xNxXu31')
# Set root password
if grep -q '^root:' "$TREE/etc/shadow"; then
    sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$TREE/etc/shadow"
    say "set root password (root) for live SSH access"
fi
# Unlock and set live user password (was locked with '!')
if grep -q '^live:' "$TREE/etc/shadow"; then
    sed -i "s|^live:[^:]*:|live:${LIVE_HASH}:|" "$TREE/etc/shadow"
    say "set live user password (live)"
fi
# Add sshd PAM config (needed for password auth)
if [ ! -e "$TREE/etc/pam.d/sshd" ] && [ ! -L "$TREE/etc/pam.d/sshd" ]; then
    cat > "$TREE/etc/pam.d/sshd" <<'PAMEOF'
#%PAM-1.0
auth       include     system-login
account    include     system-login
password   include     system-login
session    include     system-login
PAMEOF
    say "created /etc/pam.d/sshd"
fi
# Ensure sshd_config allows password login
SSHD_CFG="$TREE/Programs/OpenSSH/Settings/ssh/sshd_config"
if [ -f "$SSHD_CFG" ]; then
    grep -q '^PasswordAuthentication' "$SSHD_CFG" || echo 'PasswordAuthentication yes' >> "$SSHD_CFG"
    grep -q '^PermitRootLogin' "$SSHD_CFG" || echo 'PermitRootLogin yes' >> "$SSHD_CFG"
    say "sshd_config: enabled PasswordAuthentication and PermitRootLogin"
fi

# ---- 15b) LiveCD user root access: passwordless sudo + polkit ---------------
# GParted / the Gobo GUI installer need root from the 'live' desktop session.
# sudo already ships (Programs/Sudo); give live NOPASSWD and fix the canonical
# sudoers mode/owner (Packages unpack as live:avahi 0644, which sudo dislikes).
SUDOERS_FILE="$TREE/Programs/Sudo/Settings/sudoers"
if [ -f "$SUDOERS_FILE" ]; then
    if ! grep -q '^live[[:space:]]' "$SUDOERS_FILE"; then
        printf '\n# LiveCD user: root for GParted / Gobo GUI installer (no password prompt)\nlive ALL=(ALL) NOPASSWD: ALL\n' >> "$SUDOERS_FILE"
        say "sudoers: live ALL=(ALL) NOPASSWD: ALL"
    fi
    chown root:root "$SUDOERS_FILE" 2>/dev/null || true
    chmod 440 "$SUDOERS_FILE" 2>/dev/null || true
fi
# pkexec-based launchers (GParted.desktop, Gobo installer) authenticate through
# polkitd; authorize live for any admin action with no prompt.
mkdir -p "$TREE/etc/polkit-1/rules.d"
if [ ! -f "$TREE/etc/polkit-1/rules.d/10-live.rules" ]; then
    cat > "$TREE/etc/polkit-1/rules.d/10-live.rules" <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (subject.user == "live") {
        return polkit.Result.YES;
    }
});
POLKIT
    say "polkit: live user may authorize any admin action (10-live.rules)"
fi

# --- 15c) Setuid-root sweep: sudo/pkexec/polkitd/unix_chkpwd/dbus helper ------
# Packages unpack as live:avahi with the setuid bit and root ownership lost, so
# every privileged helper breaks: sudo ("must be owned by uid 0"), pkexec
# ("must be setuid root"), polkitd (cannot drop to user 'polkitd'), PAM
# password checks (unix_chkpwd not root) and dbus service activation (the
# launch helper must be setuid root + owned by root).
# NOTE: Programs/<name>/Current is a SYMLINK into the version dir, and neither
# `chown -R <symlink>` nor plain `find <path>` follows it — those were silent
# no-ops.  Every helper below resolves Current with readlink -f first and acts
# on the real version dir.
progdir() { # <ProgramName> -> real Current dir ('' if absent)
    if [ -d "$TREE/Programs/$1" ]; then
        readlink -f "$TREE/Programs/$1/Current" 2>/dev/null
    fi
}

# sudo itself + its policy plug-ins must be root-owned; sudo binary setuid.
SUDO_DIR="$(progdir Sudo)"
if [ -n "$SUDO_DIR" ]; then
    chown root:root "$SUDO_DIR/bin/sudo" 2>/dev/null || true
    chmod 4755 "$SUDO_DIR/bin/sudo" 2>/dev/null || true
    if [ -d "$SUDO_DIR/lib/sudo" ]; then
        chown -R root:root "$SUDO_DIR/lib/sudo" 2>/dev/null || true
        chmod 755 "$SUDO_DIR"/lib/sudo/sudo/*.so 2>/dev/null || true
        chmod 755 "$SUDO_DIR"/lib/sudo/*.so* 2>/dev/null || true
    fi
    say "setuid: sudo + plug-ins root-owned"
fi
# pkexec / polkitd binaries must be root-owned; pkexec + agent-helper setuid.
POLKIT_DIR="$(progdir Polkit)"
if [ -n "$POLKIT_DIR" ]; then
    chown -R root:root "$POLKIT_DIR" 2>/dev/null || true
    chmod 4755 "$POLKIT_DIR/bin/pkexec" 2>/dev/null || true
    find "$POLKIT_DIR/lib" -name 'polkit-agent-helper-1' -exec chmod 4755 {} + 2>/dev/null || true
    say "setuid: pkexec + polkit-agent-helper-1"
fi
# PAM password checks (needed by sddm greeter login, su, sudo password path).
PAM_DIR="$(progdir Linux-PAM)"
if [ -n "$PAM_DIR" ]; then
    chown root:root "$PAM_DIR/sbin/unix_chkpwd" 2>/dev/null || true
    chmod 4755 "$PAM_DIR/sbin/unix_chkpwd" 2>/dev/null || true
    say "setuid: unix_chkpwd"
fi
# dbus service activation requires the setuid launch helper at
# <libdir>/dbus/dbus-daemon-launch-helper; refresh-index only publishes
# lib/dbus-1/, so mirror the missing Index/lib/dbus/ entry as an absolute
# symlink (exec through it honors the target's setuid bit).
DBUS_DIR="$(progdir DBus)"
if [ -n "$DBUS_DIR" ] && [ -e "$DBUS_DIR/lib/dbus-daemon-launch-helper" ]; then
    chown root:root "$DBUS_DIR/lib/dbus-daemon-launch-helper" 2>/dev/null || true
    chmod 4755 "$DBUS_DIR/lib/dbus-daemon-launch-helper" 2>/dev/null || true
    mkdir -p "$TREE/System/Index/lib/dbus"
    if [ ! -e "$TREE/System/Index/lib/dbus/dbus-daemon-launch-helper" ]; then
        ln -s /System/Index/lib/dbus-daemon-launch-helper "$TREE/System/Index/lib/dbus/dbus-daemon-launch-helper" 2>/dev/null && \
            say "dbus: indexed lib/dbus/dbus-daemon-launch-helper (setuid)"
    fi
fi
# polkitd drops privileges to a dedicated system user; the Gobo base ships a
# MALFORMED entry with an empty uid field (getpwnam fails -> "Error switching
# to user polkitd").  Replace it with a canonical uid 999 account.
if grep -q '^polkitd:' "$TREE/etc/passwd" 2>/dev/null; then
    sed -i '/^polkitd:/d' "$TREE/etc/passwd"
    echo 'polkitd:x:999:999:PolicyKit daemon:/var/empty:/sbin/nologin' >> "$TREE/etc/passwd"
    sed -i '/^polkitd:/d' "$TREE/etc/shadow"
    echo 'polkitd:*:19700:0:99999:7:::' >> "$TREE/etc/shadow"
    say "polkit: fixed polkitd system user (uid 999)"
fi

# --- 16) Wingpanel autostart ---------------------------------------------------
# wingpanel is NOT in pantheon.session's RequiredComponents and no autostart
# entry ships anywhere in the tree, so the top bar never appears.  Add one.
wingpanel_autostart="$TREE/etc/xdg/autostart/io.elementary.wingpanel.desktop"
if [ -x "$TREE/System/Index/bin/io.elementary.wingpanel" ]; then
    mkdir -p "$(dirname "$wingpanel_autostart")"
    if [ ! -e "$wingpanel_autostart" ]; then
        cat > "$wingpanel_autostart" <<'WINGDESK'
[Desktop Entry]
Type=Application
Name=Wingpanel
Comment=Top panel that holds indicators and the applications menu
Exec=io.elementary.wingpanel
Icon=io.elementary.wingpanel
Terminal=false
OnlyShowIn=Pantheon;
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Panel
WINGDESK
        say "created wingpanel autostart in /etc/xdg/autostart"
    fi
else
    say "WARNING: io.elementary.wingpanel not on PATH — top bar will be missing"
fi

# --- 17) Polkit authentication agent autostart --------------------------------
# io.elementary.desktop.agent-polkit ships NO autostart entry in the tree, so
# no PolicyKit prompt would ever appear.  Add one pointing at the (live) agent
# binary.  polkitd is provided by Programs/Polkit (built with full polkitd +
# elogind session tracking) and autostarts via dbus system-services
# org.freedesktop.PolicyKit1.service.
if find "$TREE"/Programs/PantheonPolkitAgent -name 'io.elementary.desktop.agent-polkit' -type f 2>/dev/null | grep -q .; then
    pk_autostart="$TREE/etc/xdg/autostart/io.elementary.desktop.agent-polkit.desktop"
    mkdir -p "$(dirname "$pk_autostart")"
    if [ ! -e "$pk_autostart" ]; then
        cat > "$pk_autostart" <<'PKDESK'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent
Exec=/usr/libexec/policykit-1-pantheon/io.elementary.desktop.agent-polkit
Terminal=false
NoDisplay=true
OnlyShowIn=Pantheon;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Panel
PKDESK
        say "created polkit agent autostart in /etc/xdg/autostart"
    fi
else
    say "WARNING: PantheonPolkitAgent not found — no polkit prompt agent"
fi

# --- 18) Ensure the Wayland session file targets the Wayland compositor --------
# pantheon-wayland.session requires the 'gala-wayland' component (gala run as a
# native Wayland compositor).  The bare 'pantheon.session' requires 'gala' and
# runs under X11.  If the Wayland session file exists, make sure it picks the
# Wayland session so a Wayland login doesn't silently fall back to X11 gala.
wl_pantheon="$TREE/usr/share/wayland-sessions/pantheon.desktop"
if [ -e "$wl_pantheon" ]; then
    if ! grep -q -- '--session=pantheon-wayland' "$wl_pantheon"; then
        sed -i 's|--session=pantheon|--session=pantheon-wayland|' "$wl_pantheon"
        say "wayland-sessions/pantheon.desktop now runs gnome-session --session=pantheon-wayland"
    fi
fi

# --- 19) GLVND EGL vendor files (authoritative, /usr/share) -------------------
# glvnd discovers EGL drivers by scanning /usr/share/glvnd/egl_vendor.d/*.json.
# /usr/share is a RELATIVE symlink to ../System/Index/share, so the loader
# resolves /usr/share/glvnd to /System/Index/share/glvnd at runtime.  Both the
# current `usr/share/glvnd` and `System/Index/share/glvnd` are ABSOLUTE symlinks
# into the Mesa program tree (/Programs/Mesa/<v>/share/glvnd) whose targets only
# exist inside the ISO — on the host they dangle, which is why earlier ln/cp
# here failed ENOENT with a misleading "File exists" from mkdir.  Fix: replace
# those symlinks with a REAL merged dir under System/Index/share and link in
# Mesa (current-version, authoritative) + Nvidia vendor JSONs.  Nvidia jsons are
# only added when its driver libraries exist (real GPUs get hardware EGL; under
# QEMU glvnd fails to dlopen them and keeps Mesa).  Idempotent and host-safe:
# never dereferences an ISO-only absolute symlink.
GLVND_DIR="$TREE/System/Index/share/glvnd"          # == /usr/share/glvnd in the ISO
VENDOR_DIR="$GLVND_DIR/egl_vendor.d"
for stale in "$GLVND_DIR" "$TREE/usr/share/glvnd"; do
    [ -L "$stale" ] && rm -f "$stale" && say "EGL vendor: dropped stale ${stale#$TREE/} symlink"
done
mkdir -p "$VENDOR_DIR"
rm -f "$VENDOR_DIR"/*.json
MESA_VENDOR="$TREE/Programs/Mesa/Current/share/glvnd/egl_vendor.d/50_mesa.json"
[ -f "$MESA_VENDOR" ] || MESA_VENDOR="$TREE/Programs/Mesa/25.3.6/share/glvnd/egl_vendor.d/50_mesa.json"
if [ -f "$MESA_VENDOR" ]; then
    rm -f "$VENDOR_DIR/50_mesa.json"
    ln -sf "/${MESA_VENDOR#$TREE/}" "$VENDOR_DIR/50_mesa.json"
    say "EGL vendor: linked Mesa/Current 50_mesa.json"
else
    cat > "$VENDOR_DIR/50_mesa.json" <<'JSON'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_mesa.so.0"
    }
}
JSON
    say "EGL vendor: wrote known-good 50_mesa.json (no Mesa share present in tree)"
fi
NV_VENDOR_DIR="$TREE/Programs/Nvidia/Current/Resources/Unmanaged/usr/share/glvnd/egl_vendor.d"
if [ -d "$NV_VENDOR_DIR" ] && ls "$TREE"/Programs/Nvidia/Current/lib/libEGL_nvidia.so.* >/dev/null 2>&1; then
    for j in "$NV_VENDOR_DIR"/10_nvidia.json "$NV_VENDOR_DIR"/10_nvidia_wayland.json \
             "$NV_VENDOR_DIR"/15_nvidia_gbm.json "$NV_VENDOR_DIR"/20_nvidia_xcb.json \
             "$NV_VENDOR_DIR"/20_nvidia_xlib.json; do
        [ -f "$j" ] || continue
        rm -f "$VENDOR_DIR/$(basename "$j")"
        ln -sf "/${j#$TREE/}" "$VENDOR_DIR/$(basename "$j")"
    done
    say "EGL vendor: linked Nvidia vendor jsons"
fi

# --- 30) Plasma6/KF6 Qt6 runtime search-path integration ---------------------
# Symptom (QEMU debug): plasmashell fails with
#   module "org.kde.kirigami" is not installed
#   kf.package: Invalid metadata for package structure "Plasma/Shell"
#   kf.windowsystem: Could not find any platform plugin
# Two causes:
#   a) Qt6 resolves QT_INSTALL_QML=/Programs/QtBase/<v>/qml and QT_INSTALL_PLUGINS
#      =/Programs/QtBase/<v>/plugins (no qt.conf), so KF6 modules/plugins are
#      invisible unless QT_PLUGIN_PATH + QML_IMPORT_PATH are exported and the
#      Index qml tree at /System/Index/lib/qml is complete.
#   b) the Index lib/qml mirror picks the wrong/wrong program for some modules:
#      org.kde.kirigami resolves to LibPlasma's lib/qml/org/kde/kirigami (only
#      a "styles" stub, no qmldir, so the REAL Kirigami module is shadowed) and
#      org.kde.kwindowsystem is missing entirely.
# Repair: re-link every namespaced module directory that CONTAINS a qmldir into
# /System/Index/lib/qml (last-valid-wins; stub dirs with no qmldir are skipped),
# bridge the KDE namespace into QtBase's own qml dir, and export the search
# paths from the SDDM session scripts + a profile.d snippet.
QML_INDEX="$TREE/System/Index/lib/qml"
mkdir -p "$QML_INDEX"
QML_FIXED=0
for broot in "$TREE"/Programs/*/*/qml "$TREE"/Programs/*/*/lib/qml; do
    [ -d "$broot" ] || continue
    while IFS= read -r -d "" qmldirf; do
        rel="${qmldirf#"$broot"/}"
        mod="${rel%/qmldir}"
        case "$mod" in */*) ;; *) continue ;; esac    # skip top-level QtQuick/...
        tgt="$QML_INDEX/$mod"
        src="/${qmldirf#$TREE/}"; src="${src%/qmldir}"
        mkdir -p "$(dirname "$tgt")"
        if [ -L "$tgt" ]; then
            rm -f "$tgt"
        elif [ -d "$tgt" ]; then
            # already a real module dir (per-file Index build): keep it
            [ -e "$tgt/qmldir" ] && continue
            mv -f "$tgt" "$tgt.livefix.old.$$" 2>/dev/null || rm -rf "$tgt"
        elif [ -e "$tgt" ]; then
            rm -f "$tgt"
        fi
        if [ ! -e "$tgt" ]; then
            ln -s "$src" "$tgt" && QML_FIXED=$((QML_FIXED + 1))
        fi
    done < <(find "$broot" -name qmldir -print0 2>/dev/null)
done
[ "$QML_FIXED" -gt 0 ] && say "qml Index: linked $QML_FIXED KF6/KDE modules under ${QML_INDEX#$TREE/}"

# The namespaced loop above skips top-level modules (QtCore/QtQml/...).  The
# build-time merge normally mirrors them from QtDeclarative, but if any are
# absent the KCM System-Settings pages break with
#   qrc:/kcm/kcm_*/main.qml:module "QtCore" is not installed
# (themes / colors / application style / plasma style / pointers / sounds all
# load through kcm qrc files that `import QtCore`).  Mirror any missing
# top-level Qt6 module from QtDeclarative as a last resort.
for m in QtCore QtQml QtQuick QtNetwork QtTest; do
    [ -e "$QML_INDEX/$m/qmldir" ] && continue
    for src in "$TREE"/Programs/QtDeclarative/*/qml/$m; do
        [ -d "$src" ] && [ -e "$src/qmldir" ] || continue
        ln -s "/${src#$TREE/}" "$QML_INDEX/$m"
        say "qml Index: linked top-level $m (missing KCM Qt6 module)"
        break
    done
done

# Qt6's compiled-in QT_INSTALL_QML stays /Programs/QtBase/<v>/qml; bridge the
# KDE namespace into it so org.kde.* imports also resolve with no env at all.
# QtBase does NOT ship a qml/ dir at all (the modules live in QtDeclarative
# etc.), so create it first or the bridge below silently never happens.
QT6_QML="$TREE/Programs/QtBase/6.10.3/qml"
mkdir -p "$QT6_QML"
if [ ! -e "$QT6_QML/org" ]; then
    ln -s /System/Index/lib/qml/org "$QT6_QML/org"
    say "Qt6 qml: bridged ${QT6_QML#$TREE/}/org -> /System/Index/lib/qml/org"
fi

# Export Qt6 search paths from the SDDM session scripts (the whole Plasma
# session runs under them) and via profile.d for interactive shells.
sddm_scripts="$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts"
for SC in "$sddm_scripts/wayland-session" "$sddm_scripts/Xsession"; do
    [ -f "$SC" ] || continue
    if ! grep -q 'QT_PLUGIN_PATH=/System/Index/lib/plugins' "$SC"; then
        sed -i '1a export QT_PLUGIN_PATH="/System/Index/lib/plugins:/Programs/Qt/5.15.2/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"\nexport QML2_IMPORT_PATH="/System/Index/lib/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"\nexport QML_IMPORT_PATH="/System/Index/lib/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"' "$SC"
        say "session script: exported Qt6/KF6 search paths (${SC#$TREE/})"
    fi
done
if [ ! -f "$TREE/etc/profile.d/plasma-qt6.sh" ]; then
    mkdir -p "$TREE/etc/profile.d"
    cat > "$TREE/etc/profile.d/plasma-qt6.sh" <<'EOF'
# Plasma6/KF6 Qt6 runtime search paths (LiveCD).  The Index dir is Qt6-ABI only,
# so Qt5 GUI apps (pinentry-qt, spawned by gobonet's dialogs) must also see the
# Qt5 plugin tree or they abort with "Could not find the Qt platform plugin xcb"
# (they find the Qt6 libqxcb in Index, reject it, and never reach the Qt5 one).
export QT_PLUGIN_PATH="/System/Index/lib/plugins:/Programs/Qt/5.15.2/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QML2_IMPORT_PATH="/System/Index/lib/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="/System/Index/lib/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
EOF
    say "wrote /etc/profile.d/plasma-qt6.sh"

    # Qt/Wayland runtime pick (the real-hardware gobonet "EGL Wayland" crash
    # fix).  The qtwayland platform plugins exist and ldd-clean (proven on the
    # ISO), so the failure is NOT a missing package -- it is Qt not being told
    # which platform to use.  Under a Wayland session we must override the
    # default plugin (eglfs/xcb) with wayland/xcb, else gobonet and the
    # update-checker die with "EGL error: ... Wayland" / blank window, which
    # the user reported as "Network not working / can't update" on real hw.
    # Only force wayland when WAYLAND_DISPLAY is actually set (a real compositor
    # is up); otherwise fall back to xcb so the app still runs over XWayland.
    if ! grep -q 'QT_QPA_PLATFORM' "$TREE/etc/profile.d/plasma-qt6.sh" 2>/dev/null; then
        cat >> "$TREE/etc/profile.d/plasma-qt6.sh" <<'ENVO'
# Qt platform pick: prefer Wayland when a compositor is present, else X11.
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/Data/Variable/run}/$WAYLAND_DISPLAY" ]; then
    export QT_QPA_PLATFORM="wayland${QT_QPA_PLATFORM:+:$QT_QPA_PLATFORM}"
    export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
else
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
fi
ENVO
        say "plasma-qt6.sh: baked Qt Wayland/xcb platform pick (real-hw gobonet EGL-Wayland fix)"
    else
        say "plasma-qt6.sh: Qt platform pick already present"
    fi
fi

# Qt platform-plugin family merge into the dir the baked QT_PLUGIN_PATH actually
# searches: /System/Index/lib/plugins/platforms.  On a fresh merge that dir is
# EMPTY (worse: absent), while the platform plugins Qt needs to load live under
# Programs/QtBase/Current/plugins/platforms and Programs/Qt/Current/plugins/
# platforms (PROVEN on the ISO verbatim: libqxcb.so libqoffscreen.so
# libqminimal.so all SHIPPED in both trees).  Qt is told QT_PLUGIN_PATH=/System/
# Index/lib/plugins -- so it searches THERE, finds no platforms/ subtree, falls
# back to its compiled-in auto-search, and only the Wayland family surfaces
# (real-hardware gobonet: "Could not find xcb"; "available platform plugins are:
# wayland-egl, wayland, wayland-xcomposite-glx, webgl").  Idempotent: only
# copies when the Index copy is missing; never clobbers an existing platform so
# re-running livefix is safe.
IPF="$TREE/System/Index/lib/plugins/platforms"
IPF="$TREE/System/Index/lib/plugins/platforms"
mkdir -p "$IPF"
for qtp_d in Programs/QtBase/Current/plugins/platforms Programs/Qt/Current/plugins/platforms \
             Programs/QtBase/*/plugins/platforms Programs/Qt/*/plugins/platforms; do
    [ -d "$TREE/$qtp_d" ] || continue
    for qplug in libqxcb.so libqoffscreen.so libqminimal.so; do
        [ -e "$TREE/$qtp_d/$qplug" ] || continue
        if [ ! -e "$IPF/$qplug" ]; then
            cp -a "$TREE/$qtp_d/$qplug" "$IPF/$qplug"
            say "qt-plugins: merged $qplug from ${qtp_d%/*} -> Index"
        fi
    done
done

# THE GAP: profile.d is DEAD on this tree — there is no /etc/profile, no
# /etc/zsh/zprofile, and zshrc only sources GoboPath + /System/Environment/Cache.
# So NOTHING sources plasma-qt6.sh: interactive shells (ssh/tty/konsole) start
# without QT_PLUGIN_PATH/QML_IMPORT_PATH, and any Qt6/KF6 app launched from a
# shell fails with `module "org.kde.kirigami" is not installed` (System
# Settings sidebar: "Fatal error while loading the sidebar view qml component").
# The desktop itself only works because wayland-session/Xsession export the
# vars.   Bake the vars into Gobo's Environment machinery instead: zshrc cats
# every /System/Environment/*--* entry into Cache, and that Cache is what shells
# source.  Ship a new env entry AND patch the bundled Cache so already-baked
# boots get it without waiting for a Cache regeneration.
QML_EXPORTS='
export QT_PLUGIN_PATH="/System/Index/lib/plugins:/Programs/Qt/5.15.2/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QML2_IMPORT_PATH="/System/Index/lib/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export QML_IMPORT_PATH="/System/Index/lib/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
'
ENVDIR="$TREE/System/Environment"
mkdir -p "$ENVDIR"
if [ ! -f "$ENVDIR/Plasma6--LiveCD" ]; then
    printf '%s\n' "$QML_EXPORTS" > "$ENVDIR/Plasma6--LiveCD"
    say "wrote ${ENVDIR#$TREE/}/Plasma6--LiveCD (Qt6/KF6 search paths for ALL shells)"
fi
if [ -f "$ENVDIR/Cache" ] && ! grep -q '^export QML_IMPORT_PATH=' "$ENVDIR/Cache"; then
    cp "$ENVDIR/Cache" "$ENVDIR/Cache.livefix.old"
    printf '%s\n' "$QML_EXPORTS" >> "$ENVDIR/Cache"
    say "patched ${ENVDIR#$TREE/}/Cache with Qt6/KF6 search paths"
fi

# --- 31) Plasma session glue: single-token Exec, Xwayland dir, swrast GL -------
# Four separate QEMU findings, each only survives a fresh boot if it is baked
# into the tree here (everything else gets re-applied by hand per session):
#
# a) SDDM 0.20.0 runs the session command as ONE argv element; a two-token
#    Exec= in plasma.desktop ("plasma-dbus-run-session-if-needed
#    startplasma-wayland") trips the same multi-token bug block 9 unquotes for
#    wayland-session, so the Plasma (Wayland) entry would not start the shell.
#    Wrap it in a single-token shim and point the .desktop Exec at the shim.
# b) kwin_xwl refuses to start Xwayland when /tmp/.X11-unix does not exist
#    ("Failed to create Xwayland connection sockets").  Ensure it per session.
# c) Under the QEMU virtio-gpu driver the ABI EGL KMS screen fails
#    ("egl: failed to create dri2 screen", no wl_output advertised) until Mesa
#    is forced to the llvmpipe softpipe -- the compositor then advertises the
#    output and plasmashell starts in ~15s.  Only force swrast when the DRM
#    driver is a virtualized one; real GPUs (i915/amdgpu/nvidia) keep HW GL.
# d) The Plasma desktop FolderView shows ~/Desktop: an empty Desktop means
#    "no icons" and Kickoff menus are empty while /etc/xdg/menus/launchers
#    lacks applications.menu.  Seed the live Desktop + install the menu.
# e) Plasma-Workspace ships its autostart .desktop entries only in the
#    program tree (etc/xdg/autostart/org.kde.plasmashell.desktop etc), but
#    the session (ksmserver/plasma_session) scans the GLOBAL config autostart
#    dir (/etc/xdg/autostart -> /System/Settings/xdg/autostart), which has no
#    Plasma entries -- so plasmashell NEVER auto-starts: kwin_wrapper+ksmserver
#    run, the screen stays black, and plasmashell only appears when launched by
#    hand.  Symlink the entries into the global dir.

PW_VER=$(basename "$(readlink "$TREE/Programs/Plasma-Workspace/Current" 2>/dev/null || echo 6.7.4)")
PW_ROOT="$TREE/Programs/Plasma-Workspace/$PW_VER"

# (a) single-token session shim
PW_ABS="/Programs/Plasma-Workspace/$PW_VER"
if [ -d "$PW_ROOT" ]; then
    pw_shim="$PW_ROOT/libexec/plasma-session"
    # Re-generate when missing OR when a stale build chrooted the host path
    # ($TREE) into an existing shim -- /mnt/... does not exist in the guest,
    # so sddm autologin then black-screens (session Exec ENOENT).
    if [ ! -f "$pw_shim" ] || grep -qE '/mnt/|/home/|PW_ROOT' "$pw_shim"; then
        mkdir -p "$(dirname "$pw_shim")"
        cat > "$pw_shim" <<EOF
#!/bin/sh
# single-token shim: SDDM 0.20.0 passes the session command as one argv token
# ("plasma-dbus-run-session-if-needed /Programs/.../bin/startplasma-wayland");
# dbus-launch then execs a single filename with a space and dies.  Exec'ing the
# real (multi-token) command from inside the shim keeps the .desktop Exec
# single-token while still launching the full session.
exec "/Programs/Plasma-Workspace/$PW_VER/libexec/plasma-dbus-run-session-if-needed" "/Programs/Plasma-Workspace/$PW_VER/bin/startplasma-wayland"
EOF
        chmod 755 "$pw_shim"
        say "created single-token plasma session shim ${pw_shim#$TREE/}"
    fi
    pw_desktop="$PW_ROOT/share/wayland-sessions/plasma.desktop"
    # Canonical Exec= is the ABSOLUTE iso path; rewrite stale/relative forms.
    if [ -f "$pw_desktop" ] && ! grep -q "^Exec=$PW_ABS/libexec/plasma-session" "$pw_desktop"; then
        sed -i "s|^Exec=.*|Exec=$PW_ABS/libexec/plasma-session|" "$pw_desktop"
        say "wayland-sessions/plasma.desktop Exec -> absolute single-token shim"
    fi

    # (e) global autostart links (plasmashell.desktop, session-restore, etc).
    if [ -d "$PW_ROOT/etc/xdg/autostart" ]; then
        XDG_AUTOSTART_DIR="$TREE/System/Settings/xdg/autostart"
        mkdir -p "$XDG_AUTOSTART_DIR"
        for f in "$PW_ROOT"/etc/xdg/autostart/*.desktop; do
            [ -e "$f" ] || continue
            ln -sf "/${f#$TREE/}" "$XDG_AUTOSTART_DIR/$(basename "$f")"
            # KDE autostart policy skips ANY system-wide .desktop entry that is
            # neither root-owned NOR executable ("Access ... denied, not owned by
            # root and executable flag not set").  Packages are extracted as
            # live:avahi, so without +x plasmashell/xembedsniproxy never launch
            # and the session is a black screen with a working cursor.  chmod
            # follows the symlink to the target, so this fixes the copied file in
            # the program tree (and the global link at the same time).
            chmod +x "$f" 2>/dev/null
        done
        say "linked + executable-bit Plasma autostart entries into /System/Settings/xdg/autostart"
    fi
fi

# (b) Xwayland socket dir + (c) swrast GL env, in the SDDM session scripts.
# Reuse the block-30 export anchor (insert right below the Qt6 path exports).
for SC in "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/wayland-session" \
          "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/Xsession"; do
    [ -f "$SC" ] || continue
    # Patch old guard (missing virtio-pci) so the existing frag is usable as-is
    # on re-merge; QEMU's virtio-gpu uevent DRIVER=virtio-pci, not virtio_gpu.
    sed -i 's/virtio_gpu|qxl|bochs-drm|vmwgfx|vboxvideo/virtio-pci|virtio_gpu|qxl|bochs-drm|vmwgfx|vboxvideo/g' "$SC" 2>/dev/null || true
    if ! grep -q 'GBM_ALWAYS_SOFTWARE' "$SC"; then
        # Robust splice: insert fragment before the last line starting with 'exec'.
        python3 - "$SC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().splitlines()
frag = """
# Virtualized GPU (QEMU virtio/qxl/bochs/vmwgfx/vbox): force Mesa softpipe so
# the EGL KMS screen -- which fails to create under virtio ("dri2 screen") --
# falls back to llvmpipe and KWin advertises a wl_output.  Real drivers keep
# their hardware GL paths (LIBGL/GBM vars stay unset).
# NOTE: QEMU's virtio-gpu PCI device reports DRIVER=virtio-pci (not virtio_gpu)
# in /sys/class/drm/card0/device/uevent, so virtio-pci must be in the match list.
if [ -d /sys/class/drm ]; then
    for ue in /sys/class/drm/card*/device/uevent; do
        [ -r "$ue" ] || continue
        case "$(sed -n 's/^DRIVER=//p' "$ue" | head -1)" in
            virtio-pci|virtio_gpu|qxl|bochs-drm|vmwgfx|vboxvideo)
                export GBM_ALWAYS_SOFTWARE=1
                export LIBGL_ALWAYS_SOFTWARE=1
                export GALLIUM_DRIVER=llvmpipe
                break
                ;;
        esac
    done
fi
mkdir -p /tmp/.X11-unix 2>/dev/null && chmod 1777 /tmp/.X11-unix 2>/dev/null || true
"""
last = max(i for i, l in enumerate(s) if l.lstrip().startswith('exec'))
s[last:last] = frag.splitlines()
open(p, 'w').write('\n'.join(s) + '\n')
PY
        say "session script: swrast-GL env + /tmp/.X11-unix ensure (${SC#$TREE/})"
    fi
done

# c) also mirror the swrast GL env into interactive shells (sshd/manual runs)
# Patch old guard first (same virtio-pci fix).
sed -i 's/virtio_gpu|qxl|bochs-drm|vmwgfx|vboxvideo/virtio-pci|virtio_gpu|qxl|bochs-drm|vmwgfx|vboxvideo/g' "$TREE/etc/profile.d/plasma-qt6.sh" 2>/dev/null || true
if ! grep -q 'GBM_ALWAYS_SOFTWARE' "$TREE/etc/profile.d/plasma-qt6.sh" 2>/dev/null; then
    mkdir -p "$TREE/etc/profile.d"
    cat >> "$TREE/etc/profile.d/plasma-qt6.sh" <<'GL'
# Force Mesa softpipe for virtualized GPUs only (real HW keeps HW GL).
# NOTE: QEMU virtio-gpu reports DRIVER=virtio-pci in uevent (not virtio_gpu).
if [ -d /sys/class/drm ]; then
    for ue in /sys/class/drm/card*/device/uevent; do
        [ -r "$ue" ] || continue
        case "$(sed -n 's/^DRIVER=//p' "$ue" | head -1)" in
            virtio-pci|virtio_gpu|qxl|bochs-drm|vmwgfx|vboxvideo)
                export GBM_ALWAYS_SOFTWARE=1
                export LIBGL_ALWAYS_SOFTWARE=1
                export GALLIUM_DRIVER=llvmpipe
                break
                ;;
        esac
    done
fi
GL
    say "profile.d: added virtualized-GPU swrast GL env"
fi

# d) applications menu + seeded Desktop so the shell actually SHOWS icons.
#    Plasma-Workspace ships etc/xdg/menus/plasma-applications.menu; the plain
#    applications.menu name is what KService/kickoff resolves without
#    XDG_MENU_PREFIX, and its absence logs "applications.menu not found".
if [ -f "$PW_ROOT/etc/xdg/menus/plasma-applications.menu" ]; then
    mkdir -p "$TREE/etc/xdg/menus"
    menu_live="$TREE/etc/xdg/menus/applications.menu"
    menu_tgt="/${PW_ROOT#$TREE/}/etc/xdg/menus/plasma-applications.menu"
    # -L/-e so a host-dangling link from a previous run is not re-created.
    if [ ! -e "$menu_live" ] && [ ! -L "$menu_live" ]; then
        ln -s "$menu_tgt" "$menu_live"
        say "linked /etc/xdg/menus/applications.menu -> plasma-applications.menu"
    fi
fi
seed_desktop() {
    local d="$1"
    mkdir -p "$d"
    [ -f "$d/.directory" ] || printf '[Desktop Entry]\nIcon=folder\nType=Directory\n' > "$d/.directory"
    [ -f "$d/README-Gobo.txt" ] || printf '%s\n' 'GoboLinux Plasma LiveCD -- right-click to customize.' > "$d/README-Gobo.txt"
    [ -f "$d/dolphin.desktop" ] || cat > "$d/dolphin.desktop" <<'DE'
[Desktop Entry]
Name=Dolphin File Manager
Type=Application
Exec=dolphin
Icon=system-file-manager
Terminal=false
DE
    [ -f "$d/konsole.desktop" ] || cat > "$d/konsole.desktop" <<'DE'
[Desktop Entry]
Name=Konsole Terminal
Type=Application
Exec=konsole
Icon=utilities-terminal
Terminal=false
DE
    chmod 755 "$d"/*.desktop 2>/dev/null || true
}
seed_desktop "$TREE/Programs/EnhancedSkel/Settings/skel/Desktop"
seed_desktop "$TREE/Users/live/Desktop"

# --- 31.5) Qt6 modular plugin mirror (SVG icons / splash) -------------------
# A modular Qt6 scatters its runtime plugins across module prefixes:
#   QtBase/6.10.3/plugins/*, QtSVG/6.10.3/plugins/{iconengines,imageformats},
#   QtWayland/6.10.3/plugins/*, QtMultimedia/6.10.3/plugins, QtTextToSpeech, ...
# The refresh-merge Index publishes none of them, so /System/Index/lib/plugins
# is EMPTY and Qt6 cannot dlopen the SVG icon engine at startup: every themed
# SVG icon (kickoff / konsole / dolphin / Gobo installer) renders blank and the
# session splash .svgz fails ("Unsupported image format"), while plain PNGs
# (firefox.png) still work.  Mirror each Q* plugins tree into the Index as
# absolute symlinks.  Idempotent and host-safe (no ISO-only dereferences).
#
# Ordering: "$TREE"/Programs/Qt*/ globs the legacy monolithic Qt5 tree
# (/Programs/Qt/5.15.2) FIRST, so first-wins would publish its
# iconengines/imageformats plugins, which Qt6 dlopen() rejects ("uses
# incompatible Qt library") -- the exact blank-SVG-icon bug above.  Let the
# Qt6 modules win on name collisions; Qt5-only plugin names stay mirrored.
QT_PLUG_MIRROR="$TREE/System/Index/lib/plugins"
mkdir -p "$QT_PLUG_MIRROR"
QT5_QTV="$(basename "$(readlink "$TREE/Programs/Qt/Current" 2>/dev/null)" 2>/dev/null || true)"
QT5_PLUGS="/Programs/Qt/${QT5_QTV:-5.15.2}/plugins"
MIRRORED=0
for qp in "$TREE"/Programs/Qt*/; do
    [ -d "$qp" ] || continue
    for qv in "$qp"*/; do
        [ -d "$qv/plugins" ] || continue
        is_qt5_tree=0
        relpath="${qv#$TREE/}"
        [ "${relpath#Programs/Qt/}" != "$relpath" ] && is_qt5_tree=1
        while IFS= read -r -d "" rel; do
            rel="${rel#./}"
            link="$QT_PLUG_MIRROR/$rel"
            if [ -L "$link" ]; then
                tgt="$(readlink "$link" 2>/dev/null || true)"
                if [ -n "$tgt" ] && [ -e "$link" ] \
                        && { [ "$is_qt5_tree" = 1 ] || [ "${tgt#$QT5_PLUGS/}" = "$tgt" ]; }; then
                    continue        # fine as mirrored (Qt6 keeps first-Qt6)
                fi
                rm -f "$link"       # stale host-dangling, or Qt6 superseding Qt5
            elif [ -e "$link" ]; then
                continue            # real dir/file the ISO already carries
            fi
            mkdir -p "$(dirname "$link")"
            ln -s "/${qv#$TREE/}plugins/$rel" "$link" && MIRRORED=$((MIRRORED + 1))
        done < <(cd "$qv/plugins" && find . -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
    done
done
[ "$MIRRORED" -gt 0 ] && say "qt6 plugins: mirrored $MIRRORED files into ${QT_PLUG_MIRROR#$TREE/}"

# --- 31.6) python3.11 merged site-packages on sys.path (gi startup) ---------
# Gobo's python3.11 interpreter ships a gobo-3.8-site.pth pointing only at the
# 3.8 merged tree, so the 3.11 merge (PyGObject gi, PyCairo, pip deps in
# /System/Index/lib/python3.11/site-packages) is never on sys.path -> gi-based
# apps (Lutris: `No module named 'gi'`, then `Namespace WebKit2 not available`)
# die at startup.  Drop a gobo-3.11-site.pth into every 3.11 interpreter's
# site-packages so it, too, publishes the Index tree.
for _pysp in "$TREE"/Programs/Python/*/lib/python3.11/site-packages; do
    [ -d "$_pysp" ] || continue
    if [ ! -f "$_pysp/gobo-3.11-site.pth" ]; then
        printf '/System/Index/lib/python3.11/site-packages\n' > "$_pysp/gobo-3.11-site.pth"
        say "python3.11: wrote gobo-3.11-site.pth (merged 3.11 site-packages on sys.path)"
    fi
done

# --- 32) OpenSSH live bootstrap (fatal sshd fix) ---------------------------
# Why sshd never answers in the built ISOs (kex reset / no banner):
# the stock OpenSSH task generates host keys into
# /Programs/OpenSSH/Settings/ssh, but the daemon is started as plain `sshd`,
# which reads its config from /etc/ssh/sshd_config.  In the merged tree
# /System/Settings/etc/ssh does not exist (verified against the reference
# GoboLinux-017.01 ISO too), so sshd falls back to built-in defaults, looks
# for host keys at /etc/ssh/ssh_host_* (none exist), and exits immediately
# with "no hostkeys specified".  One symlink makes config *and* the generated
# keys resolve to the same directory, restoring password root login.
if [ -d "$TREE/Programs/OpenSSH/Settings/ssh" ]; then
    mkdir -p "$TREE/System/Settings/etc"
    if [ ! -e "$TREE/System/Settings/etc/ssh" ]; then
        ln -s /Programs/OpenSSH/Settings/ssh "$TREE/System/Settings/etc/ssh"
        say "linked /etc/ssh -> /Programs/OpenSSH/Settings/ssh (fatal sshd fix)"
    fi
    grep -qx 'PermitRootLogin yes' "$TREE/Programs/OpenSSH/Settings/ssh/sshd_config" \
        || sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
            "$TREE/Programs/OpenSSH/Settings/ssh/sshd_config"
fi
# sshd privilege-separation sandbox: /var/empty must be root-owned, mode
# 0755.  mksquashfs preserves the build host uid (the account that ran the build), so in the
# guest sshd refuses to start ("/var/empty must be owned by root...") and the
# StartTask fails -> kex reset.  This was CONFIRMED live from the serial log:
#   "Generating ... rsa key pair." / "/var/empty must be owned by root..." /
#   "StartTask: OpenSSH: Returned code 1 => FAILED."
chown root:root "$TREE/var/empty" >/dev/null 2>&1 || true
chmod 755 "$TREE/var/empty" >/dev/null 2>&1 || true
say "var/empty made root:root 0755 (fatal sshd privilege-separation fix)"
# The stock boot task generates an SSHv1 key (`ssh-keygen -t rsa1`, removed
# from OpenSSH 7.5+) -> "unknown key type rsa1" + chmod on a nonexistent file,
# and it never creates a usable modern host key, so sshd starts with none
# ("no hostkeys specified") and the handshake resets.  Patch the task to emit
# an ed25519 host key, then pre-bake a full host-key set so sshd answers even
# if the tree overlay is read-only at boot.
for sshexk in "$TREE"/Programs/OpenSSH/*/Resources/Tasks/OpenSSH; do
    [ -f "$sshexk" ] || continue
    if grep -q -- '-t rsa1' "$sshexk"; then
        sed -i 's/ssh-keygen -t rsa1 -b 1024/ssh-keygen -t ed25519/' "$sshexk"
        sed -i 's#\(-f \${goboPrograms}/OpenSSH/Settings/ssh/\)ssh_host_key -N#\1ssh_host_ed25519_key -N#' "$sshexk"
        sed -i 's#chmod 600 \${goboPrograms}/OpenSSH/Settings/ssh/ssh_host_key#chmod 600 ${goboPrograms}/OpenSSH/Settings/ssh/ssh_host_ed25519_key#' "$sshexk"
        say "patched OpenSSH boot task: rsa1 -> ed25519 host key"
    fi
done
SSHKEY_DIR="$TREE/Programs/OpenSSH/Settings/ssh"
SSHKEY_BIN="$TREE/Programs/OpenSSH/Current/bin/ssh-keygen"
SSHKEY_HOST="$(command -v ssh-keygen 2>/dev/null || true)"
if [ -d "$SSHKEY_DIR" ]; then
    for spec in "ed25519:ssh_host_ed25519_key:" "rsa:ssh_host_rsa_key:-b 2048" "ecdsa:ssh_host_ecdsa_key:-b 256"; do
        kt=${spec%%:*}; rest=${spec#*:}; kf=${rest%%:*}; kb=${rest#*:}
        if [ ! -f "$SSHKEY_DIR/$kf" ]; then
            if [ -x "$SSHKEY_BIN" ]; then
                "$SSHKEY_BIN" -t "$kt" $kb -f "$SSHKEY_DIR/$kf" -N "" >/dev/null 2>&1
            elif [ -n "$SSHKEY_HOST" ]; then
                "$SSHKEY_HOST" -t "$kt" $kb -f "$SSHKEY_DIR/$kf" -N "" >/dev/null 2>&1
            fi
            [ -f "$SSHKEY_DIR/$kf" ] && say "generated ${kf} host key"
        fi
    done
    chown root:root "$SSHKEY_DIR"/ssh_host_*_key "$SSHKEY_DIR"/ssh_host_*_key.pub 2>/dev/null || true
    chmod 600 "$SSHKEY_DIR"/ssh_host_*_key 2>/dev/null || true
    chmod 644 "$SSHKEY_DIR"/ssh_host_*_key.pub 2>/dev/null || true
    say "OpenSSH host keys present + root-owned 0600/0644"
fi

# --- 33) Non-interactive live boot (unblock the "login never appears") ------
# StartLiveCD runs `ConfigureLiveCD` before SDDM.  It opens interactive
# `dialog --nocancel` menus for language and keymap on the TEXT console.  In
# a GUI/VM the user cannot see them, so the boot sits there indefinitely
# (observed on QEMU serial: language + keymap menus drawn, then nothing until
# input arrives) -> "way too long for the login screen".  Bake the defaults
# (en_US + us keymap, Xorg autodetect) when LIVE_AUTOCONFIG=1 and have
# StartLiveCD set that flag.
CFG_BIN="$TREE/Programs/LiveCD/017.01/bin/ConfigureLiveCD"
if [ -f "$CFG_BIN" ] && ! grep -q 'LIVE_AUTOCONFIG' "$CFG_BIN"; then
    LIVE_GUARD="$TREE/Programs/LiveCD/017.01/bin/.live-config-guard"
    cat > "$LIVE_GUARD" <<'GUARD_EOF'
if [ "${LIVE_AUTOCONFIG:-0}" = "1" ]; then
    # Non-interactive live boot (VM/quick login): en_US locale, us keymap.
    # The interactive language/keymap menus render only on the text console
    # and block the boot forever when nobody can press Enter there.
    rm -f "$(readlink -f ${goboSettings}/X11/xorg.conf 2>/dev/null)" \
        "${goboSettings}/X11/xorg.conf" 2>/dev/null
    mkdir -p "${goboTemp}/setup"
    language="${LIVE_LANG:-en_US}"
    printf '%s\n' "$language" > "${goboTemp}/setup/language"
    export LANG="${language}.UTF-8" LC_ALL="${language}.UTF-8"
    printf 'export LANG=%s\nexport LC_ALL=%s\n' "$LANG" "$LC_ALL" >> "$HOME/.zshrc"
    cp "$HOME/.zshrc" "$HOME/.bashrc"
    printf 'us\n' > "${goboTemp}/setup/keymap"
    loadkeys us >/dev/null 2>&1 || true
    ModifyXinitrc us >/dev/null 2>&1 || true
    exit 0
fi
GUARD_EOF
    awk -v g="$LIVE_GUARD" '
        /^source StartFunctions$/ { print; while ((getline line < g) > 0) print line; close(g); next }
        { print }
    ' "$CFG_BIN" > "$CFG_BIN.patched" && mv -f "$CFG_BIN.patched" "$CFG_BIN"
    rm -f "$LIVE_GUARD"
    say "ConfigureLiveCD: guard inserted after 'source StartFunctions'"
fi
SCL="$TREE/Programs/LiveCD/017.01/bin/StartLiveCD"
if [ -f "$SCL" ] && ! grep -q 'LIVE_AUTOCONFIG=1' "$SCL"; then
    sed -i 's/^ConfigureLiveCD$/\LIVE_AUTOCONFIG=1 ConfigureLiveCD/' "$SCL"
    say "StartLiveCD: ConfigureLiveCD now runs with LIVE_AUTOCONFIG=1 (no dialogs)"
fi

# --- 34) Core GLib-family typelibs (Gio/GLib/GObject/GModule) ----------------
# The GObject-Introspection 1.84.0 package built for this ISO ships only its own
# namespaces (cairo, DBus, Vulkan, ...).  The base ISO carried Gio-2.0, GLib-2.0,
# GObject-2.0 and GModule-2.0 in GObject-Introspection/1.62.0, but refresh-merge
# replaced that program dir -- so the merged /usr/lib/girepository-1.0 has no
# GLib-family typelibs and `gi.repository.Gio` fails with "introspection typelib
# not found", breaking Lutris et al.  Restore the four core typelibs from the
# base ISO's 1.62.0 cache into the ACTIVE GI program dir (idempotent: re-dropping
# identical files is harmless).
GIACT=$(basename "$(readlink "$TREE/Programs/GObject-Introspection/Current" 2>/dev/null || echo GObject-Introspection/1.84.0)")
GIACT_DIR="$TREE/Programs/GObject-Introspection/$GIACT/lib/girepository-1.0"
BASE_GIDIR="$(dirname "$(dirname "$TREE")")/rootfs/Programs/GObject-Introspection/1.62.0/lib/girepository-1.0"
for tl in Gio-2.0 GLib-2.0 GObject-2.0 GModule-2.0; do
    if [ ! -e "$GIACT_DIR/$tl.typelib" ] && [ -f "$BASE_GIDIR/$tl.typelib" ]; then
        mkdir -p "$GIACT_DIR"
        cp -p "$BASE_GIDIR/$tl.typelib" "$GIACT_DIR/$tl.typelib"
        say "restored $tl.typelib into GObject-Introspection/$GIACT/lib/girepository-1.0"
    fi
    if [ -f "$GIACT_DIR/$tl.typelib" ] && [ ! -e "$TREE/usr/lib/girepository-1.0/$tl.typelib" ]; then
        ln -s "/Programs/GObject-Introspection/$GIACT/lib/girepository-1.0/$tl.typelib" \
            "$TREE/usr/lib/girepository-1.0/$tl.typelib"
        say "linked $tl.typelib"
    fi
done

# --- 35) XIVLauncher: pre-create the WINEPREFIX before wineboot -------------
# The FFXIVQuickLauncher wrapper initializes the prefix with `wine wineboot`,
# but wine refuses to chdir into a nonexistent prefix ("wine: chdir to
# /User/live/.local/share/wineprefixes/xivlauncher no such file or directory").
# Pre-create the prefix dir so the very first boot works (idempotent).
for xl in "$TREE"/Programs/FFXIVQuickLauncher/*/bin/xivlauncher \
          "$TREE"/Programs/XIVLauncher/*/bin/xivlauncher; do
    [ -f "$xl" ] || continue
    if ! grep -q 'mkdir -p "$WINEPREFIX"' "$xl"; then
        sed -i 's#^    "\$WINE" wineboot --init 2>/dev/null$#    mkdir -p "$WINEPREFIX"\n    "$WINE" wineboot --init 2>/dev/null#' "$xl"
        say "patched ${xl#$TREE/}: pre-create WINEPREFIX for wineboot"
    fi
done

# --- 36) Lutris data path (lib/lutris/share -> Program share) ----------------
# Lutris' own bin/lutris prepends its package dir to sys.path, so
# datapath.get() looks for the asset tree at <sys.path[0]>/share/lutris
# (branch 3).  The recipe's post_install intends site-packages/share ->
# ../../../share, but the built ISO kept pip's real share/ (only doc), so the
# lookup misses and Lutris dies at startup with "data_path can't be found at
# lib/lutris/share/lutris" (this roars before any GUI/display error).
# Re-create the link so assets resolve regardless of how lutris is launched.
for lt in "$TREE"/Programs/Lutris/*/lib/lutris; do
    [ -e "$lt/share/lutris/json" ] && continue
    progroot="$(dirname "$(dirname "$lt")")"        # Programs/Lutris/<ver>
    progshare="/${progroot#$TREE/}/share"           # /Programs/Lutris/<ver>/share
    rm -rf "$lt/share"
    ln -sfn "$progshare" "$lt/share"
    say "linked ${lt#$TREE/}/share -> $progshare (Lutris datapath)"
    break
done

# --- 37) VLC: Qt xcb platform plugin search path (qt.conf) -------------------
# VLC's Qt GUI dies immediately with
#   qt.qpa.plugin: Could not find the Qt platform plugin "xcb" in ""
# (VERIFIED in the VM: with libqxcb.so present at
# /Programs/Qt/<ver>/plugins/platforms) because the Qt build records no plugin
# path, so Qt scans next to the binary and finds none.  A qt.conf beside the
# VLC binary (Prefix=/Programs/Qt/<active>, same trick as sddm-greeter in
# section 1) makes Qt resolve plugins/xcb from the active Qt prefix.  Idempotent
# and Qt-version-proof.
QTACTIVE=${QTACTIVE:-5.15.2}
for vlcbin in "$TREE"/Programs/VLC/*/bin; do
    [ -x "$vlcbin/vlc" ] || continue
    qconf="$vlcbin/qt.conf"
    if [ ! -f "$qconf" ] || ! grep -q 'Prefix=/Programs/Qt/' "$qconf"; then
        printf '[Paths]\nPrefix=/Programs/Qt/%s\n' "$QTACTIVE" > "$qconf"
        chmod 644 "$qconf"
        say "created ${qconf#$TREE/}/qt.conf (Qt $QTACTIVE) -- VLC xcb plugin fix"
    fi
    break
done

# --- 38) Live boot network + sound + ConfigureLiveCD repair -------------------
# On a `Boot=LiveCD` boot BootUp never runs: BootDriver execs StartLiveCD
# directly.  StartLiveCD's original DHCP loop was functionally deaf in the
# debugged ISOs:
#   * launch_dhcp() backgrounds `dhcpcd -t 15 $1 &> /dev/null` and drops all
#     output, so a failed/wedged lease is invisible and the 15s budget is too
#     tight for real hardware.
#   * WiFi is never started on the live path.
# Sound: nothing initializes the mixer on live boot; there is no baked
# asound.state for Alsactl to restore, so Master/PCM are typically muted ->
# pulseaudio runs but produces silence. Force unmute + 100% at boot.
# Also repairs the section 33 sed bug: GNU sed \L lowercased the intended
#   LIVE_AUTOCONFIG=1 ConfigureLiveCD
# into the broken
#   ive_autoconfig=1 configurelivecd
# (a nonexistent command), so the language wizard silently never ran (VM log:
# "configurelivecd: command not found" + unset LANG).
for scl in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
    [ -f "$scl" ] || continue
    python3 - "$scl" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

fixed = s.replace("ive_autoconfig=1 configurelivecd", "LIVE_AUTOCONFIG=1 ConfigureLiveCD")
if fixed != s:
    s = fixed
    print("[livefix] StartLiveCD: repaired mangled LIVE_AUTOCONFIG / ConfigureLiveCD line")

sound = '''
msg "Loading sound settings"
if command -v amixer >/dev/null 2>&1; then
   #
   # Prefer the first ANALOG playback card; skip GPU output cards
   # (HDMI/DisplayPort/SPDIF/Digital are silent with no monitor attached).
   # In the passthrough VM the NVIDIA HDMI audio (10de:10f1) enumerates next
   # to QEMU's intel-hda; on real laptops the Intel HDA "Speaker/Headphone"
   # card is the one wanted.  Card 0 is the fallback.
   #
   defcard=
   for c in /proc/asound/card*; do
      [ -d "$c" ] || continue
      for pcm in "$c"/pcm*p; do
         [ -f "$pcm/info" ] || continue
         case "$(head -c 300 "$pcm/info" 2>/dev/null)" in
            *HDMI*|*DisplayPort*|*SPDIF*|*Digital*) ;;
            *) defcard="${c##*/card}"; break 2 ;;
         esac
      done
   done
   [ -n "$defcard" ] || defcard=0
   printf 'defaults.pcm.card %s\\ndefaults.ctl.card %s\\ndefaults.pcm.device 0\\n' "$defcard" "$defcard" > /etc/asound.conf
   #
   # raise every playback volume and unmute (covers Master/PCM/Front/Speaker/
   # Headphone on HDA codecs) and keep Auto-Mute off so built-in speakers work
   #
   while read -r ctl; do
      [ -n "$ctl" ] && amixer -c "$defcard" sset "$ctl" 100% unmute >/dev/null 2>&1 || true
   done < <(amixer -c "$defcard" scontrols 2>/dev/null | awk -F"'" '{print $2}')
   amixer -c "$defcard" sset 'Auto-Mute Mode' Disabled >/dev/null 2>&1 || true
   alsactl restore >/dev/null 2>&1 || true
fi
'''
old_sound = '''
msg "Loading sound settings"
if command -v amixer >/dev/null 2>&1; then
   amixer -q set Master unmute 2>/dev/null || true
   amixer -q set Master 100% 2>/dev/null || true
   amixer -q set PCM unmute 2>/dev/null || true
   amixer -q set PCM 100% 2>/dev/null || true
fi
'''
if old_sound in s:
    s = s.replace(old_sound, sound)
    print("[livefix] StartLiveCD: ALSA sound block upgraded (HW-neutral card + unmute-all)")
elif "Loading sound settings" not in s:
    s = s.replace("StartTask CUPS\n", "StartTask CUPS\n" + sound, 1)
    print("[livefix] StartLiveCD: ALSA sound block added after CUPS")

if "launch_dhcp $interface" in s and "livefix: dhcp" not in s:
    start = s.index("for interface in $(NetInterfaces)")
    end = s.index("done", start) + len("done")
    dhcp = '''for interface in $(NetInterfaces)
do
   if ifconfig $interface  >& /dev/null
   then
      mkdir -p /Data/Variable/log
      if [ -d /sys/class/net/$interface/wireless ]; then
         msg "Wireless $interface present: starting WPA control daemon"
         StartTask WPA_Supplicant >/dev/null 2>&1 || true
      fi
      msg "Requesting address on $interface via DHCP"
      dhcpcd -q -t 30 "$interface" > /Data/Variable/log/dhcpcd-$interface.log 2>&1 &
   fi
done
# livefix: dhcp (logged, 30s timeout, wireless WPA daemon)'''
    s = s[:start] + dhcp + s[end:]
    s = s.replace("# Executes the 'launch_dhcp' function if an ethernet interface was found\n", "")
    print("[livefix] StartLiveCD: DHCP loop replaced (per-interface logged dhcpcd + WiFi daemon)")

open(p, "w", encoding="utf-8").write(s)
PYEOF
    say "StartLiveCD applied: ${scl#$TREE/} (live network + sound + ConfigureLiveCD)"
done

# Installed (BootUp) path: the section 12 line `Exec "Requesting network
# address..." dhcpcd` names a task that does not exist (the DHCPCD task is
# DHCPNetworkInterface, which needs an interface argument), so StartTask fails
# on normal boots too.  Replace it with a direct per-interface dhcpcd (same
# semantics as the StartLiveCD loop above).  `sh -c` mirrors the working sddm
# Exec line; StartTask is a shell function and can't be inherited by a `sh -c`
# child, hence the plain dhcpcd calls.
bootup="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"
if [ -f "$bootup" ] && grep -q '^Exec "Requesting network address..."' "$bootup" && \
   grep -q '^Exec "Requesting network address..."[[:space:]]*dhcpcd[[:space:]]*$' "$bootup"; then
    sed -i 's#^Exec "Requesting network address..."[[:space:]]*dhcpcd[[:space:]]*$#Exec "Requesting network address..." sh -c '\''mkdir -p /Data/Variable/log; for i in $(NetInterfaces); do [ -n "$i" ] \&\& dhcpcd -q -t 30 "$i" >/Data/Variable/log/dhcpcd-$i.log 2>\&1 \& done'\''#' "$bootup"
    say "BootUp: replaced nonexistent 'dhcpcd' task line with per-interface dhcpcd loop"
fi

# --- 39) Real-hardware sound: PulseAudio D-Bus auto-activation + audio group ---
# Why "no sound on real hardware" (everything in this section verified against
# the built ISO):
#   * The ONLY PulseAudio launch path is the xdg/autostart .desktop
#     (Exec=start-pulseaudio-x11).  No org.pulseaudio.Server D-Bus activation
#     service ships anywhere, so any session that does not process
#     /etc/xdg/autostart gets NO audio server -> apps silently lose audio.
#   * The live/root users are NOT members of the `audio` group; /dev/snd/*
#     nodes are 0660 root:audio, so even an on-demand server cannot open the
#     sound hardware.  (Section 38 fixes the mixer + default ALSA card; this
#     section fixes "server never runs / cannot open the device".)
# Ship the classic on-demand D-Bus service into every user-home seed the ISO
# creates (live, root, EnhancedSkel skel, LiveCD Users_gobo) and grant the
# group memberships.
PA_SVC='
[D-BUS Service]
Name=org.pulseaudio.Server
Exec=/Programs/PulseAudio/Current/bin/pulseaudio --start --daemonize=yes --system=false
'
if [ -d "$TREE/Programs/PulseAudio/Current" ]; then
    for seed in \
        "$TREE/Users/live/.local/share/dbus-1/services" \
        "$TREE/Users/root/.local/share/dbus-1/services" \
        "$TREE/Programs/EnhancedSkel/Current/Resources/Defaults/Settings/skel/.local/share/dbus-1/services" \
        "$TREE/Programs/LiveCD/Current/Data/Users_gobo/.local/share/dbus-1/services"; do
        mkdir -p "$seed"
        if [ ! -f "$seed/org.pulseaudio.Server.service" ] || \
           ! grep -q 'pulseaudio --start' "$seed/org.pulseaudio.Server.service"; then
            printf '%s\n' "$PA_SVC" > "$seed/org.pulseaudio.Server.service"
            chmod 644 "$seed/org.pulseaudio.Server.service"
            say "PulseAudio D-Bus activation shipped: ${seed#$TREE/}/org.pulseaudio.Server.service"
        fi
    done
else
    say "WARNING: $TREE/Programs/PulseAudio/Current not found (skipping D-Bus activation)"
fi

# audio group membership: /dev/snd blocks are 0660 root:audio.  Without this
# the user-level PA never gets a handle on the sound hardware.
for gfile in "$TREE/System/Settings/group"; do
    [ -f "$gfile" ] || continue
    for g in audio pulse-rt pulse-access; do
        case "$g" in
            audio) sid="11"; mem="live,sddm" ;;
            pulse-rt) sid="121"; mem="live" ;;
            pulse-access) sid="122"; mem="live,sddm" ;;
        esac
        if grep -q "^${g}:x:${sid}:" "$gfile"; then
            sed -i "s#^${g}:x:${sid}:.*\$#${g}:x:${sid}:${mem}#" "$gfile"
        fi
    done
    grep -E '^audio:|^pulse-(rt|access):' "$gfile" | sed 's/^/    /'
    say "sound group memberships updated: ${gfile#$TREE/}"
done

# --- 40) PipeWire system-wide audio: boot task + env + PulseAudio handover ---
# Builds on section 39.  When the full PipeWire stack (Recipes/PipeWire +
# Recipes/WirePlumber) is merged in, this section:
#   * installs the PipeWire/WirePlumber Gobo init Tasks and /System/Tasks links
#   * starts the daemon on BOTH boot paths (BootUp and StartLiveCD) after the
#     system message bus (PipeWire attaches to it) and before the display
#     manager
#   * exports PIPEWIRE_RUNTIME_DIR + PULSE_SERVER to every session via
#     /etc/environment (pam_env) so ALSA-only AND Pulse-only apps find the
#     system-wide daemon
#   * disables the on-demand PulseAudio paths shipped in section 39, so PA and
#     pipewire-pulse never fight over /dev/snd
# The task scripts are identical to the ones in the recipes'
# Resources/Tasks/; writing them here keeps apply-live-fixes the single owner
# of init wiring (same convention as Elogind/SeatD/SDDM in section 12).
# No-op on trees without /Programs/PipeWire (LibPipewire-only ISOs keep the
# section-39 PulseAudio behaviour).
PIPEWIRE_VER="$(basename "$(readlink "$TREE/Programs/PipeWire/Current" 2>/dev/null || echo 1.4.0)")"
WIREPLUMBER_VER="$(basename "$(readlink "$TREE/Programs/WirePlumber/Current" 2>/dev/null || echo 0.5.17)")"
if [ -d "$TREE/Programs/PipeWire" ]; then
    pw_task="$TREE/Programs/PipeWire/$PIPEWIRE_VER/Resources/Tasks/PipeWire"
    wp_task="$TREE/Programs/WirePlumber/$WIREPLUMBER_VER/Resources/Tasks/WirePlumber"
    mkdir -p "$(dirname "$pw_task")" "$(dirname "$wp_task")"
    cat > "$pw_task" <<'EOF'
#!/bin/bash
#
# PipeWire: system-wide media server + WirePlumber session manager +
# pipewire-pulse (PulseAudio compatibility server)
#
# Gobo has no systemd user services, so this boot-level Task runs the daemons
# as ONE shared system instance; the ISO is a personal live system with a
# single desktop user (live).  pipewire owns the audio graph, wireplumber is
# the session/policy manager and pipewire-pulse speaks the classic PulseAudio
# protocol for libpulse apps.  All sockets live under /run (tmpfs), owned
# root:audio mode 2770, so any session user in the `audio` group can connect
# (apply-live-fixes.sh section 39 puts live/sddm in that group).
#
# Client env for sessions is exported via /System/Settings/environment
# (pam_env) by apply-live-fixes.sh section 40:
#     PIPEWIRE_RUNTIME_DIR=/run/pipewire
#     PULSE_SERVER=unix:/run/pulse/native
#
# Started from the Gobo BootUp / StartLiveCD scripts via:  PipeWire Start
# (StartTask PipeWire).  Idempotent: every daemon is pgrep-guarded by its
# exact full-path command line (note: pipewire and pipewire-pulse are the
# SAME binary name so `pgrep -x pipewire` matches both -- never use it).
op="$1"
[ "$op" ] || op="start"

PW="$(readlink -f /Programs/PipeWire/Current)/bin/pipewire"
PULSE="$PW-pulse"
MP="$(readlink -f /Programs/WirePlumber/Current)/bin/wireplumber"

LOG=/Data/Variable/log
RUNDIR=/run/pipewire
PULSEDIR=/run/pulse

start() {
    mkdir -p "$LOG"
    chmod 1777 "$LOG"

    mkdir -p "$RUNDIR" "$PULSEDIR"
    # setgid so the native socket inherits group `audio`; umask 007 makes the
    # socket 0660 root:audio -> connected user sessions can open it.
    chown root:audio "$RUNDIR" "$PULSEDIR" 2>/dev/null \
        || { chown root:root "$RUNDIR" "$PULSEDIR"; }
    chmod 2770 "$RUNDIR" "$PULSEDIR"

    # run the whole stack against /run (system-wide).  dbus session bus does
    # not exist as a separate daemon here: point GDBus at the system bus
    # (MessageBus is up by the time this task runs at boot).
    export XDG_RUNTIME_DIR=/run
    export PIPEWIRE_RUNTIME_DIR="$RUNDIR"
    export PULSE_RUNTIME_PATH="$PULSEDIR"
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
    umask 007

    [ -x "$PW" ] || { echo "PipeWire: daemon binary missing ($PW)"; exit 1; }

    if ! pgrep -f "^$PW\$" >/dev/null 2>&1; then
        setsid -f "$PW" </dev/null >>"$LOG/pipewire.log" 2>&1 &
    fi
    # wait for the native socket so wireplumber always finds the daemon
    i=0
    while [ ! -S "$RUNDIR/pipewire-0" ] && [ "$i" -lt 30 ]; do
        i=$((i + 1)); sleep 0.5
    done

    if [ -x "$MP" ] && ! pgrep -f "^$MP " >/dev/null 2>&1; then
        setsid -f "$MP" --profile main-systemwide \
            </dev/null >>"$LOG/wireplumber.log" 2>&1 &
    fi

    if [ -x "$PULSE" ] && ! pgrep -f "^$PULSE\$" >/dev/null 2>&1; then
        setsid -f "$PULSE" </dev/null >>"$LOG/pipewire-pulse.log" 2>&1 &
    fi
    return 0
}

stop() {
    pkill -f '^.*/bin/pipewire-pulse$' 2>/dev/null
    pkill -x wireplumber 2>/dev/null
    pkill -f '^.*/bin/pipewire$' 2>/dev/null
    return 0
}

case "$op" in
    [Ss]tart) start ;;
    [Ss]top)  stop ;;
    *) echo "usage: PipeWire [start|stop]"; exit 2 ;;
esac
EOF
    chmod 755 "$pw_task"

    cat > "$wp_task" <<'EOF'
#!/bin/bash
#
# WirePlumber: PipeWire session manager (system-wide instance)
#
# Companion to the PipeWire boot task -- that task normally starts the session
# manager itself.  This task lets you (re)start just the session manager
# against an already-running daemon, e.g. after editing a WirePlumber config:
#
#     WirePlumber Stop
#     WirePlumber Start
#
# Uses the `main-systemwide` profile: the default 0.5.17 config ships it to
# disable the session-only modules (logind, portal permissionstore,
# reserve-device) that make no sense for a root system-wide instance.
op="$1"
[ "$op" ] || op="start"

WP="$(readlink -f /Programs/WirePlumber/Current)/bin/wireplumber"

start() {
    pgrep -x wireplumber >/dev/null 2>&1 && exit 0
    [ -x "$WP" ] || { echo "WirePlumber: binary missing ($WP)"; exit 1; }
    mkdir -p /Data/Variable/log
    chmod 1777 /Data/Variable/log
    export XDG_RUNTIME_DIR=/run
    export PIPEWIRE_RUNTIME_DIR=/run/pipewire
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
    setsid -f "$WP" --profile main-systemwide \
        </dev/null >>/Data/Variable/log/wireplumber.log 2>&1 &
}

stop() {
    pkill -x wireplumber 2>/dev/null
}

case "$op" in
    [Ss]tart) start ;;
    [Ss]top)  stop ;;
    *) echo "usage: WirePlumber [start|stop]"; exit 2 ;;
esac
EOF
    chmod 755 "$wp_task"

    for t in "PipeWire:$pw_task" "WirePlumber:$wp_task"; do
        name="${t%%:*}"; path="${t#*:}"
        [ -e "$TREE/System/Tasks/$name" ] || [ -L "$TREE/System/Tasks/$name" ] || \
            { mkdir -p "$TREE/System/Tasks"; ln -s "${path#$TREE}" "$TREE/System/Tasks/$name"; }
    done
    say "PipeWire + WirePlumber tasks installed (${pw_task#$TREE/})"

    # BootUp: start the sound daemon right after SeatD, before the display
    # manager, so sddm sessions never race a missing PipeWire socket.
    bootup="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"
    if [ -f "$bootup" ] && ! grep -q 'PipeWire Start' "$bootup"; then
        sed -i '/^Exec "Starting seat daemon\.\.\."/a Exec "Starting sound daemon..."           PipeWire Start' "$bootup"
        say "BootUp: PipeWire start wired after SeatD"
    elif [ -f "$bootup" ]; then
        say "BootUp: PipeWire start already present"
    else
        say "WARNING: BootUp not found ($bootup); skipping sound daemon wiring"
    fi

    # StartLiveCD (live boot path; BootUp is skipped on Boot=LiveCD), right
    # after the early daemons block added in section 12.
    for sld in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
        [ -f "$sld" ] || continue
        if ! grep -q 'StartTask PipeWire' "$sld"; then
            sed -i '/^StartTask OpenSSH/a\msg "Starting sound daemon"\nStartTask PipeWire' "$sld"
            say "StartLiveCD: PipeWire start wired after OpenSSH (${sld#$TREE/})"
        else
            say "StartLiveCD: PipeWire start already present (${sld#$TREE/})"
        fi
    done

    # Session environment (/etc/environment).  pam_env reads it for every login
    # session; the socket dirs are root:audio 2770 so an `audio` member can use
    # them.  PULSE_SERVER + PULSE_RUNTIME_PATH must agree with the task above
    # (module-protocol-pulse treats PULSE_RUNTIME_PATH as the socket dir itself,
    # so the server, when run by the task, listens on /run/pulse/native).
    envf="$TREE/System/Settings/environment"
    if [ -e "$envf" ] || [ -L "$envf" ]; then
        for kv in PIPEWIRE_RUNTIME_DIR=/run/pipewire PULSE_SERVER=unix:/run/pulse/native; do
            key="${kv%%=*}"
            sed -i "/^${key}=/d" "$envf"
            printf '%s\n' "$kv" >> "$envf"
        done
        say "session audio env exported: ${envf#$TREE/} (PIPEWIRE_RUNTIME_DIR, PULSE_SERVER)"
    else
        say "WARNING: ${envf#$TREE/} not found; skipping session audio env export"
    fi

    # Disable the on-demand PulseAudio launch paths from section 39: with the
    # system-wide PipeWire owning /dev/snd, an activated PA would either steal
    # the device or confuse apps.  Rename (not delete) so a re-run of section
    # 39 stays visible and the change is trivially reversible.
    pa_autostart="$TREE/Programs/PulseAudio/Settings/xdg/autostart/pulseaudio.desktop"
    for f in "$pa_autostart" "$TREE"/Programs/PulseAudio/*/Resources/Defaults/Settings/xdg/autostart/pulseaudio.desktop; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "$f" in *.disabled) continue ;; esac
        mv -f "$f" "$f.disabled"
        say "PulseAudio autostart disabled: ${f#$TREE/}"
    done
    # Drop the session autostart symlink so the disabled entry is not exposed.
    if [ -L "$TREE/System/Settings/xdg/autostart/pulseaudio.desktop" ]; then
        rm -f "$TREE/System/Settings/xdg/autostart/pulseaudio.desktop"
        say "PulseAudio autostart symlink removed: System/Settings/xdg/autostart/pulseaudio.desktop"
    fi
    for seed in \
        "$TREE/Users/live/.local/share/dbus-1/services" \
        "$TREE/Users/root/.local/share/dbus-1/services" \
        "$TREE/Programs/EnhancedSkel/Current/Resources/Defaults/Settings/skel/.local/share/dbus-1/services" \
        "$TREE/Programs/LiveCD/Current/Data/Users_gobo/.local/share/dbus-1/services"; do
        svc="$seed/org.pulseaudio.Server.service"
        [ -e "$svc" ] || [ -L "$svc" ] || continue
        case "$svc" in *.disabled) continue ;; esac
        mv -f "$svc" "$svc.disabled"
        say "PulseAudio D-Bus activation disabled: ${svc#$TREE/}"
    done
    say "PipeWire wired; pipewire-pulse now serves libpulse clients"
else
    say "PipeWire not installed; keeping section-39 PulseAudio behaviour"
fi

# --- 41) Boot networking: GoboNet (wired DHCP + known WiFi), radios, live-path Bluetooth + modems ---
# GoboNet (the Programs/GoboNet tree) is the Gobo-native network manager: it
# drives wpa_supplicant for WiFi and dhcpcd for addresses, keeping per-user
# known networks in ~/.cache/GoboNet/wifi.  NetworkManager is deliberately NOT
# started -- it would compete with GoboNet/dhcpcd for the same interfaces.
#
# On top of the existing dhcpcd lines this section:
#   * installs a `Network` Gobo task (rfkill unblock + `gobonet autoconnect`)
#     and its /System/Tasks link, wired just before the dhcpcd fallback in
#     BootUp and StartLiveCD,
#   * starts the Bluetooth task on the live path (StartLiveCD boots without
#     BootUp, so bluetoothd never ran there),
#   * starts ModemManager when installed (the qmi/mbim backends come from the
#     networking recipe step; until then only AT/PPP modems enumerate).
#
# Additive + idempotent: the dhcpcd fallback lines stay and every block is
# grep-guarded, so `livefix` can be re-run safely.
GONET_ROOT="$(readlink -f "$TREE/Programs/GoboNet/Current" 2>/dev/null || true)"
if [ -n "$GONET_ROOT" ] && [ -d "$GONET_ROOT" ]; then
    # /dev/rfkill must be world-writable on the live system or the 'live'
    # session user gets "rfkill: cannot open /dev/rfkill: Permission denied"
    # (the stock Eudev rule only sets MODE=0664, group root).  Bake an udev
    # override so the node stays 0666 regardless of the device-parent order.
    RFKILL_RULE="$TREE/Programs/Eudev/Current/lib/udev/rules.d/90-live-rfkill.rules"
    if [ -d "$(dirname "$RFKILL_RULE")" ]; then
        printf 'KERNEL=="rfkill", SUBSYSTEM=="misc", MODE="0666"\n' > "$RFKILL_RULE"
    fi
    # AND fix the already-created node now (the running kernel/node outlives a
    # reload; without this the very first `gobonet connect` still hits 0664).
    if [ -e /dev/rfkill ] && [ "$(stat -c %a /dev/rfkill 2>/dev/null)" != "666" ]; then
        chmod 666 /dev/rfkill 2>/dev/null || true
    fi
    net_task="$GONET_ROOT/Resources/Tasks/Network"
    mkdir -p "$(dirname "$net_task")"
    cat > "$net_task" <<'EOF'
#!/bin/bash
#
# Network: GoboNet-driven boot networking (wired DHCP + known WiFi).
#
# Started from the Gobo BootUp / StartLiveCD scripts as `Network start`.
# GoboNet runs as the desktop user because known networks live in that user's
# ~/.cache/GoboNet/wifi.  The raw dhcpcd lines that follow in BootUp /
# StartLiveCD stay as a fallback for interfaces GoboNet does not bring up.
#
# GoboNet prefers a plugged wired link and then known/open WiFi, so this is a
# harmless no-op when nothing applies.  It is backgrounded so a WiFi scan never
# delays the rest of the boot.

op="$1"
[ "$op" ] || op="start"

LOG=/Data/Variable/log
MK="$(readlink -f /Programs/GoboNet/Current 2>/dev/null)/bin/gobonet"

start() {
    mkdir -p "$LOG"

    # Clear soft rfkill blocks (some firmware/hw remembers them).
    command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>/dev/null

    [ -x "$MK" ] || return 0

    # NetworkManager would fight GoboNet/dhcpcd for the same interfaces; this
    # ISO uses the GoboNet model, so only flag it if something started it.
    if pgrep -x NetworkManager >/dev/null 2>&1; then
        echo "Network: WARNING: NetworkManager is running alongside GoboNet" >>"$LOG/gobonet.log"
    fi

    # Prefer the live session user; an installed system falls back to root.
    netuser="live"
    id -u "$netuser" >/dev/null 2>&1 || netuser="root"

    if [ "$netuser" = "root" ]; then
        setsid -f "$MK" autoconnect </dev/null >>"$LOG/gobonet.log" 2>&1 &
    else
        setsid -f su - "$netuser" -c "$MK autoconnect" \
            </dev/null >>"$LOG/gobonet.log" 2>&1 &
    fi
}

stop() {
    pkill -x gobonet_backend 2>/dev/null
    pkill -x gobonet 2>/dev/null
}

case "$op" in
    [Ss]tart) start ;;
    [Ss]top)  stop ;;
    *) echo "usage: Network [start|stop]"; exit 2 ;;
esac
EOF
    chmod 755 "$net_task"
    [ -e "$TREE/System/Tasks/Network" ] || [ -L "$TREE/System/Tasks/Network" ] || \
        { mkdir -p "$TREE/System/Tasks"; ln -s "${net_task#$TREE}" "$TREE/System/Tasks/Network"; }
    say "Network task installed (${net_task#$TREE/})"

    # --- 41b) NetworkManager as a *boot daemon* (the wiki "Configuring-the-boot-
    #           process" mechanism: a program auto-starts iff
    #           /System/Settings/BootScripts/<Name>/Init exists).
    #           GoboNet stays the primary link/wifi driver (dhcpcd gets the
    #           lease), so NM is NOT wired to own interfaces -- it is started
    #           only so its D-Bus name answers, because Qt connectivity probes
    #           (gobonet/update-checker QNetworkConfigurationManager) hard-hang
    #           on "no NM on D-Bus" and report OFFLINE, which the update
    #           checker treats as "can't update / not connected to the
    #           Internet" even when the wire genuinely carries traffic.
    nm_init="$TREE/System/Settings/BootScripts/NetworkManager/Init"
    if [ ! -f "$nm_init" ]; then
        mkdir -p "$(dirname "$nm_init")"
        cat > "$nm_init" <<'NMIO'
#!/bin/bash
# NetworkManager boot daemon (wiki: Configuring-the-boot-process -> BootScripts).
# NM is intentionally run WITHOUT any interface (GoboNet/dhcpcd own the lease);
# its job here is only to answer the org.freedesktop.NetworkManager D-Bus name
# so Qt's QNetworkConfigurationManager reports connectivity accurately.
NM_BIN="$(command -v NetworkManager 2>/dev/null || echo /Programs/NetworkManager/Current/sbin/NetworkManager)"
pgrep -x NetworkManager >/dev/null 2>&1 && exit 0
LOG=/Data/Variable/log
mkdir -p "$LOG"
exec setsid "$NM_BIN" --no-daemon --no-dns-update </dev/null >>"$LOG/NetworkManager.log" 2>&1 &
NMIO
        chmod 755 "$nm_init"
        say "NetworkManager: baked /System/Settings/BootScripts/NetworkManager/Init (NM on D-Bus at boot -> Qt sees online)"
    else
        say "NetworkManager: boot Init already present"
    fi

    bootup="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"
    if [ -f "$bootup" ] && ! grep -q 'Network Start' "$bootup"; then
        sed -i '/^Exec "Requesting network address\.\.\."/i Exec "Connecting to known networks..."    Network Start' "$bootup"
        say "BootUp: GoboNet wired before dhcpcd fallback"
    else
        say "BootUp: GoboNet start already present or BootUp missing"
    fi

    for sld in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
        [ -f "$sld" ] || continue
        if ! grep -q 'StartTask Network' "$sld"; then
            sed -i '/^StartTask OpenSSH/a\msg "Connecting to known networks"\nStartTask Network' "$sld"
            say "StartLiveCD: GoboNet wired after OpenSSH (${sld#$TREE/})"
        fi
        if ! grep -q 'StartTask Bluetooth' "$sld"; then
            sed -i '/^StartTask Elogind/a\msg "Starting Bluetooth daemon"\nStartTask Bluetooth' "$sld"
            say "StartLiveCD: Bluetooth wired after Elogind (${sld#$TREE/})"
        fi
    done
else
    say "GoboNet not installed; skipping GoboNet boot wiring"
fi

# ModemManager: start it at boot when installed.  Invoked through StartTask
# (which resolves $goboTasks/<name> directly) because a bare `ModemManager`
# would hit the program binary in /System/Index/bin instead of the task.
mm_root="$(readlink -f "$TREE/Programs/ModemManager/Current" 2>/dev/null || true)"
if [ -n "$mm_root" ] && [ -x "$mm_root/bin/ModemManager" ]; then
    mm_task="$mm_root/Resources/Tasks/ModemManager"
    mkdir -p "$(dirname "$mm_task")"
    cat > "$mm_task" <<'EOF'
#!/bin/bash
#
# ModemManager: mobile-broadband daemon (mmcli front-end).
#
op="$1"; [ "$op" ] || op="start"
MM="$(readlink -f /Programs/ModemManager/Current)/bin/ModemManager"

start() {
    pgrep -x ModemManager >/dev/null 2>&1 && exit 0
    [ -x "$MM" ] || { echo "ModemManager: binary missing ($MM)"; exit 1; }
    mkdir -p /Data/Variable/log
    setsid -f "$MM" --no-auto-suspend </dev/null >>/Data/Variable/log/modemmanager.log 2>&1 &
}

stop() {
    pkill -x ModemManager 2>/dev/null
}

case "$op" in
    [Ss]tart) start ;;
    [Ss]top)  stop ;;
    *) echo "usage: ModemManager [start|stop]"; exit 2 ;;
esac
EOF
    chmod 755 "$mm_task"
    [ -e "$TREE/System/Tasks/ModemManager" ] || [ -L "$TREE/System/Tasks/ModemManager" ] || \
        { mkdir -p "$TREE/System/Tasks"; ln -s "${mm_task#$TREE}" "$TREE/System/Tasks/ModemManager"; }
    say "ModemManager task installed (${mm_task#$TREE/})"

    bootup="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"
    if [ -f "$bootup" ] && ! grep -q 'StartTask ModemManager' "$bootup"; then
        sed -i '/^Exec "Starting Bluetooth daemon\.\.\."/a Exec "Starting modem manager..."          StartTask ModemManager' "$bootup"
        say "BootUp: ModemManager wired after Bluetooth"
    fi
    for sld in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
        [ -f "$sld" ] || continue
        if ! grep -q 'StartTask ModemManager' "$sld"; then
            sed -i '/^StartTask Elogind/a\msg "Starting modem manager"\nStartTask ModemManager' "$sld"
            say "StartLiveCD: ModemManager wired after Elogind (${sld#$TREE/})"
        fi
    done
else
    say "ModemManager not installed; skipping modem daemon wiring"
fi

# --- 42) NVIDIA EGL-wayland unify + force EGL/GLX to Nvidia + wine boot fix ---
# Real-hardware findings (GTX 1060 Mobile, `wine boot` smoke test):
#   1. Wine is a CLASSIC dual-arch build (lib/wine/{i386-unix,x86_64-unix}), so
#      wineboot spawns real ELF32 processes.  Its 32-bit loader reads
#      /System/Index/lib32/libgnutls.so.30 (Lib32-gnutls 3.7.9) but that lib
#      NEEDs libnettle.so.8 / libhogweed.so.6 / 32-bit p11-kit + tasn1, none of
#      which exist in the tree (base Nettle is 3.5.1 -> sonames 7/5) -> wine
#      logs "failed to load libgnutls" (crypto only, non-fatal; needs new Lib32
#      recipes, NOT a livefix).
#   2. EGL-Wayland (1.1.9) ships /usr/share/egl/egl_external_platform.d/
#      10_nvidia_wayland.json only under its Program tree; it never gets
#      merged to the live path (System/Index/share == /usr/share at runtime),
#      and libnvidia-egl-wayland.{so,so.1,1.1.9} point at 1.1.9 while so.1
#      points at Nvidia's bundled 1.1.20 -> inconsistent.  Unify on the
#      driver-bundled soname when present, and materialize the external
#      platform JSON so NVIDIA EGL-wayland is actually discoverable.
#   3. Mesa's libEGL probes the real GPU's DRM fd because GLVND has BOTH
#      mesa + nvidia vendor JSONs; on a real GPU it must pick nvidia first
#      (stops "DRI3 error: Could not get DRI3 device" / "kmsro,iris: driver
#      missing" / swrast fallback).  Do NOT remove 50_mesa.json (QEMU/llvmpipe
#      still needs it as the fallback); instead force nvidia via the XDG/GLVND
#      runtime env vars only in the desktop session scripts, so hardware EGL
#      uses libEGL_nvidia and Mesa only gets used when no nvidia libs exist.
#   4. `wine boot` is not a wine command (ShellExecuteEx failed: File not
#      found); the correct bootstrap is `wineboot` (/System/Index/bin/wineboot).
#      Add a shell shim so a typo of `wine boot` runs wineboot instead.
say "== section 42: NVIDIA EGL-wayland unify + force-nvidia + wine boot shim =="

# --- 42a) Unify libnvidia-egl-wayland to ONE soname target -------------------
# Prefer the driver-bundled real lib (comes from the same Nvidia program that
# provides libEGL_nvidia), fall back to the EGL-Wayland recipe build.  All
# runtime soname links must resolve to the SAME real file.  Note: only the
# bare `.so`, `.so.1` and `.so.1.1.20` names are loadable entry points; the
# hex-versioned `.1.1.9`/`.1.1.20` names are just what the dlopened soname
# finally dereferences to.
EWLIB_DIR="$TREE/System/Index/lib"
NV_REAL=$(find "$TREE"/Programs/Nvidia -name 'libnvidia-egl-wayland.so.1.1.2[0-9]' 2>/dev/null | sort -V | tail -1)
EW_REAL="$TREE/Programs/EGL-Wayland/1.1.9/lib/libnvidia-egl-wayland.so.1.1.9"
WINNER=
for cand in "$NV_REAL" "$EW_REAL"; do
    if [ -f "$cand" ]; then WINNER="$cand"; break; fi
done
if [ -n "$WINNER" ]; then
    winner_rel="/${WINNER#$TREE/}"
    # Repoint every loadable name (.so, .so.1) and the versioned suffix that
    # both sides ship to the single winner real file.  If the winner is the
    # EGL-Wayland build, drop the stale .1.1.20 link (it was never its file);
    # if the winner is Nvidia's, its .1.1.20 link is what the new .so.1
    # resolves through, so leave it and retire the leftover .1.1.9 entry.
    ln -sfn "$winner_rel" "$EWLIB_DIR/libnvidia-egl-wayland.so"
    ln -sfn "$winner_rel" "$EWLIB_DIR/libnvidia-egl-wayland.so.1"
    case "$WINNER" in
        "$TREE"/Programs/Nvidia/*) rm -f "$EWLIB_DIR/libnvidia-egl-wayland.so.1.1.9" ;;
        *)                         rm -f "$EWLIB_DIR/libnvidia-egl-wayland.so.1.1.20" ;;
    esac
    say "EGL-wayland: unified to $(basename "$WINNER")"
else
    say "EGL-wayland: no real lib found (nvidia absent); leaving Mesa-only path"
fi

# --- 42b) Verify /usr/share/egl/egl_external_platform.d is reachable ---------
# libEGL scans $datadir/egl/egl_external_platform.d/*.json for
# EGL_EXT_platform_wayland.  The recipe installs the JSON under the EGL-Wayland
# Program tree; /usr/share/egl is a SYMLINK chain (usr/share -> System/Index/
# share, and System/Index/share/egl -> Programs/EGL-Wayland/.../share/egl), so
# it IS reachable at runtime as long as the links exist.  Host-side `ls`
# misreports it because the targets are ISO-absolute; only fix it when the
# chain is genuinely broken (like section 19 replaces stale glvnd links).
EXTDIR="$TREE/System/Index/share/egl/egl_external_platform.d"
ext_ok=0
if [ -L "$TREE/System/Index/share/egl" ]; then
    tgt="$(readlink "$TREE/System/Index/share/egl")"
    if [ -e "$TREE/${tgt#/}/egl_external_platform.d/10_nvidia_wayland.json" ]; then
        ext_ok=1
    fi
fi
if [ "$ext_ok" = 0 ]; then
    for stale in "$TREE/System/Index/share/egl"; do
        [ -L "$stale" ] && rm -f "$stale" && say "EGL external platform: dropped stale ${stale#$TREE/} symlink"
    done
    mkdir -p "$EXTDIR"
    src=""
    for j in "$TREE"/Programs/EGL-Wayland/*/share/egl/egl_external_platform.d/10_nvidia_wayland.json; do
        [ -f "$j" ] && src="$j"
    done
    if [ -n "$src" ]; then
        [ -e "$EXTDIR/10_nvidia_wayland.json" ] || ln -sf "/${src#$TREE/}" "$EXTDIR/10_nvidia_wayland.json"
        say "EGL external platform: materialized 10_nvidia_wayland.json"
    else
        cat > "$EXTDIR/10_nvidia_wayland.json" <<'JSON'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libnvidia-egl-wayland.so.1"
    }
}
JSON
        say "EGL external platform: wrote fallback 10_nvidia_wayland.json"
    fi
else
    say "EGL external platform: symlink chain OK at runtime (no fix needed)"
fi

# --- 42c) Force GLX/EGL onto NVIDIA in desktop sessions, on REAL GPUs only ---
# GLVND picks EGL vendors from egl_vendor.d in filename order; 10_nvidia*
# preempts 50_mesa so hardware EGL already lands on nvidia.  The remaining
# "DRI3 error: Could not get DRI3 device" / "driver (null)" / "kmsro,iris:
# driver missing" / "egl: failed to create dri2 screen" noise on real hardware
# comes from libEGL being asked to init against the raw DRM fd and picking
# Mesa while the nvidia module owns the GPU.  Fix: in the SDDM session scripts,
# RUNTIME-gate on the actual GPU (same uevent scan section 31 uses for virtio):
# only when the DRM card's driver is nvidia/nouveau do we whitelist nvidia's
# GLVND vendor JSONs (__EGL_VENDOR_LIBRARY_FILENAMES) and force
# __GLX_VENDOR_LIBRARY_NAME=nvidia.  Under QEMU the driver is virtio-pci ->
# vars stay unset -> Mesa/llvmpipe fallback is untouched.  This CANNOT be
# decided at build time because the ISO always ships the nvidia program.
NV_VENDOR_DIR="$TREE/Programs/Nvidia/Current/Resources/Unmanaged/usr/share/glvnd/egl_vendor.d"
NV_FILES=""
if [ -d "$NV_VENDOR_DIR" ]; then
    for j in "$NV_VENDOR_DIR"/10_nvidia.json "$NV_VENDOR_DIR"/10_nvidia_wayland.json \
             "$NV_VENDOR_DIR"/15_nvidia_gbm.json "$NV_VENDOR_DIR"/20_nvidia_xcb.json \
             "$NV_VENDOR_DIR"/20_nvidia_xlib.json; do
        [ -f "$j" ] && NV_FILES="${NV_FILES}:/usr/share/glvnd/egl_vendor.d/$(basename "$j")"
    done
    NV_FILES="${NV_FILES#:}"
fi
for scr in "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/Xsession" \
           "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/wayland-session"; do
    [ -f "$scr" ] || continue
    if ! grep -q 'force-nvidia-glvnd' "$scr"; then
        python3 - "$scr" "$NV_FILES" <<'PY'
import sys
p, files = sys.argv[1], sys.argv[2]
with open(p) as fh:
    s = fh.readlines()
# find index of the exec line (the session launch), insert the gate before it
for i, l in enumerate(s):
    if l.lstrip().startswith('exec'):
        if files:
            frag = [
                '# --- force-nvidia-glvnd: nvidia EGL/GLX ONLY on a real NVIDIA GPU ---\n',
                'if [ -z "$__EGL_VENDOR_LIBRARY_FILENAMES" ]; then\n',
                '    for ue in /sys/class/drm/card*/device/uevent; do\n',
                '        [ -r "$ue" ] || continue\n',
                '        case "$(sed -n \'s/^DRIVER=//p\' "$ue" | head -1)" in\n',
                '            nvidia|nouveau)\n',
                '                export __EGL_VENDOR_LIBRARY_FILENAMES="%s"\n' % files,
                '                export __GLX_VENDOR_LIBRARY_NAME=nvidia\n',
                '                break\n',
                '                ;;\n',
                '        esac\n',
                '    done\n',
                'fi\n',
            ]
            s[i:i] = frag
        else:
            frag = [
                '# --- force-nvidia-glvnd: nvidia vendor JSONs not present; keeping Mesa ---\n',
            ]
            s[i:i] = frag
        break
open(p, 'w').writelines(s)
PY
        say "session force-nvidia: patched $(basename "$scr") (runtime-gated)"
    fi
done

# --- 42d) `wine boot` -> wineboot shim in the live user's shell rc -----------
# `wine boot` fails with "ShellExecuteEx failed: File not found"; wineboot is
# the real bootstrap.  Add a tiny wine() wrapper to the live user's rc and the
# skel so future users get it too.  The wrapper only intercepts argv1 == boot.
run_shim() {
    local rc="$1"; [ -z "$rc" ] && return 0
    if [ ! -f "$rc" ]; then
        # live user has no rc in the tree yet; create one with the shim so the
        # wrapper survives into the booted session.
        printf '%s\n' \
'wine() { if [ "$1" = "boot" ]; then shift; command wineboot "$@"; else command wine "$@"; fi; }' \
            > "$rc"
        say "wine shim created ${rc#$TREE/}"
        return 0
    fi
    if ! grep -q 'wine()' "$rc"; then
        printf '%s\n' \
'wine() { if [ "$1" = "boot" ]; then shift; command wineboot "$@"; else command wine "$@"; fi; }' \
            >> "$rc"
        say "wine shim appended to ${rc#$TREE/}"
    fi
}
mkdir -p "$TREE/Users/live"
run_shim "$TREE/Users/live/.zshrc"
run_shim "$TREE/Users/live/.bashrc"
run_shim "$TREE/Programs/EnhancedSkel/Settings/skel/.zshrc"
run_shim "$TREE/Programs/EnhancedSkel/Settings/skel/.bashrc"
run_shim "$TREE/Programs/EnhancedSkel/Current/Resources/Defaults/Settings/skel/.zshrc"
run_shim "$TREE/Programs/EnhancedSkel/Current/Resources/Defaults/Settings/skel/.bashrc"

# --- 42e) Unify Qt wayland QPA platform plugins to ONE Qt build (Qt/5.15.2) ----
# pinentry-qt / any Qt5 app that picks the *wayland* QPA gets
#   Qt: "Could not load the Qt platform plugin \"wayland\" in '' even though it was found"
# because the merged System/Index/lib/plugins/platforms ships the SAME plugin
# NAME from TWO Qt builds with DIFFERENT ABIs:
#   System/Index merges libqWaylandClient.so.5 -> Qt/5.15.2 (matches Qt Core),
#   yet the merged libqwayland-generic.so / libqwayland-egl.so still resolve to
#   Qt5Wayland/5.14.1's builds (die on dlopen against the 5.15.2 symbol table).
# The VM only "worked" by silently using a stock X server (qxcb) instead.
# Repoint every wayland QPA platform plugin in the merged Index so all of them
# resolve to the single Qt/5.15.2 build that owns libQt5WaylandClient (idempotent).
QPA="$TREE/System/Index/lib/plugins/platforms"
WIN_QPA="$TREE/Programs/Qt/5.15.2/plugins/platforms"
say "plugin ABI audit: merged wayland QPA set resolved against libQt5WaylandClient=Qt/5.15.2"
n=0
for name in libqwayland-generic.so libqwayland-egl.so libqwayland-xcomposite-glx.so libqwayland.so; do
    merge_link="$QPA/$name"
    [ -e "$merge_link" ] || continue
    cur="$(readlink "$merge_link" 2>/dev/null)"
    if [ -L "$merge_link" ] && [[ "$cur" == *Qt5Wayland/* ]]; then
        if [ -e "$WIN_QPA/$name" ]; then
            rm -f "$merge_link"
            ln -s "/Programs/Qt/5.15.2/plugins/platforms/$name" "$merge_link"
            say "  wayland QPA: $name -> Qt/5.15.2 (was $cur)"
            n=$((n+1))
        else
            say "  wayland QPA: $name no 5.15.2 twin, leaving as-is (was $cur)"
        fi
    elif [ -e "$WIN_QPA/$name" ]; then
        say "  wayland QPA: $name already Qt-build (ok)"
    fi
done
say "wayland QPA unify: $n plugin(s) repointed to Qt/5.15.2"

# --- 42f) Chipset-agnostic wifi driver autoload (System/Tasks/WifiAutoload) ----
# On REAL hardware (this laptop) the boot reaches the live session with NO
# wireless radio at all -- `ls /sys/class/net` shows only `lo` + wired, so
# GoboNet's detect_wifi_interface finds no phy80211 and the GoboNet scan loop
# runs iwlist against lo/enp3s0f1 ("doesn't support scanning",
# "Allocation failed: scan info").  The ISO SHIPS every wireless chipset's
# driver + firmware (iwlwifi, iwlvm, rtw88/rtw89, ath9k/10k/11k, rtl*, brcmfmac,
# mt76, ...) under Programs/Linux/7.1.5/lib/modules + Linux-Firmware, so the
# ONLY missing boot step is "bind the driver whose modules.alias owns THIS
# laptop's chipset".  Instead of a per-chipset whitelist, we iteratively
# modprobe a chipset via its PCI class 0x0280 modalias, which kmod matches
# against modules.alias itself -- whatever driver the ISO bundles that owns
# the present chip gets autoloaded.  Chipset-agnostic + idempotent.
#
# Boot task idiom mirrors §41's Network task: a real System/Tasks/WifiAutoload
# run by `StartTask WifiAutoload` in StartLiveCD BEFORE `StartTask Network`,
# so the radio exists before GoboNet's autoconnect scans for it.  Idempotent:
# a driver already bound (or a machine with no wireless PCI device at all) is
# a no-op; run us any number of times.
WIFITASK="$TREE/System/Tasks/WifiAutoload"
if [ ! -f "$WIFITASK" ]; then
    mkdir -p "$TREE/System/Tasks"
    cat > "$WIFITASK" <<'WIF'
#!/bin/bash
#
# WifiAutoload: bind whatever wireless PCI chipset is present on THIS boot to
# the driver the ISO ships for it.  Chipset-agnostic on purpose: kmod resolves
# each wireless device's MODALIAS (PCI class 0x0280, encoded as ...bc02sc80...)
# against /lib/modules/*/modules.alias, so the driver that owns the modalias --
# iwlwifi, iwlvm, iwldvm, rtw88/89, ath9k/10k/11k, rtl8xxxu, brcmfmac, mt76, ...
# -- is loaded with no whitelist to maintain.  The radio then shows up as a
# wlan*/phy80211 interface that GoboNet's autoconnect can find.
#
# Idempotent: a driver already bound (or no wireless PCI device at all) is a
# no-op; run it any number of times.
LOG=/Data/Variable/log
mkdir -p "$LOG"
logf="$LOG/wifi-autoload.log"

command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>/dev/null

# Already have a wireless radio?  Nothing to do.
if ! command -v grep >/dev/null 2>&1 || ! grep -q . /sys/class/net/*/wireless 2>/dev/null; then
    :
fi
for dev in /sys/class/net/*; do
    [ -d "$dev/wireless" ] && { echo "WifiAutoload: radio already up (${dev##*/})" >> "$logf"; exit 0; }
done

# Otherwise: load whatever driver owns each present wireless PCI device.
# Iterate PCI devices; if the modalias matches wireless class (bc02sc80), ask
# kmod to resolve+autoload the owning module from the ISO's modules.alias.
loaded=0
for uev in /sys/bus/pci/devices/*/uevent; do
    [ -r "$uev" ] || continue
    m="$(sed -n 's/^MODALIAS=//p' "$uev" 2>/dev/null)"
    case "$m" in
        *bc02sc800*|*bc0280*)  # PCI class 0x0280 = wireless controller
            if modprobe "$m" 2>>"$logf"; then
                echo "WifiAutoload: loaded driver for $m" >> "$logf"
                loaded=1
            fi
            ;;
    esac
done

# rfkill may have left the radio soft-blocked after the driver binds.
command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>/dev/null

[ "$loaded" = 1 ] && \
    echo "WifiAutoload: done (interface should appear as wlan*)" >> "$logf" || \
    echo "WifiAutoload: no wireless PCI device found on this boot" >> "$logf"
exit 0
WIF
    chmod 755 "$WIFITASK"
    say "WifiAutoload task installed (${WIFITASK#$TREE/})"
else
    say "WifiAutoload task already present ($( [ -e "$WIFITASK" ] && echo ok || echo stale ))"

fi
# Wire it into StartLiveCD right before §41's `StartTask Network`, so the radio
# is up before GoboNet's known-network scan; idempotent per-script.
for sld in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
    [ -f "$sld" ] || continue
    if ! grep -q 'StartTask WifiAutoload' "$sld"; then
        sed -i '0,/^StartTask Network/{/^StartTask Network/i\
msg "Bringing up wireless radio (chipset autoload)"\
StartTask WifiAutoload
}' "$sld"
        say "StartLiveCD: WifiAutoload wired before Network (${sld#$TREE/})"
    else
        say "StartLiveCD: WifiAutoload already wired (${sld#$TREE/})"
    fi
done

say "wifi bring-up: chipset-agnostic driver autoload wired (PCI class 0x0280 -> kmod modalias)"


# --- 42g) Kill the dead PCIEVENT udev idiom the nvidia bake installs (lines ----
# 1105-1119) and replace it with a boot-time task that creates the nvidia
# control devices the driver needs.  The bake's OWN rule previously shipped:
#
#   PCIEVENT="/bin/sh -c '...nvidia-modprobe -c 0 -m -u -d...'"
#   PCIEVENT and KERNEL== nvidia rules use RUN+=$PCIEVENT
#
# which eudev REJECTS (udevadm test: Unknown key 'PCIEVENT'; Rule 8 is invalid
# on eudev) -- so /dev/nvidiactl never existed on real boots even though the
# kmod stack loaded (lsmod: nvidia 580.159.04 bound, but nvidia-smi
# "couldn't communicate" + no /dev/nvidia*).  Verified single-line fix on this
# exact laptop:  sudo mknod /dev/nvidiactl c 195 255  brings nvidia-smi back
# instantly (GTX 1060, driver 580.159.04).  We bake that proven one-liner as a
# udev-valid System/Tasks/NvidiaCtl bring-up, gated on the PCI vendor that
# actually answered (idempotent: rfkill-style `[ -e ... ] ||` guard).
nctl_task="$TREE/Programs/Nvidia/Current/Resources/Tasks/NvidiaCtl"
if [ ! -f "$nctl_task" ]; then
    mkdir -p "$(dirname "$nctl_task")"
    cat > "$nctl_task" <<'NVC'
#!/bin/bash
# NvidiaCtl: create the /dev/nvidiactl c 195 255 node the driver stack needs
# (and its udev rules are dead under eudev).  Plain udev calling convention.
start() {
    # Only on real NVIDIA PCI hardware (mirrors force-nvidia gating).
    need=0
    for d in /sys/bus/pci/devices/*; do
        [ -f "$d/vendor" ] && [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] && need=1
    done
    [ "$need" = 1 ] || { echo "NvidiaCtl: no NVIDIA PCI device present; nothing to do"; exit 0; }
    [ -c /dev/nvidiactl ] || mknod /dev/nvidiactl c 195 255
    [ -c /dev/nvidia0 ]   || mknod /dev/nvidia0   c 195 0
    chmod 660 /dev/nvidiactl /dev/nvidia0 2>/dev/null || true
    chgrp video /dev/nvidiactl /dev/nvidia0 2>/dev/null || true
    command -v modprobe >/dev/null 2>&1 && { modprobe nvidia-uvm 2>/dev/null; modprobe nvidia-modeset 2>/dev/null; }
    echo "NvidiaCtl: /dev/nvidiactl ready (nvidia-smi visible)"
    true
}
stop() { :; }
case "$1" in *) start ;; esac
NVC
    chmod 755 "$nctl_task"
    say "NvidiaCtl task baked (${nctl_task#$TREE/})"
else
    say "NvidiaCtl task already baked (ok)"
fi

# --- 42h) Link the NVIDIA Vulkan ICD + implicit-layer JSONs into the merged ----
# /usr/share/vulkan/icd.d + implicit_layer.d (same idiom as the in-tree ICD
# wiring at 1156-1170, but for the Resources/Unmanaged twin that actually ships
# on current NVIDIA builds + the explicit-layer JSON).  The runtime consumer
# (Mesa/Nvidia loader, vulkaninfo) only looks in System/Index/share/vulkan,
# and the driver's own Programs tree left these unlinked -- so "vulkaninfo"
# listed Intel-only until we hand link nvidia_icd.json.  Idempotent.
VUID="$TREE/System/Index/share/vulkan"
NVUNM="$TREE/Programs/Nvidia/Current/Resources/Unmanaged/usr/share/vulkan"
for sub in icd.d implicit_layer.d; do
    mkdir -p "$VUID/$sub"
    for json in nvidia_icd.json nvidia_icd.x86_64.json nvidia_icd.i686.json nvidia_layers.json; do
        [ -f "$json" ] || continue
        b="$(basename "$json")"
        if [ -e "$VUID/$sub/$b" ]; then
            say "  vulkan $sub: $b already present (ok)"
        else
            ln -sf "/${json#$TREE}" "$VUID/$sub/$b"
            say "  vulkan $sub: linked $b (${json#$TREE/})"
        fi
    done
done

# --- 43) Phone / MTP automount: /Mount/phone via simple-mtpfs -----------------
# GoboLinux's main user-mount dir is /Mount (mnt -> Mount; media -> Mount/Media),
# so any automounted phone lands on /Mount/phone.  This is the runtime half the
# 'devices' step packages (Libusb + Libmtp + Simple-Mtpfs) have been missing:
#
#   - Simple-Mtpfs is a FUSE filesystem; this ISO's Fuse packaging is NOT ready
#     for it: /etc/fuse.conf is a dangling symlink to /Programs/Fuse/Settings/
#     fuse.conf (that file does not exist on the merged tree) and the shipped
#     fusermount is NOT setuid root, so the non-root `live` desktop session can
#     never mount the phone.  We fix both.
#   - Simple-Mtpfs sets st_uid/st_gid from the *mounting* process uid, so the
#     mount MUST run as the `live` desktop user (uid 1000) -- a root mount would
#     hand the user a phone owned by root.  Mirror the GoboNet idiom and run it
#     via `su live`.  (Matches 'devices' README claim: automount as the desktop
#     session user.)
#   - Triggered two ways: (a) a System/Tasks/MtpPhone task invoked from BootUp
#     and StartLiveCD so a device already plugged at boot gets mounted, and
#     (b) a udev rule on MTP/PTP USB interfaces for hotplug.  Both are
#     idempotent: task re-checks "already mounted" before doing anything.
#
# MTP/PTP USB interface classes: Android phones expose MTP as class 0x08
# (mass-storage) subtype 0x06 (SCSI, "protocol 0x50"), cameras PTP as class
# 0x06 subtype 0x01.  We match both; the task's own simple-mtpfs --list-devices
# gate makes any false positive a harmless no-op.

# 43a) Repair Fuse so the desktop user can FUSE-mount at all.
#   1) materialize the real /Programs/Fuse/Settings/fuse.conf (fixes the
#      dangling /etc/fuse.conf symlink) with user_allow_other enabled so a
#      non-root mount may also use allow_other,
#   2) fusermount must be setuid root (standard on Debian/Ubuntu; this ISO
#      ships it 0755) or libfuse refuses non-root mounts.
fuse_conf_target="$TREE/Programs/Fuse/Settings/fuse.conf"
if [ ! -f "$fuse_conf_target" ]; then
    mkdir -p "$(dirname "$fuse_conf_target")"
    cat > "$fuse_conf_target" <<'FCS'
# /etc/fuse.conf -> /Programs/Fuse/Settings/fuse.conf  (baked by livefix 43a)
# Enables FUSE mounts with allow_other for non-root users, which the Simple-Mtpfs
# phone automount needs the live desktop user to reach through.
user_allow_other
FCS
    chmod 644 "$fuse_conf_target"
    say "fuse: wrote ${fuse_conf_target#$TREE/} (user_allow_other)"
else
    say "fuse: ${fuse_conf_target#$TREE/} already present (ok)"
fi
for fu in "$TREE/Programs/Fuse/2.9.9/bin/fusermount" "$TREE/Programs/Fuse/3.16.2/bin/fusermount3"; do
    if [ -x "$fu" ] && [ ! -u "$fu" ]; then
        chmod u+s "$fu"
        say "fuse: setuid on ${fu#$TREE/}"
    fi
done

# 43b) /Mount/phone mountpoint, owned by the live desktop session (uid/gid 1000).
mkdir -p "$TREE/Mount/phone"
chmod 775 "$TREE/Mount/phone"
chown 1000:1000 "$TREE/Mount/phone" 2>/dev/null || true
[ -d "$TREE/Mount/phone" ] && say "mountpoint: /Mount/phone ready (live 1000:1000 ok)"

# 43c) System/Tasks/MtpPhone: automount the first attached MTP/PTP device.
MTPTASK="$TREE/System/Tasks/MtpPhone"
if [ ! -f "$MTPTASK" ]; then
    mkdir -p "$(dirname "$MTPTASK")"
    cat > "$MTPTASK" <<'MTP'
#!/bin/bash
# MtpPhone: mount the first attached MTP/PTP device (usually an Android phone)
# onto /Mount/phone via simple-mtpfs.  Runs as the `live` desktop user so the
# mounted files are owned by that session (Simple-Mtpfs sets ownership from the
# mounting process).  Idempotent: no device present / already mounted -> no-op.
op="$1"; [ "$op" ] || op="start"

# udev RUNs run with a near-empty env; give the task its own resolution paths.
export PATH=/System/Index/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/Programs/Simple-Mtpfs/Current/bin

LOG=/Data/Variable/log
MP=/Mount/phone
SM="$(readlink -f /Programs/Simple-Mtpfs/Current 2>/dev/null)/bin/simple-mtpfs"
FU="$(readlink -f /Programs/Fuse/Current 2>/dev/null)/bin/fusermount"

start() {
    mkdir -p "$LOG"
    [ -x "$SM" ] || { echo "MtpPhone: simple-mtpfs not installed" >>"$LOG/mtp-phone.log"; return 0; }
    mountpoint -q "$MP" 2>/dev/null && { echo "MtpPhone: already mounted at $MP" >>"$LOG/mtp-phone.log"; return 0; }

    # Desktop user owning the session (GoboNet idiom); fall back to root.
    muser="live"
    id -u "$muser" >/dev/null 2>&1 || muser="root"

    # Wait briefly for the device to enumerate (udev can fire before libusb
    # sees it); simple-mtpfs --list-devices is our authoritative presence test.
    for i in $(seq 1 10); do
        detected="$("$SM" --list-devices 2>/dev/null | grep -c '^[0-9]*:')"
        [ "$detected" -gt 0 ] && break
        sleep 1
    done
    if [ "$detected" -le 0 ]; then
        echo "$(date): no MTP device present" >>"$LOG/mtp-phone.log"
        return 0
    fi

    mkdir -p "$MP"
    chmod 775 "$MP"
    if [ "$muser" = "root" ]; then
        setsid -f "$SM" "$MP" </dev/null >>"$LOG/mtp-phone.log" 2>&1 || true
    else
        setsid -f su - "$muser" -c "$SM '$MP'" </dev/null >>"$LOG/mtp-phone.log" 2>&1 || true
    fi
    for i in $(seq 1 10); do
        mountpoint -q "$MP" 2>/dev/null && break
        sleep 1
    done
    if mountpoint -q "$MP" 2>/dev/null; then
        echo "$(date): mounted MTP device at $MP" >>"$LOG/mtp-phone.log"
    else
        echo "$(date): mount did not settle (see mtp-phone.log)" >>"$LOG/mtp-phone.log"
    fi
    return 0
}

stop() {
    [ -x "$FU" ] || return 0
    mountpoint -q "$MP" 2>/dev/null || return 0
    "$FU" -u "$MP" >>"$LOG/mtp-phone.log" 2>&1 || fusermount -u "$MP" >>"$LOG/mtp-phone.log" 2>&1 || true
    echo "$(date): unmounted $MP" >>"$LOG/mtp-phone.log"
    return 0
}

case "$op" in
    [Ss]tart) start ;;
    [Ss]top)  stop ;;
    *) echo "usage: MtpPhone [start|stop]"; exit 2 ;;
esac
MTP
    chmod 755 "$MTPTASK"
    say "task baked (${MTPTASK#$TREE/})"
else
    say "task already baked (${MTPTASK#$TREE/}, ok)"
fi

# 43d) Boot wiring: mount a phone that was already plugged in at boot.
# BootUp line goes right after the message bus / network bring-up; StartLiveCD
# keeps the same ordering so both a DVD boot and a live-installed system work.
phboot="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"
[ -f "$phboot" ] || phboot="$bdir/BootUp"
if [ -f "$phboot" ]; then
    if ! grep -q 'MtpPhone Start' "$phboot"; then
        sed -i '/^Exec "Starting message bus\.\.\."/a Exec "Mounting phone..."                MtpPhone Start' "$phboot"
        say "BootUp: MtpPhone wired after message bus"
    else
        say "BootUp: MtpPhone start already present (ok)"
    fi
fi
for sld in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
    [ -f "$sld" ] || continue
    if ! grep -q 'StartTask MtpPhone' "$sld"; then
        sed -i '/^StartTask MessageBus/a\msg "Mounting phone"\nStartTask MtpPhone' "$sld"
        say "StartLiveCD: MtpPhone wired after MessageBus (${sld#$TREE/})"
    else
        say "StartLiveCD: MtpPhone start already present (${sld#$TREE/}, ok)"
    fi
done

# 43e) udev: hotplug rule for MTP/PTP USB interfaces -> MtpPhone start/stop.
# Simple eudev-safe rule (no variables/expansion); mismatches are no-ops
# because the task re-tests with simple-mtpfs --list-devices.
MTPRULE="$TREE/etc/udev/rules.d/70-mtp-phone.rules"
if [ ! -f "$MTPRULE" ]; then
    mkdir -p "$(dirname "$MTPRULE")"
    cat > "$MTPRULE" <<'MTPR'
# Android phone / PTP camera automount -> /Mount/phone (livefix 43e).
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="08", ATTR{bInterfaceSubClass}=="06", ACTION=="add",    RUN+="/System/Tasks/MtpPhone", ENV{MTP}="1"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="06", ATTR{bInterfaceSubClass}=="01", ACTION=="add",    RUN+="/System/Tasks/MtpPhone", ENV{MTP}="1"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ENV{MTP}=="1", ACTION=="remove", RUN+="/System/Tasks/MtpPhone stop"
MTPR
    say "udev: wrote ${MTPRULE#$TREE/}"
else
    say "udev: ${MTPRULE#$TREE/} already present (ok)"
fi

# --- 44) GoboNet GUI as root/sudo: bridge the session display to uid 0 -------
# `gobonet` run as root (or via sudo) on the live desktop dies before any GUI
# dialog can open with:
#   Failed to create wl_display (Permission denied)
#   qt.qpa.plugin: Could not load the Qt platform plugin "wayland" ...
#   Authorization required, but no authorization protocol specified
#   qt.qpa.xcb: could not connect to display :0
# The desktop user (`live`) is fine because their session carries DISPLAY,
# WAYLAND_DISPLAY / XDG_RUNTIME_DIR (0700 /run/user/1000 where the Wayland
# compositor socket lives) and XAUTHORITY (the Xwayland cookie for :0).  A root
# process inherits none of it -- no access to /run/user/1000's socket, no
# .Xauthority cookie -- so pinentry-qt (gobonet's password dialog via show_dialog)
# and any Qt/GTK X11 client refuse to start.
#
# Fix (baked here, applied at runtime):
#   * Xsession/wayland-session snapshot the launched session's display env
#     (DISPLAY, WAYLAND_DISPLAY, XDG_RUNTIME_DIR, XAUTHORITY,
#     DBUS_SESSION_BUS_ADDRESS) to /Data/Variable/log/live-session-env (644),
#     and best-effort `xhost +SI:localuser:root` on the X11 display.
#   * /System/Index/bin/gobo-root-display rebuilds uid 0's display access from
#     that snapshot: creates /run/user/0, symlinks the desktop user's wayland-*
#     sockets in, seeds /root/.Xauthority from the session cookie, prefers X11
#     (xcb over Xwayland) and falls back to Wayland; prints export lines.
#   * gobonet's script sources that bridge before its main body when EUID 0, so
#     `sudo gobonet` / a root shell both get a working GUI backend.
RUNROOT="$TREE/System/Index/bin"
# Session scripts: write the display env before the session binary is exec'd.
for scr in "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/Xsession" \
           "$TREE/Programs/SDDM/$SDDM_VER/share/sddm/scripts/wayland-session"; do
    [ -f "$scr" ] || continue
    python3 - "$scr" <<'PY'
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    lines = fh.readlines()
if any("livefix 44" in l for l in lines):
    print("[livefix44] %s already has session-env snapshot" % p)
    sys.exit(0)
for i in range(len(lines) - 1, -1, -1):
    if lines[i].lstrip().startswith("exec"):
        idx = i
        break
else:
    print("[livefix44] %s: no exec line, skipping" % p)
    sys.exit(0)
frag = [
    "\n# --- livefix 44: snapshot session display env for root/sudo GUI (gobonet) ---\n",
    "if [ -n \"${XDG_RUNTIME_DIR:-}\" ]; then\n",
    "    {\n",
    '        echo "export DISPLAY=\\"${DISPLAY:-}\\""\n',
    '        echo "export WAYLAND_DISPLAY=\\"${WAYLAND_DISPLAY:-}\\""\n',
    '        echo "export XDG_RUNTIME_DIR=\\"${XDG_RUNTIME_DIR:-}\\""\n',
    '        echo "export XAUTHORITY=\\"${XAUTHORITY:-}\\""\n',
    '        echo "export DBUS_SESSION_BUS_ADDRESS=\\"${DBUS_SESSION_BUS_ADDRESS:-}\\""\n',
    "    } > /Data/Variable/log/live-session-env\n",
    "    chmod 644 /Data/Variable/log/live-session-env\n",
    '    command -v xhost >/dev/null 2>&1 && { [ -n "${DISPLAY:-}" ] && xhost +SI:localuser:root >/dev/null 2>&1 || true; }\n',
    "fi\n",
]
lines[idx:idx] = frag
with open(p, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
print("[livefix44] session env snapshot inserted in %s" % p)
PY
    say "livefix44 session-env hook: $(basename "$scr") patched"
done
# Root display bridge helper.  Also copied to System/Scripts (other tasks may
# not have /System/Index/bin on PATH in the boot shell).
if [ ! -e "$RUNROOT/gobo-root-display" ]; then
    mkdir -p "$RUNROOT" "$TREE/System/Scripts"
    cat > "$RUNROOT/gobo-root-display" <<'GRD'
#!/bin/bash
# gobo-root-display [-e] [--exec <cmd...>]
# Rebuild uid 0's display access from the live desktop session snapshot
# (/Data/Variable/log/live-session-env).  A root process cannot reach the
# `live` user's Wayland socket (XDG_RUNTIME_DIR=/run/user/UID, 0700) nor has an
# .Xauthority cookie for the Xwayland display, so gobonet/pinentry/Qt GUIs die
# with "Permission denied" / "Authorization required".  This script:
#   * creates /run/user/0 (root's runtime dir) and symlinks the desktop user's
#     wayland-* sockets into it,
#   * seeds /root/.Xauthority from the session's X11 cookie,
#   * prefers the X11 (xcb over Xwayland) platform, falling back to Wayland,
#   * prints `export ...` lines (default) or, with --exec, runs a command in
#     that environment.
set -u
SVCFG=/Data/Variable/log/live-session-env
MODE=env
if [ "${1:-}" = "--exec" ]; then
    MODE=exec
    shift
fi

ulive="$(id -u live 2>/dev/null || echo 1000)"
rt_live="/run/user/$ulive"

if [ -f "$SVCFG" ]; then
    . "$SVCFG"
fi

DISPLAY="${DISPLAY:-:0}"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if [ "$(id -u)" = 0 ]; then
    mkdir -p /run/user/0 2>/dev/null || true
    chmod 700 /run/user/0 2>/dev/null || true
    rtdir="${XDG_RUNTIME_DIR:-$rt_live}"
    [ -d "$rtdir" ] || rtdir="$rt_live"
    for wsock in "$rtdir"/wayland-*; do
        [ -S "$wsock" ] || continue
        ln -sfn "$wsock" "/run/user/0/$(basename "$wsock")" 2>/dev/null || true
    done
    # the desktop user's runtime dir must be traversable for the symlinks
    chmod 711 "$rtdir" 2>/dev/null || true
    XDG_RUNTIME_DIR=/run/user/0
fi

# X11 cookie: session value, else the newest xauth_* under the desktop user's
# runtime dir (Xwayland writes xauth_<rand> there).
XA="${XAUTHORITY:-}"
if [ -z "$XA" ] || [ ! -f "$XA" ]; then
    for xa in "$rt_live"/xauth_*; do
        [ -f "$xa" ] || continue
        XA="$xa"
        break
    done
fi
if [ -n "$XA" ] && [ -f "$XA" ]; then
    if [ "$(id -u)" = 0 ]; then
        cp -f "$XA" /root/.Xauthority 2>/dev/null || true
        chown root:root /root/.Xauthority 2>/dev/null || true
        chmod 600 /root/.Xauthority 2>/dev/null || true
        XA=/root/.Xauthority
    fi
    export XAUTHORITY="$XA"
fi

export DISPLAY="$DISPLAY"
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$rt_live}"

# Prefer xcb (Xwayland) when a usable cookie exists - matches what the `live`
# desktop itself uses for Qt/pinentry; Wayland socket is the fallback.
if [ -n "${XAUTHORITY:-}" ] && [ -f "${XAUTHORITY:-/no}" ]; then
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
else
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
fi
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}"
fi

case "$MODE" in
    env)
        echo "export DISPLAY=\"$DISPLAY\""
        echo "export WAYLAND_DISPLAY=\"$WAYLAND_DISPLAY\""
        echo "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""
        echo "export QT_QPA_PLATFORM=\"$QT_QPA_PLATFORM\""
        [ -n "${XAUTHORITY:-}" ] && echo "export XAUTHORITY=\"$XAUTHORITY\""
        [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && echo "export DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\""
        ;;
    exec)
        exec "$@"
        ;;
esac
GRD
    chmod 755 "$RUNROOT/gobo-root-display"
    printf '%s\n' \
        '#!/bin/bash' \
        'exec /System/Index/bin/gobo-root-display --exec "$@"' \
        > "$TREE/System/Scripts/gobo-root-display"
    chmod 755 "$TREE/System/Scripts/gobo-root-display"
    say "gobo-root-display bridge installed (Index + System/Scripts)"
else
    say "gobo-root-display bridge already present (ok)"
fi
# gobonet: bootstrap the display bridge when running as root/sudo.
GBNDIR="$(readlink -f "$TREE/Programs/GoboNet/Current" 2>/dev/null || echo "$TREE/Programs/GoboNet/0.12")/bin"
if [ -f "$GBNDIR/gobonet" ]; then
    python3 - "$GBNDIR/gobonet" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "livefix 44" in s:
    print("[livefix44] gobonet already bridged")
    sys.exit(0)
head, sep, tail = s.partition("\n")
if not head.startswith("#!"):
    print("[livefix44] unexpected gobonet header; skipping")
    sys.exit(1)
guard = '''# livefix 44: when run as root/sudo, borrow the desktop session display
if [ "$(id -u)" = 0 ] && [ -r /Data/Variable/log/live-session-env ] && [ -x /System/Index/bin/gobo-root-display ]; then
    eval "$(/System/Index/bin/gobo-root-display)"
fi

'''
open(p, "w", encoding="utf-8").write(head + "\n" + guard + tail)
print("[livefix44] gobonet root display bridge prepended")
PY
    say "gobonet root-display bootstrap: $(readlink -f "$GBNDIR/gobonet") patched"
else
    say "WARNING: gobonet bin not found ($GBNDIR/gobonet) - root GUI bridge skipped"
fi

# 45 - ZFS root boot support for the custom SysVinit runtime.
# Delegates to zfs45.sh (sibling of this script): OpenZFS 90zfs dracut module
# hardening, GenGrubConf root=zfs/initrd handling, WriteBoot64 --add zfs, BootUp
# udev-settle before swapon, and Installer ZFS pool + swap zvol support.
ZFS45_HELPER="$(dirname "$(readlink -f "$0")")/zfs45.sh"
if [ -x "$ZFS45_HELPER" ]; then
    bash "$ZFS45_HELPER" "$TREE" \
        || say "WARNING: zfs45.sh reported an error on $TREE (check the output above)"
else
    say "zfs45.sh helper not found ($ZFS45_HELPER) - ZFS root plumbing skipped"
fi

# 46 - XIVLauncher: import the host CA bundle into the Wine prefix trust store.
# The wrapper runs `wineboot` on a fresh prefix, whose Windows cert store starts
# EMPTY. .NET/SChannel (Velopack self-update, Square Enix login/news, Dalamud
# downloads) then fails every TLS handshake even while the host is online.
# Inject an idempotent per-prefix import into the wrapper unless already there.
shopt -s nullglob
for XLF in "$TREE"/Programs/FFXIVQuickLauncher/*/bin/xivlauncher
do
    if ! grep -q "gobo livefix 46" "$XLF"; then
        CA46='# gobo livefix 46: import the host CA bundle into the prefix trust store.
# .NET/SChannel under Wine verifies TLS against the prefix'"'"'s Windows cert
# store, which wineboot creates EMPTY; without this every HTTPS call fails
# even while the host is online (Velopack self-update, SE login/news, Dalamud).
CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
[ -f /System/Settings/ssl/certs/ca-certificates.crt ] && CA_BUNDLE=/System/Settings/ssl/certs/ca-certificates.crt
CA_FLAG="$WINEPREFIX/.gobo-cacert-imported"
if [ -f "$CA_BUNDLE" ] && [ ! -f "$CA_FLAG" ]; then
    CA_TMP="$WINEPREFIX/.ca-import.$$"
    rm -rf "$CA_TMP" && mkdir -p "$CA_TMP"
    awk '"'"'/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s/cert-%04d.pem", d, n); print > f; next} f{print > f}'"'"' d="$CA_TMP" "$CA_BUNDLE"
    imp=0
    for cf in "$CA_TMP"/cert-*.pem; do
        [ -f "$cf" ] || continue
        WINEDEBUG=-all "$WINE" certutil -addstore -f root "Z:${cf#/}" >/dev/null 2>&1 && imp=1
    done
    rm -rf "$CA_TMP"
    [ "$imp" = 1 ] && touch "$CA_FLAG"
fi
'
        python3 - "$XLF" "$CA46" <<'PY'
import sys
xl, block = sys.argv[1], sys.argv[2]
src = open(xl).read()
exec_marker = 'exec "$WINE" "$APP" "$@"'
assert exec_marker in src, "exec line not found in %s" % xl
src = src.replace(exec_marker, block + "\n" + exec_marker)
open(xl, "w").write(src)
print("[livefix46] CA trust import injected into " + xl)
PY
    else
        say "ok (already) "${XLF#$TREE/}""
    fi
done
shopt -u nullglob

# --- 47) glibc 2.44-2 libcrypt: drop the dead 2.30 built-in, ship libxcrypt --
# The glibc 2.44-2 upgrade package kept the base 2.30 `libcrypt-2.30.so`
# (glibc >= 2.34 split libcrypt OUT into libxcrypt, so the Debian libc6 2.44
# ships no libcrypt at all).  The 2.30 leftover requires __snprintf@GLIBC_PRIVATE,
# which libc 2.44 no longer exports: any dlopen of libcrypt.so.1 fails and
# Linux-PAM reports "Module is unknown" for pam_unix.so -> the SDDM greeter
# could not start.  Fix = install the libxcrypt (Debian libcrypt1) module
# libcrypt.so.1.1.0 (SONAME libcrypt.so.1, built for GLIBC_2.38, zero
# GLIBC_PRIVATE refs) and re-point the tree + index links.  Idempotent: skips
# once libcrypt-2.30.so is gone.
GLIB_VER=2.44-2
G_TREE="$TREE/Programs/Glibc/$GLIB_VER"
if [ -e "$TREE/Programs/Glibc/$GLIB_VER/lib/libcrypt-2.30.so" ]; then
    say "glibc $GLIB_VER still ships broken libcrypt-2.30.so -- replacing with libxcrypt"
    LIBCRYPT_DEB="${LIBCRYPT1_DEB:-/tmp/libcrypt1_4.5.2+20251210-1_amd64.deb}"
    LIBCRYPT_URL="http://deb.debian.org/debian/pool/main/libx/libxcrypt/libcrypt1_4.5.2+20251210-1_amd64.deb"
    if [ ! -f "$LIBCRYPT_DEB" ]; then
        curl -fsSL --max-time 120 -o "$LIBCRYPT_DEB" "$LIBCRYPT_URL" \
            || { say "ERROR: could not fetch libcrypt1 deb for glibc libcrypt fix"; }
    fi
    if [ -f "$LIBCRYPT_DEB" ]; then
        G_WORK="$TREE/var/tmp/gobo-livefix-libxcrypt-$$"
        rm -rf "$G_WORK" && mkdir -p "$G_WORK"
        ar p "$LIBCRYPT_DEB" data.tar.xz | tar xJf - -C "$G_WORK" \
            && cp -a --remove-destination "$G_WORK/usr/lib/x86_64-linux-gnu/libcrypt.so.1.1.0" \
                    "$G_TREE/lib/libcrypt.so.1.1.0" \
            && rm -f "$G_TREE/lib/libcrypt-2.30.so" \
            && rm -f "$G_TREE/lib/libcrypt.so.1" "$G_TREE/lib/libcrypt.so" \
            && ln -s libcrypt.so.1.1.0 "$G_TREE/lib/libcrypt.so.1" \
            && ln -s libcrypt.so.1 "$G_TREE/lib/libcrypt.so"
        RC=$?
        rm -rf "$G_WORK"
        if [ $RC -eq 0 ]; then
            rm -f "$TREE/System/Index/lib/libcrypt-2.30.so"
            for hl in \
                "$TREE/System/Index/lib/libcrypt.so.1" \
                "$TREE/System/Index/lib/libcrypt.so" \
                "$TREE/lib64/libcrypt.so.1" \
                "$TREE/lib64/libcrypt.so" \
            ; do
                [ -d "$(dirname "$hl")" ] && ln -sfn "/Programs/Glibc/$GLIB_VER/lib/libcrypt.so.1" "$hl"
            done
            for hl in "$TREE/usr/lib/libcrypt.so.1" "$TREE/usr/lib/libcrypt.so"; do
                [ -d "$(dirname "$hl")" ] && ln -sfn "/Programs/Glibc/$GLIB_VER/lib/libcrypt.so.1" "$hl"
            done
            say "glibc libcrypt fixed (libcrypt.so.1 -> libxcrypt libcrypt.so.1.1.0, 2.30 built-in removed)"
        else
            say "WARNING: libcrypt replacement failed in $G_TREE"
        fi
    fi
else
    say "glibc $GLIB_VER libcrypt already fixed (no libcrypt-2.30.so) -- skipping"
fi

# --- 48) Locale: force a real UTF-8 locale for every login ------------------
# The base ISO boots with NO locale exported (LANG/LC_ALL unset -> "C"), so
# Plasma emits KPluginFactory warnings (".../meta.json: parameter ... is not
# a member of the dict" / "Assertion failed in KSycocaFactoryList") for every
# plugin and package, Global Themes "Install" fails and Window Decorations
# lists nothing. pam_env /etc/environment reaches both SDDM and the Plasma
# session, and glibc 2.44-2 ships the en_US.utf8 locale archive already.
locf="$TREE/System/Settings/environment"
if [ -e "$locf" ] || [ -L "$locf" ]; then
    for kv in LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; do
        key="${kv%%=*}"
        sed -i "/^${key}=/d" "$locf"
        printf '%s\n' "$kv" >> "$locf"
    done
    say "locale exported: LANG + LC_ALL = en_US.UTF-8 (${locf#$TREE/})"
else
    say "WARNING: ${locf#$TREE/} not found; cannot export locale"
fi

# --- 49) polkitd: boot task + StartLiveCD/BootUp wiring ---------------------
# polkitd NEVER runs on the live ISO: the base ships the full polkitd under
# Programs/Polkit (protocol + elogind linked through /System/Index/lib) but no
# Gobo boot task starts it, and its D-Bus system-services Exec points at an FHS
# path that only resolves AFTER the Index is present.  Without the
# org.freedesktop.PolicyKit1 owner alive, elogind answers every
# PowerOff/Reboot/Suspend authorization check with deny/unknown, so the Plasma
# session menu hides Shutdown/Restart entirely and SDDM's power buttons vanish.
# Fix: a pgrep-guarded Polkit StartTask next to Elogind/SeatD plus a D-Bus
# system-services Exec rewrite to the resolved /Programs path (same rule as the
# generic section-7 repair, done explicitly here so polkitd also starts before
# any Index/Current flip the merge made).
POLKIT_VER=$(basename "$(readlink "$TREE/Programs/Polkit/Current" 2>/dev/null || echo Polkit/126)")
polkit_task="$TREE/Programs/Polkit/$POLKIT_VER/Resources/Tasks/Polkit"
mkdir -p "$(dirname "$polkit_task")"
cat > "$polkit_task" <<'EOF'
#!/bin/sh
# Starts polkitd (full daemon) under the merged polkit tree. Gobo boot tasks
# run as root, but the D-Bus policy for org.freedesktop.PolicyKit1 only grants
# the bus name to user polkitd (uid 999), so the daemon MUST run unprivileged;
# runuser drops root for it (polkitd does not self-drop its gid/uid).
# runuser is shipped by Util-Linux. The NEEDED libs all resolve via
# /System/Index/lib, so no LD_LIBRARY_PATH is needed (unlike elogind's private
# lib/elogind dir).
case "$1" in
[Ss]tart)
    pgrep -x polkitd >/dev/null 2>&1 && exit 0
    PK="$(readlink -f /Programs/Polkit/Current)/lib/polkit-1/polkitd"
    if [ -x "$PK" ]; then
        mkdir -p /run/polkit /Data/Variable/log
        chown polkitd:polkitd /run/polkit 2>/dev/null || true
        # polkitd stays in the foreground as user polkitd; setsid -f detaches it
        # so it survives the boot shell teardown (mirrors the sddm Exec line).
        setsid -f runuser -u polkitd -- "$PK" --no-debug >>/Data/Variable/log/polkitd.log 2>&1 &
        # give it a beat and verify (polkitd may take a moment to register).
        for _p in 1 2 3 4 5 6 7 8; do
            pgrep -xc polkitd >/dev/null 2>&1 && break
            sleep 1
        done
        if pgrep -xc polkitd >/dev/null 2>&1; then
            echo "polkitd started $(date '+%F %T')" >>/Data/Variable/log/polkitd.log
            exit 0
        fi
        echo "polkitd FAILED to start $(date '+%F %T')" >>/Data/Variable/log/polkitd.log
        exit 1
    fi
    echo "polkitd binary missing: $PK" >>/Data/Variable/log/polkitd.log
    exit 1
    ;;
[Ss]top)
    pkill -x polkitd
    ;;
esac
EOF
chmod 755 "$polkit_task"
# /System/Tasks/Polkit symlink (ISO-dangling is fine; -e follows the link, so
# guard on -L too, like the Elogind/SeatD/SDDM block above).
[ -e "$TREE/System/Tasks/Polkit" ] || [ -L "$TREE/System/Tasks/Polkit" ] || \
    { mkdir -p "$TREE/System/Tasks"; ln -s "${polkit_task#$TREE}" "$TREE/System/Tasks/Polkit"; }
# Repoint the D-Bus system-services Exec at the resolved /Programs path (the
# FHS /usr/lib/polkit-1/polkitd form only works after the Index links exist)
# and run the daemon as polkitd (the dbus policy only grants the bus name to
# user polkitd, so a root-spawned polkitd would be denied ownership).
for svc in "$TREE"/Programs/Polkit/*/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service; do
    [ -f "$svc" ] || continue
    sed -i 's#^Exec=.*#Exec=/Programs/Polkit/'"$POLKIT_VER"'/lib/polkit-1/polkitd --no-debug#' "$svc"
    sed -i 's/^User=.*/User=polkitd/' "$svc"
done
# Wire Polkit Start into StartLiveCD (live boot path; right after Elogind so
# logind's authorization checks find the daemon up first).
for sld in "$TREE"/Programs/LiveCD/*/bin/StartLiveCD; do
    [ -f "$sld" ] || continue
    if ! grep -q 'StartTask Polkit' "$sld"; then
        sed -i '/^StartTask Elogind/a\msg "Starting policy daemon"\nStartTask Polkit' "$sld"
        say "StartLiveCD: polkitd wired after elogind (${sld#$TREE/})"
    else
        say "StartLiveCD: polkitd already wired (${sld#$TREE/})"
    fi
done
# Wire into BootUp (non-live Boot=... path): right after elogind's Exec line,
# using the same BootScripts Settings copy section 12 edits.
bootup="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"
if [ -f "$bootup" ] && ! grep -q 'Polkit Start' "$bootup"; then
    sed -i '/^Exec "Starting logind daemon/a Exec "Starting policy daemon..."          Polkit Start' "$bootup"
    say "BootUp: polkitd wired after elogind (${bootup#$TREE/})"
fi
# polkitd drops to polkitd (uid 999); ensure that user exists (section 3 only
# creates sddm + live). Match the base ISO's polkitd uid for rules ownership.
if ! grep -q '^polkitd:' "$TREE/etc/passwd"; then
    echo 'polkitd:x:999:999:Polkit Daemon:/:/bin/false' >> "$TREE/etc/passwd"
    grep -q '^polkitd:' "$TREE/etc/group" || echo 'polkitd:x:999:' >> "$TREE/etc/group"
    say "created polkitd user 999:999"
fi
say "polkitd task + StartLiveCD/BootUp wiring installed ($POLKIT_VER)"

# --- 50) XDG user directories (Desktop/Documents/Downloads/...) -------------
# The live user's $HOME and the skel have ONLY .files + Desktop, so Plasma's
# file dialogs and user-manager show no Documents/Downloads/Pictures/Music.
# Pre-create the XDG dirs in both the skel and the live user so they exist
# before first login (xdg-user-dirs is not on the ISO; Plasma expects them).
xdg_dirs="Desktop Documents Downloads Music Pictures Projects Videos"
skel_dir="$TREE/Programs/EnhancedSkel/Current/Resources/Defaults/Settings/skel"
[ -d "$skel_dir" ] && {
    for d in $xdg_dirs; do
        [ -d "$skel_dir/$d" ] || { mkdir -p "$skel_dir/$d"; say "skel: created $d"; }
    done
}
for d in $xdg_dirs; do
    [ -d "$TREE/Users/live/$d" ] || { mkdir -p "$TREE/Users/live/$d"; say "live: created $d"; }
done
chown 1000:1000 "$TREE/Users/live" "$TREE/Users/live/"* 2>/dev/null || true
say "XDG user dirs provisioned in skel + /Users/live"

# --- 51) Repair stale /System/Tasks symlinks (host-path leftovers) ----------
# Section 41's guard `[ -e ] || [ -L ] ||` SKIPS when ANY symlink exists, so
# stale links that point at the build-host path (/Mount/gobo-build/...) survive
# forever and the real Gobo task never runs on the booted ISO. Re-point them at
# the corresponding /Programs/... task by stripping the host-path prefix.
for link in "$TREE"/System/Tasks/*; do
    [ -L "$link" ] || continue
    tgt="$(readlink "$link")"
    case "$tgt" in
    "/Mount/gobo-build/work/rootfs/"*)
        clean="${tgt#/Mount/gobo-build/work/rootfs}"
        case "$clean" in /Programs/*) rel="${clean#/Programs/}"; esac
        if [ -n "${rel:-}" ] && [ -e "$TREE/Programs/$rel" ]; then
            rm -f "$link"
            ln -s "/Programs/$rel" "$link"
            say "repairing $(basename "$link") task symlink: $tgt -> /Programs/$rel"
        else
            say "WARNING: stale $(basename "$link") task target not resolvable in tree: $tgt"
        fi
        ;;
    esac
done

say "== done with $TREE"
