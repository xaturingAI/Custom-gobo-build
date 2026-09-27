#!/bin/bash
# Sets up the GoboLinux chroot bind mounts and runs the build inside it.
# Usage (as root):  sudo ./run-build.sh [step] [args]
# Steps: proton sync linux nvidia glibc32 fs lib32 cmake seatd tools wayland swayextras vulkan steam winetools mingw winedev protonplus lutris ffxiv music nodejs go odin fastfetch network pipewire pycompat pyxml core elogind_base flatpak sddm extras webkit appimage pantheon plasma merge livefix pkg pkgkeep all detach
#   e.g. sudo ./run-build.sh pkg LibCanberra 0.30
#   'nvidia' verifies the 5 kernel modules under
#   /Programs/Linux/Current/lib/modules/7.1.5/.../drivers/video; if the tarball
#   exists but the modules are missing it deletes the tarball and rebuilds.
#   The package now SHIPS the runtime enablement (packaged unmanaged files):
#   /etc/modprobe.d/nvidia.conf (nouveau blacklist + nvidia-drm modeset=1),
#   the udev PCI 0x10de rule that auto-loads the driver stack at boot on real
#   NVIDIA hardware, and /usr/share/X11/xorg.conf.d/10-nvidia.conf (Xorg
#   OutputClass -> nvidia DDX for full nvidia-settings under plasmax11).
#   'glibc32' builds the minimal 32-bit base (glibc/libgcc/libstdc++).
#   'lib32' builds all 32-bit gaming libraries (X11, GL, audio, SDL2, etc.)
#     that the Steam client and Wine/Proton need. Run AFTER glibc32.
#     Packages built: Lib32-X11 Lib32-Xext Lib32-Xrandr Lib32-Xinerama
#     Lib32-Xcursor Lib32-Xi Lib32-Xcomposite Lib32-Xdamage Lib32-Xss
#     Lib32-Xfixes Lib32-Xtst Lib32-DBus Lib32-FreeType Lib32-Fontconfig
#     Lib32-libpng Lib32-zlib Lib32-libxml2 Lib32-expat Lib32-libxcb
#     Lib32-libgcc Lib32-libstdcpp Lib32-alsa-lib Lib32-libpulse
#     Lib32-libsndfile Lib32-xkbcommon Lib32-libglvnd Lib32-mesa
#     Lib32-vulkan-loader Lib32-SDL2
#   'seatd' rebuilds just SeatD 0.6.4 (recipe pre_build patches the
#   /dev/dri + /dev/input realpath-prefix checks for GoboLinux symlinks).
#   'merge' now auto-runs step_livefix (apply-live-fixes.sh) afterwards.
#     All compiled packages in $GB/Packages/ (including Lib32-*) are merged
#     into the ISO rootfs — no explicit package list needed. step_livefix
#     re-applies all runtime fixes to work/rootfs, INCLUDING the NVIDIA
#     enablement (modprobe.conf, udev PCI auto-load, Xorg OutputClass).
#     'merge' FIRST rebuilds the ISO runtime fixes (ensure_livefix_builds) so
#     they are baked in: the 64-bit Glibc 2.44-2 upgrade (base ISO ships 2.30;
#     FastFetch + ProtonPlus's bundled GTK4 need up to GLIBC_2.44) and the
#     ProtonPlus 0.6.8 repack (its first tarball shipped an empty
#     lib/protonplus). The whole flow is then: glibc -> protonplus -> merge
#     -> livefix, and finalize-iso.sh produces an ISO where both app bugs are
#     fixed at runtime.
#   'core' builds the shared desktop-agnostic foundation (GLib/GI two-pass,
#     gdk-pixbuf/json-glib, elogind seat/session base, the whole Flatpak
#     chain: duktape/seccomp/polkit/appstream/vala/bubblewrap/gpgme/libostree/
#     dbus-proxy/flatpak). Used by flatpak, sddm and pantheon alike.
#   'elogind_base' builds just the elogind foundation (Linux-PAM headers
#     symlink + Linux-Headers 7.1.5 + Elogind 257.16 + BootUp wiring).
#   'flatpak' builds ONLY the shared core -> reaches a working `flatpak`
#     CLI + runtime with no Pantheon/GUI package on the index.
#   'sddm' builds the SDDM 0.20.0 Wayland display manager standalone
#     (elogind base + extra-cmake-modules + SDDM; needs 'wayland' + weston at
#     runtime; Qt 5.15.2 migration must already be in place).
#   'extras' builds Discord + VLC 3.0.21 (Qt 5.15.2 interface; ECM/SDDM moved
#     to 'sddm', Bubblewrap to 'core') — no longer a desktop prerequisite.
#   'lutris' builds Lutris 0.5.22 and ONLY the packages Lutris needs at
#     runtime: WebKitGTK with introspection (account-login WebViews), Xrandr
#     (resolution queries), Mesa-Utils (glxinfo) and P7zip (7z). The step
#     pre-checks them and builds just what is missing; once all five tarballs
#     exist it prints SKIP. NOTE: the 'lutris' step NEVER builds the Sway/
#     wayland desktop -- Sway compiles inside the 'wayland' step, which only
#     runs when a desktop component (wayland/swayextras/pantheon/plasma) is
#     selected in the menu or via --flags. Use --lutris (a selectable
#     component that pulls only winedev + webkit, no sway) for a gaming-only
#     Lutris build. '--gaming' still includes the Lutris pile too.
#   'ffxiv' builds the FFXIVQuickLauncher (XIVLauncher) 7.0.20 Windows/Squirrel
#     launcher (official nupkg) packaged for Wine, with a bin/xivlauncher wrapper
#     + menu entry. Depends on the wine stack; 'winedev' must run first (or the
#     recipe's Resources/Dependencies pulls Wine/Wine-Lutris-GE + DXVK + Vkd3d +
#     P7zip automatically). Single-game optional component, separate from 'gaming'.
#   'music' builds the LMMS 1.3.0-alpha.2 DAW (optional component, off by
#     default in the interactive menu). Build deps are Qt5 (5.15.2 migration),
#     FFTW3F and libsndfile -- all present on the base ISO, so the step only
#     compiles+packages LMMS (and publishes the Qt 5.15.2 tarball).
#   'nodejs' builds Node.js 24.21.0 (Krypton LTS) with the bundled npm/npx/
#     corepack CLIs (official prebuilt linux-x64 tarball, self-contained; bin/
#     stays a sibling of lib/ so the npm -> ../lib/node_modules symlinks work).
#   'go' builds Go 1.27.1 (official linux-amd64 tarball: go + gofmt + stdlib
#     toolchain, GOROOT auto-derived from the binary's location).
#   'odin' builds the Odin dev-2026-09 compiler (official linux-amd64 nightly
#     release; fully static single binary with base/core/shared/vendor shipped
#     beside it under the program root -- ODIN_ROOT is auto-detected from
#     /proc/self/exe -- linked at runtime by the ISO's cc/ld).
#     All three are offered together in the interactive menu as the
#     'programming' component (default off; --programming, or individual
#     steps nodejs/go/odin). Their packages bake into the ISO via 'merge' like
#     any other component.
#   'pipewire' builds the full system-wide audio stack: ALSA-Lib 1.2.13 (a
#     mandatory bump -- PipeWire 1.4.0 hard-requires alsa >= 1.2.10 and the
#     base ISO ships 1.2.2; libasound.so.2 is ABI-stable so existing consumers
#     are unaffected), then PipeWire 1.4.0 (daemon, pipewire-pulse
#     PulseAudio-compat server, pipewire-alsa plugin) and finally WirePlumber
#     0.5.17 (session manager, statically bundled Lua). Compiles the three
#     named recipes (Recipes/ALSA-Lib, Recipes/PipeWire, Recipes/WirePlumber).
#     The recipes ship Gobo init Tasks (Resources/Tasks -> /System/Tasks via
#     SymlinkProgram); after 'merge' apply-live-fixes.sh section 40 wires the
#     PipeWire task into BootUp/StartLiveCD, exports PIPEWIRE_RUNTIME_DIR +
#     PULSE_SERVER via /etc/environment, and disables the old PulseAudio
#     autostart/D-Bus-activation paths so pulse clients reach pipewire-pulse.
#     Standalone `./run-build.sh pipewire` only produces the packages; run
#     'merge' afterwards to bake the runtime wiring into the ISO.
#   'network' builds the boot-time network tooling the LiveCD session needs
#     once GoboNet (the Gobo-native wpa_supplicant + dhcpcd manager) is wired
#     in by apply-live-fixes.sh section 41: iw (nl80211 WiFi CLI, needs the
#     libnl-3 the base ISO already ships), ethtool (wired-NIC diagnostics,
#     built --enable-netlink=no since libmnl is NOT on the ISO), usb_modeswitch
#     (4G/5G stick CD-ROM->modem switch; libusb is on the ISO),
#     Libmbim/Libqmi (ModemManager's MBIM/QMI backends, glib-only) and a
#     ModemManager 1.24.2 REBUILD with -Dqmi=true -Dmbim=true (the base ISO
#     shipped qmi+mbim=false, so most sticks were invisible to it), plus BIND
#     9.18's dig/host/nslookup DNS client tools. Seven recipes: Recipes/IW,
#     Ethtool, USB-Modeswitch, Libmbim, Libqmi, ModemManager, Bind. Runtime
#     wiring is apply-live-fixes section 41 (rfkill unblock, GoboNet auto-
#     connect Network task, ModemManager + Bluetooth Start into BootUp/
#     StartLiveCD) applied at 'merge'; a bare `run-build.sh network` only
#     produces the packages.
#   'plasma' builds the KDE Plasma 6.7 desktop stack (Qt 6.10 + KF 6.26 +
#     Plasma 6.7 + Gear 26.08) from the single flat Recipes/Plasma6-core/ dir.
#     Needs the 'wayland' + 'sddm' steps at runtime (qt6/kwin wayland, elogind
#     seat/session) and step_core/step_cmake (toolchain). systemd-free.
#     Per-phase: --plasma runs all four phases; individual recipes can be done
#     first via `pkg <Program> <Version>` (e.g. pkg qtbase 6.10.3).
#   'webkit' builds WebKit2GTK 2.46.5 (GTK3 API 4.1, introspection ON) for the
#     Gaming/Lutris web engine (service-login WebView dialogs). Self-contained:
#     pulls step_core + the webkit tier (HarfBuzz-ICU, font stack, GTK+ 3.24.43,
#     libsoup3, GStreamer, Ruby/Unifdef/LibHyphen) from Recipes/Pantheon + the
#     canonical introspection recipe from Recipes/WebKit. `gaming` now pulls
#     `webkit` as a dependency, so selecting gaming builds it automatically.
#     Runtime HTTPS needs glib-networking (checked at the end of the step).
#   'appimage' builds the AppImage tools (AppImageKit 13 appimagetool + the
#     libappimage 1.0.0 C++ library with create/inspect/integrate). Running
#     AppImages already works on the ISO via FUSE -- this is for WRITING and
#     integrating them. libappimage 1.0.0 now builds clean (03 patches handled
#     a GCC-14 include, the dead Bintray boost URL, and a missing <cstdint>);
#     both packages are in $GB/Packages/.
#   'fs' builds XFS + OpenZFS: LibInih (inih r62) + LibURCU (userspace-rcu
#     0.15.1) build-time-only deps first -- XFSProgs 7.1.1's configure probes
#     for ini.h/urcu unconditionally even with scrub off, though the tools never
#     link them -- then XFSProgs 7.1.1 (mkfs.xfs/xfs_repair; the XFS kernel
#     driver is already in the 7.1.5 kernel as CONFIG_XFS_FS=m) and
#     OpenZFS 2.4.4 (zpool/zfs/zfsd + kernel modules compiled against the exact
#     Linux installed on the build system, like 'nvidia'). Run AFTER 'linux';
#     needs autoconf/automake/libtool for OpenZFS's autogen.sh.
#   'livefix' FIRST (re)builds and packages the GnuPG 2.4.9 dependency chain
#   (LibGCrypt 1.11.3 + Libksba 1.6.8, then GnuPG itself) via ensure_gpg_chain
#   in build.sh -- the base ISO ships libgcrypt 1.8.5 and no libksba, so GnuPG
#   configure aborts without them. It then rebuilds the two ISO runtime fixes
#   (ensure_livefix_builds): (a) Glibc 2.44-2, the ISO's 64-bit libc upgrade
#   from the 2.30 the base ISO ships -- FastFetch's official build needs
#   GLIBC_2.34 and ProtonPlus's bundled GTK4/Adwaita need up to GLIBC_2.44, and
#   the old libc was why BOTH failed on the booted ISO -- and (b) a ProtonPlus
#   0.6.8 repack: the first build's --appimage-extract silently produced an
#   empty lib/protonplus in the chroot (wrapper died "AppRun: No such file or
#   directory"), now self-extracted under glibc 2.44 with a baked AppDir
#   fallback. Finally it re-applies apply-live-fixes.sh to work/rootfs without
#   a merge, and re-asserts root ownership after its own chown hand-back (see
#   below).
#   A bare `run-build.sh livefix` is now equivalent to `merge`: it rebuilds the
#   gpg chain + glibc + ProtonPlus, then re-runs step_merge so those packages
#   AND the apply-live-fixes.sh rewrites land in a freshly-refreshed
#   work/rootfs in one command.
#   NOTE: the glibc upgrade + ProtonPlus repack only reach the ISO when the
#   packages are merged AFTER them -- that is why a bare `run-build.sh livefix`
#   now ends by re-running the merge (step_merge) automatically, so the fixes
#   are baked into work/rootfs in the same command; `merge` alone does the same
#   since it auto-runs these builds first. finalize-iso.sh then produces an ISO
#   where both app run failures are fixed.
#   Fully idempotent and safe to run repeatedly. What it covers, by section:
#     1-2    SDDM greeter Qt: qt.conf beside sddm-greeter + SddmComponents QML
#            module onto the Qt import path
#     3-5    users/groups, /etc/shells (pam_shells requirement), PAM
#            system-login + system-local-login stacks
#     6-6b   REAL sddm.conf (autologin live user, seatd env) + greeter/compositor
#            log wrapper + udev input-group rule + weston cursor theme +
#            inittab tty1 -> sddm (drop the console on tty1)
#     8-9    GdkPixbuf loader dir curation + librsvg preload in Xsession (gala
#            double-registration guard)
#     10     python3 symlink
#     11-12b boot tasks (sshd/seatd/elogind tasks) + BootUp wiring that starts
#            dhcpcd for auto networking at boot + resolv.conf nameservers
#            (QEMU user-mode DNS 10.0.2.3 + 1.1.1.1) + boot debug readback
#     13-13f dbus launch helper at FHS paths + Mutter/Gala/Pantheon library and
#            session fixes + libgsd.so + D-Bus session bus for SDDM + elogind/
#            polkit bus-name policies + VT1 console rule (no agetty under DM)
#     14-14e lib32 symlink farm + ld.so.conf registration + missing .desktop/
#            icons for Discord/Ren'Py/XIVLauncher/Heroic/NVIDIA + an
#            'Install GoboLinux' entry for the 'live' session user + NVIDIA
#            runtime enablement (/etc/modprobe.d/nvidia.conf + udev PCI 0x10de
#            auto-load rule + Xorg OutputClass) + desktop db update + Vulkan
#            ICD registration + portal/libinput fixes
#     15-15c sshd setup + passwordless sudo + polkit for the live user +
#            setuid-root sweep: sudo/pkexec/polkitd/unix_chkpwd/dbus helper
#     16-19  Wingpanel autostart + Polkit agent autostart + Wayland session
#            target + GLVND EGL vendor files (/usr/share, authoritative)
#     30-31.6 Plasma6/KF6 Qt6 runtime search path - integration + Plasma session
#            glue (single-token Exec, Xwayland dir, swrast GL) + Qt6 modular
#            plugin mirror + python3.11 merged site-packages on sys.path
#     32     OpenSSH live bootstrap: boot task `-t rsa1` -> ed25519 host key,
#            pre-baked root-owned host keys (fixes "unknown key type rsa1" and
#            "no hostkeys specified" / kex-reset sshd deaths)
#     33     Non-interactive live boot (fixes "login prompt never appears")
#     34     Core GLib-family typelibs (Gio/GLib/GObject/GModule) restored into
#            the active GObject-Introspection so `gi.repository.Gio` imports
#            (Lutris requirement)
#     35     XIVLauncher (FFXIVQuickLauncher): pre-create the WINEPREFIX before
#            wineboot (wine chdir fix for first launch). Scans
#            Programs/FFXIVQuickLauncher/*/bin/xivlauncher
#     36     Lutris data path: lib/lutris/share -> Program share so its
#            datapath resolves (fixes "data_path can't be found at
#            lib/lutris/share/lutris")
#     37     VLC: qt.conf beside the binary so its Qt GUI finds the xcb
#            platform plugin ("Could not find the Qt platform plugin 'xcb'")
#   Post-chown (in build.sh step_livefix, after the tree is handed back to the
#   repo owner): root:root + setuid 4755 on sudo/pkexec/unix_chkpwd/dbus
#   helper/polkit-agent-helper-1 + sudo plug-ins; Sudo/Settings/sudoers root
#   root:root 0440 ("sudoers is owned by uid 1000"); /var/empty root:root 0755
#   (sshd privsep sandbox); OpenSSH host keys 600/644. Files written during
#   the fixes are chowned to the repo owner too.
#   'detach' unmounts the chroot binds again (safe to run anytime).
#
# === Full gaming ISO build sequence ===
#   sudo ./run-build.sh sync
#   sudo ./run-build.sh linux
#   sudo ./run-build.sh nvidia
#   sudo ./run-build.sh nvdiag
#   sudo ./run-build.sh glibc32
#   sudo ./run-build.sh lib32
#   sudo ./run-build.sh cmake
#   sudo ./run-build.sh wayland
#   sudo ./run-build.sh vulkan
#   sudo ./run-build.sh steam
#   sudo ./run-build.sh winetools
#   sudo ./run-build.sh mingw
#   sudo ./run-build.sh winedev
#   sudo ./run-build.sh protonplus # optional: ProtonPlus 0.6.8 (gaming manager)
#   sudo ./run-build.sh ffxiv    # optional: XIVLauncher 7.0.20 under Wine
#   sudo ./run-build.sh music    # optional: LMMS 1.3.0-alpha.2 DAW
#   sudo ./run-build.sh pycompat
#   sudo ./run-build.sh pyxml
#   sudo ./run-build.sh core     # shared foundation
#   sudo ./run-build.sh flatpak  # working flatpak CLI
#   sudo ./run-build.sh sddm     # SDDM 0.20.0 greeter
#   sudo ./run-build.sh extras   # Discord only
#   sudo ./run-build.sh fastfetch # optional: FastFetch system-info tool
#   sudo ./run-build.sh webkit   # WebKitGTK 4.1 (Lutris web connect)
#   sudo ./run-build.sh pantheon
#   sudo ./run-build.sh plasma   # Plasma 6.7 desktop
#   sudo ./run-build.sh merge
#   # then on the host:  ./finalize-iso.sh
#
#   Or all-in-one:  sudo ./run-build.sh all
set -e

# Self-locate so the scripts work for any user/layout. The canonical recipe
# source (BuildLiveCD) is expected next to this repo; override with REPO=.
GB=$(cd "$(dirname "$0")" && pwd)
ROOT="$GB/rootfs"
REPO="${REPO:-$(dirname "$GB")/Projects/BuildLiveCD}"

[ -d "$ROOT" ] || { echo "rootfs not found at $ROOT"; exit 1; }

if [ "$1" = "detach" ]; then
    if mountpoint -q "$ROOT/System/Kernel/Devices"; then
        echo "--> Unmounting chroot bind mounts under $ROOT"
        umount -R "$ROOT" || umount -l -R "$ROOT"
        echo "== chroot detached"
    else
        echo "== nothing mounted; nothing to do"
    fi
    exit 0
fi

# Bind host trees into the chroot, then IMMEDIATELY cut mount propagation.
# systemd marks every mount 'shared'; a plain --rbind makes this chroot a peer
# of the host mounts, so anything mounted INSIDE the chroot (loop images,
# devpts instances, ...) propagates BACK onto the host. That is what shadowed
# the host's /dev/pts during long merges and broke sudo for every user with
# "sudo: unable to allocate pty: No such device". Private mounts stay one-way.
bind_rprivate() { # <src> <dst>
    mountpoint -q "$2" || mount --rbind "$1" "$2"
    mount --make-rprivate "$2"
}
bind_private() { # <src> <dst>
    mountpoint -q "$2" || mount --bind "$1" "$2"
    mount --make-private "$2"
}

mkdir -p "$ROOT"/{proc,sys,dev,dev/pts,mnt/gobo-build,mnt/repo}

bind_rprivate /proc "$ROOT/proc"
bind_rprivate /sys  "$ROOT/sys"
bind_rprivate /dev  "$ROOT/dev"
bind_rprivate /dev/pts "$ROOT/dev/pts"

# gobo-build must be private too: rootfs lives INSIDE gobo-build, so a shared
# bind here would re-import every mount we just made under rootfs/ and stack
# nested copies (Mount/gobo-build/rootfs/Mount/repo) on every run.
bind_private "$GB" "$ROOT/mnt/gobo-build"
bind_private "$REPO" "$ROOT/mnt/repo" || { echo "recipes repo not found at $REPO (override with REPO=)"; exit 1; }

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

echo "== chroot ready; running build.sh $*"
exec chroot "$ROOT" /bin/bash /mnt/gobo-build/build.sh "$@"
