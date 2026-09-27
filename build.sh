#!/bin/bash
# Full game-package + LiveCD merge build, run INSIDE the GoboLinux chroot.
# Usage: /mnt/gobo-build/build.sh [options]
#        (no args)          -> interactive component menu (selections saved)
#        'menu'             -> same interactive component menu
#        --component flags  -> non-interactive build of the selected
#                              components (--lib32 --wayland --vulkan --gaming
#                              --extras --pantheon --plasma --iso --all --list)
#        'all'              -> the full build (kernel -> merge -> livefix)
#        '<step>'           -> run one predefined step (see list below)
#        'pkg <prog> <ver>' -> single compile+package (mirrors old /tmp helpers)
#        'pkgkeep ..'       -> single compile+package in-place (--keep)
# Steps: proton sync linux nvidia glibc32 lib32 cmake seatd tools wayland swayextras vulkan steam winetools mingw winedev protonplus lutris ffxiv fastfetch pycompat pyxml aliens core elogind_base flatpak sddm extras network pipewire pantheon merge livefix test pkg pkgkeep all

export TERM=xterm
export HOME=/Users/root
export LANG=C
export LC_ALL=C
set -o pipefail

source /System/Index/bin/GoboPath
export PATH="$goboExecutables:/System/Index/bin:/bin:/sbin:/usr/bin:/usr/sbin:$PATH"

# Compile/ColorMake invoke plain `make` with no -j, so WebKit builds ran one
# file at a time. GNU make reads MAKEFLAGS from the environment, so exporting
# it here parallelizes every recursive make (JSC/WebCore/WTF/bmalloc) too.
export MAKEFLAGS="-j$(nproc)"

# Alien-PIP installs Python modules into /System/Aliens/PIP/$ver/lib/python3.x/site-packages
# but never adds that dir to the interpreter's search path (its header documents that
# PYTHONPATH or a .pth must do it). The reference build env exported PYTHONPATH; our bare
# chroot bash does not, so meson (mesonbuild) and other pip tools would fail to import.
#
# python3 is now the 3.11 main interpreter (Python 3.11.12 recipe flips the index
# symlink), but Gobo's Scripts python modules (PythonUtils, GuessProgramCase, UseFlags,
# Alien, ...) still live in the 3.8 site-packages. Without them UseFlags/CheckDependencies
# (and therefore Compile) crash with "ModuleNotFoundError: No module named 'PythonUtils'".
# Keep the 3.8 site-packages on the path for the whole build. The BOOTED ISO gets the same
# coverage via a .pth shipped by the Python package (see step_pycompat).
pyver=$(python3 --version 2>/dev/null | awk '{print $2}' | cut -d. -f1-2)
# The 3.11 interpreter's own site-packages MUST come first: it ships a modern
# setuptools (65.5.0) whose install_scripts handles the bdist_wininst command
# removal in Python 3.11 (try/except). The 3.8 site-packages on PYTHONPATH
# otherwise shadows it with setuptools 41.2.0, whose install_scripts hard-calls
# bdist_wininst -> "No module named 'distutils.command.bdist_wininst'" on any
# `python3.11 setup.py install` (Lutris 0.5.22, Protontricks rebuild).
export PYTHONPATH="/System/Index/lib/python${pyver}/site-packages:/System/Aliens/PIP/$pyver/lib/python${pyver}/site-packages:/System/Index/lib/python3.8/site-packages${PYTHONPATH:+:$PYTHONPATH}"

B=/mnt/gobo-build
log() { echo "[$(date +%H:%M:%S)] $*"; }

mkdir -p /Users/root/.local /Users/root/.cache
mkdir -p /Data/Compile/{Archives,Sources,Recipes,Packages}
mkdir -p "$B"/{logs,Packages,work}
cd /Data/Compile
[ -d Recipes/.git ] || git init -q Recipes

# Refresh the CA bundle so HTTPS downloads trust modern roots (e.g. KDE's
# download.kde.org chain). The fresh bundle is fetched on the HOST into the
# bind-mounted dir to avoid the chroot's trust-bootstrapping problem.
if [ -f "$B/cacert.pem" ]
then cp "$B/cacert.pem" /etc/ssl/certs/ca-certificates.crt
     log "CA bundle refreshed from $B/cacert.pem"
fi

# Qt is built with -prefix /usr, so its CMake configs hardcode /usr paths.
# Gobo's /usr only symlinks bin/include/lib{,64}/libexec into the index;
# mkspecs/qml/translations were never created and /usr/plugins only holds an
# empty legacy webkit dir. find_package(Qt5) FATAL_ERRORs when any hardcoded
# file is missing (SDDM hit /usr/mkspecs and /usr/plugins/...). Provide them.
# Version resolved dynamically via Programs/Qt/Current so this stays correct
# after the Qt 5.14.1 -> 5.15.2 migration (see QT5.15-MIGRATION.md).
QT_ACTIVE=$(basename "$(readlink /Programs/Qt/Current 2>/dev/null || echo 5.14.1)")
if [ ! -e /usr/mkspecs ]; then ln -s "/Programs/Qt/$QT_ACTIVE/mkspecs" /usr/mkspecs; fi
if [ ! -e /usr/qml ]; then ln -s "/Programs/Qt/$QT_ACTIVE/qml" /usr/qml; fi
if [ ! -e /usr/translations ]; then ln -s "/Programs/Qt/$QT_ACTIVE/translations" /usr/translations; fi
for p in "/Programs/Qt/$QT_ACTIVE"/plugins/*; do
    [ -e "/usr/plugins/$(basename "$p")" ] || ln -s "$p" "/usr/plugins/$(basename "$p")"
done
log "Qt5 /usr prefix links ensured (Qt $QT_ACTIVE: mkspecs/qml/translations/plugins)"

STEP="${1:-menu}"

step_proton() {
    local dst="/mnt/repo/Recipes/Gaming/Steam/1.0.0.87_bin/Resources/Unmanaged/Users/root/.local/share/Steam/compatibilitytools.d/GE-Proton11-3"
    if [ -d "$dst" ]
    then log "GE-Proton11-3 already baked; skipping AddProton"
    else
        log "Fetching GE-Proton11-3"
        /mnt/repo/bin/AddProton -v GE-Proton11-3
    fi
}

# Ship the Alien-NPM and Alien-Cargo plugins on the live ISO.
#
# The final ISO is assembled by the 'merge' step: refresh-merge.py extracts the
# base ISO into $B/work/rootfs and merges the binary packages, and finalize-iso.sh
# turns that merged tree into the squashfs. So the plugins MUST be written into
# $B/work/rootfs — the chroot's live /System is only the build environment and is
# never part of the ISO. The merge step wipes $B/work first, so this step must
# run AFTER 'merge'.
#
# The base ISO ships the Alien dispatcher with plugins for cabal/cpan/ctan/
# luarocks/pip/pip3/rubygems but not npm or cargo. We add the two plugins as real
# files under Programs/Scripts/017-GIT/bin/ and wire them into /System/Index/bin/
# with symlinks in the same style as the base ISO's other Alien-* entries.
#
# They are plain shell scripts with no runtime deps — the managers they drive
# (npm, cargo/go and their toolchains, git for odin) are shipped via the
# Packages tarballs (NodeJS, Go, Odin, Rust), so a booted Live CD user can
# invoke them directly.
step_aliens() {
    local merged_root="$B/work/rootfs"
    if [ ! -d "$merged_root" ]
    then
        log "WARN: $merged_root missing - run 'merge' first (aliens writes into the merged tree)"
        return 1
    fi
    local repo_bin="/mnt/repo/bin"
    local scripts_bin="$merged_root/Programs/Scripts/017-GIT/bin"
    local idx_bin="$merged_root/System/Index/bin"
    local aliens_root="$merged_root/System/Aliens"
    mkdir -p "$scripts_bin" "$idx_bin"
    # Pre-create the language install roots AND their inner scaffolding so
    # /System/Aliens shows the same shape as the base ISO's CPAN/PIP/LuaRocks
    # trees even before the first `Alien --install` runs. Plugin installs land
    # in these paths: npm -> <pkg>/ prefixes, cargo/go -> bin/, odin -> <repo>/.
    mkdir -p "$aliens_root/NPM"
    mkdir -p "$aliens_root/Cargo/bin"
    mkdir -p "$aliens_root/Go/bin"
    mkdir -p "$aliens_root/Odin"
    log "Pre-created /System/Aliens/{NPM,Cargo/bin,Go/bin,Odin} scaffolds in merged root"
    local installed=0
    for plugin in Alien-NPM Alien-Cargo Alien-Go Alien-Odin
    do
        if [ ! -f "$repo_bin/$plugin" ]
        then
            log "WARN: $repo_bin/$plugin missing; skipping"
            continue
        fi
        install -m 0755 "$repo_bin/$plugin" "$scripts_bin/$plugin"
        rm -f "$idx_bin/$plugin"
        ln -s "/Programs/Scripts/017-GIT/bin/$plugin" "$idx_bin/$plugin"
        log "Installed $plugin into merged rootfs ($scripts_bin, linked from $idx_bin)"
        installed=$((installed+1))
    done
    [ "$installed" -gt 0 ] || log "WARN: no Alien plugins installed"
}

step_sync() {
    log "Syncing recipes from /mnt/repo into /Data/Compile/Recipes"
    for r in Linux Glibc Glibc-32 CMake Vulkan-Headers Vulkan-Loader Vulkan-Tools Nvidia \
             XKBcommon LibInput LibXKBfile LibXcvt LibDrm Scdoc LibDecor \
             Discord Extra-CMake-Modules SDDM \
             OpenSSL Python PyCairo PyGObject \
             Qt Qt5Wayland VLC \
             OpenCL-Headers Clinfo VDPAUInfo \
             Xrandr Mesa-Utils P7zip OpenAL FastFetch
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/$r" "Recipes/$r"
    done
    # Nvidia-Settings lives nested under Recipes/Nvidia/, but Compile resolves
    # it as a FLAT app name (Find_Recipe greps top-level dirs for ^Nvidia-Settings$),
    # so the flat copy must be refreshed from the nested one or the stale flat
    # recipe (recipe_type=configure) gets used and the pure-Makefile build fails.
    rm -rf "Recipes/Nvidia-Settings"
    cp -a "/mnt/repo/Recipes/Nvidia/Nvidia-Settings" "Recipes/Nvidia-Settings"
    # Gaming recipes (canonical source Recipes/Gaming/)
    for r in Steam Lutris Heroic Protontricks RenPy LMMS ProtonPlus
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Gaming/$r" "Recipes/$r"
    done
    # wayland-core recipes (canonical source Recipes/wayland-core/);  all
    # recipes listed here MUST also stay in step_wayland's compile order.
    for r in Wayland Wayland-Protocols EGLExternalPlatform EGL-Wayland SeatD \
             XorgProto Wlroots XWayland Wlr-Protocols Wlr-Randr Wayland-Utils
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/wayland-core/$r" "Recipes/$r"
    done
    # Sway-core recipes (canonical source Recipes/Sway-core/)
    for r in Sway SwayBg SwayIdle SwayLock
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Sway-core/$r" "Recipes/$r"
    done
    # wine-Core recipes (canonical source Recipes/wine-Core/);  Wine-Source is
    # documented/not built, so it is exempt from the sync loop like before.
    for r in Wine Wine-Lutris-GE DXVK Vkd3d-Proton Mingw-w64 Winetricks
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/wine-Core/$r" "Recipes/$r"
    done
    # 32-bit library recipes (Wine/Steam dependency layer) in Recipes/32-Bit-Libs/
    for r in Lib32-X11 Lib32-Xext Lib32-Xrandr Lib32-Xinerama Lib32-Xcursor Lib32-Xi \
             Lib32-Xcomposite Lib32-Xdamage Lib32-Xss Lib32-Xfixes Lib32-Xtst \
             Lib32-DBus Lib32-FreeType Lib32-Fontconfig Lib32-libpng Lib32-zlib \
             Lib32-libxml2 Lib32-expat Lib32-libxcb Lib32-alsa-lib Lib32-libpulse \
             Lib32-xkbcommon Lib32-libgcc Lib32-libstdcpp \
             Lib32-libglvnd Lib32-mesa Lib32-vulkan-loader Lib32-libsndfile Lib32-SDL2 \
             Lib32-glib Lib32-gnutls Lib32-openssl Lib32-sqlite Lib32-gdk-pixbuf Lib32-pango \
             Lib32-libjpeg Lib32-harfbuzz Lib32-fribidi Lib32-libxft \
             Lib32-gstreamer Lib32-gst-plugins-base Lib32-libtiff Lib32-mpg123 Lib32-libv4l \
             Lib32-xxf86vm Lib32-xrender Lib32-xshmfence \
             Lib32-openal Lib32-libva Lib32-gsm Lib32-theora Lib32-vorbis Lib32-libogg \
             Lib32-curl Lib32-drm Lib32-gpg Lib32-gtk Lib32-idn Lib32-krb5 Lib32-ssh \
             Lib32-libffi Lib32-PCRE2 Lib32-libmount Lib32-libblkid Lib32-libselinux \
             Lib32-libcap Lib32-libdatrie Lib32-libthai Lib32-libsystemd Lib32-graphite2 \
             Lib32-brotli
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/32-Bit-Libs/$r" "Recipes/$r"
    done
    # PipeWire system-wide audio stack recipes (Recipes/ALSA-Lib/1.2.13,
    # Recipes/PipeWire/1.4.0 and Recipes/WirePlumber/0.5.17); ALSA-Lib must
    # land before PipeWire (meson needs alsa >= 1.2.10) and PipeWire before
    # WirePlumber (meson needs libpipewire-0.3.pc) in step_pipewire.
    for r in ALSA-Lib PipeWire WirePlumber
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/$r" "Recipes/$r"
    done
    # SDL 2.30.2 (top-level Recipes/SDL/): replaces the base ISO's prebuilt SDL
    # 2.0.12, whose cmake config reports 2.0.12 and so trips the
    # `find_package(SDL2 2.0.16)` gate that lets plasma-desktop build its Game
    # Controller KCM (kcms/gamecontroller is only added when TARGET SDL2::SDL2
    # exists). Must be installed BEFORE Plasma-Desktop 6.7.4 in step_plasma.
    for r in SDL
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/$r" "Recipes/$r"
    done
    # Pantheon desktop recipes moved into Recipes/Pantheon/ (canonical source).
    # Pull each from there so the chroot always gets the Pantheon subdir.
    for r in GLib GObject-Introspection PCRE2 HarfBuzz Fribidi JSON-GLib Pango GdkPixbuf Graphene LCMS2 Libei \
             Libdisplay-Info GSettings-Desktop-Schemas Sysprof-Capture Libwacom LibEvdev LibPipewire \
             LibCanberra LibGudev GUsb IsoCodes Colord Gnome-Desktop GTK4 LibAdwaita LibX11 LibXfixes Mutter \
             Elogind LibGLVnd LLVM Mesa \
             FreeType Fontconfig Pixman Cairo HWData Linux-Headers
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r"
    done
    # Pantheon: session stack
    for r in LibNghttp2 Libsoup3 GweatherLocations Gcr3 GeocodeGlib Libgweather4 Geoclue \
             UPower GnomeKeyring GnomeSettingsDaemon GnomeSession DesktopFileUtils \
             SessionSettings Weston
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r"
    done
    # Pantheon: elementary libraries + themes
    for r in ElementaryIconTheme ElementaryWallpapers GtkThemeElementary SoundThemeElementary \
             Contractor Granite Granite7 Libgee Libhandy Vala \
             ATK GTK+ GStreamer Gst-Plugins-Base Gst-Plugins-Good Gst-LibAV VTE Gcr4 \
             Ruby LibHyphen Unifdef LibIcal WebKit2GTK WebKitGTK \
             Cogl Clutter ClutterGtk LibChamplain EvolutionDataServer Folks \
             GtkSourceView LibPeas LibGit2 LibGit2-Glib \
             Exiv2 GExiv2 LibGphoto2 LibRaw LibExif \
             LibJcat Fwupd PackageKit Jansson \
             CapnetAssist Gala LightdmPantheonGreeter Wingpanel Switchboard
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r"
    done
    # Pantheon: elementary apps
    for r in PantheonApplicationsMenu PantheonCalculator PantheonCalendar PantheonCamera \
             PantheonCode PantheonDefaultSettings PantheonFiles PantheonGeoclue2Agent \
             PantheonMail PantheonMusic PantheonNotifications PantheonOnboarding PantheonPhotos \
             PantheonPolkitAgent PantheonScreenshot PantheonSettingsDaemon PantheonShortcutOverlay \
             PantheonSideload PantheonTasks PantheonTerminal PantheonVideos PantheonWayland
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r"
    done
    # Pantheon: wingpanel indicators + switchboard plugs
    for r in WingpanelIndicatorA11y WingpanelIndicatorBluetooth WingpanelIndicatorDatetime \
             WingpanelIndicatorKeyboard WingpanelIndicatorNetwork WingpanelIndicatorNightlight \
             WingpanelIndicatorNotifications WingpanelIndicatorPower WingpanelIndicatorSession \
             WingpanelIndicatorSound \
             SwitchboardPlugAbout SwitchboardPlugApplications SwitchboardPlugBluetooth \
             SwitchboardPlugDatetime SwitchboardPlugDesktop SwitchboardPlugDisplay \
             SwitchboardPlugKeyboard SwitchboardPlugLocale SwitchboardPlugMouseTouchpad \
             SwitchboardPlugNetwork SwitchboardPlugNotifications \
             SwitchboardPlugParentalControls SwitchboardPlugPower \
             SwitchboardPlugSecurityPrivacy SwitchboardPlugSharing SwitchboardPlugSound \
             SwitchboardPlugWacom
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r"
    done
    # Pantheon: support libs for indicators/plugs (Aug 22 audit)
    for r in IBus Accountsservice LibGTop LibBlockDev UDisks2 Cups \
             Dock
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r"
    done
    # Core Flatpak stack (own top-level dir, sibling of Pantheon)
    for r in AppStream Bubblewrap Dconf Duktape Flatpak Gpgme LibGpg-Error \
             LibOstree LibPortal LibSeccomp LibXmlb LibYaml Polkit \
             XDG-DBus-Proxy XDG-Desktop-Portal XDG-Desktop-Portal-GTK
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Flatpak-Core/$r" "Recipes/$r"
    done
    # Phone/PGP tier (same Flatpak-Core dir): the recipes step_devices /
    # step_livefix compile must stay in sync with the repo -- the base ISO's
    # copies are stale (or, for LibGCrypt 1.11.3 + Libksba 1.6.8, absent).
    # GnuPG 2.4.9 configure requires libgcrypt >= 1.9.1 + libksba >= 1.6.3,
    # which is why the two new recipes are pulled here too.
    for r in Autoconf-Archive GnuPG Libmtp Libusb Simple-Mtpfs LibGCrypt Libksba
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/Flatpak-Core/$r" "Recipes/$r"
    done
    # Network stack recipes (Recipes/IW/, Recipes/Ethtool/, Recipes/USB-Modeswitch/,
    # Recipes/Libmbim/, Recipes/Libqmi/, Recipes/ModemManager/ and
    # Recipes/Bind/); all MUST stay in step_network's compile order.
    for r in IW Ethtool USB-Modeswitch Libmbim Libqmi ModemManager Bind
    do
        rm -rf "Recipes/$r"
        cp -a "/mnt/repo/Recipes/$r" "Recipes/$r"
    done
    # Plasma 6.7 desktop stack: ALL recipes (Qt6/KF6/Plasma6/Gear phases) live
    # in ONE flat dir Recipes/Plasma6-core/, so a single glob pulls every
    # recipe into the chroot. Mirrors the how the Pantheon loop works but from
    # a single flat source instead of tier subdirs. Each recipe pins its own
    # version; the four build phases are tracked as ORDER in step_plasma.
    for r in /mnt/repo/Recipes/Plasma6-core/*/
    do
        [ -d "$r" ] || continue
        p="$(basename "$r")"
        rm -rf "Recipes/$p"
        cp -a "$r" "Recipes/$p"
    done
    stage_archives
}

# Seed /Data/Compile/Archives with the host-staged tarballs so the webkit/EDS/
# code/photos/settingsdaemon tiers build offline. Compile names cached archives
# by URL basename, which for github refs-tag URLs differs from our staged names
# (e.g. url .../tags/v2.8.8.tar.gz -> v2.8.8.tar.gz, staged hyphen-2.8.8.tar.gz).
stage_archives() {
    mkdir -p /Data/Compile/Archives
    # unifdef: force-refresh the staged archive — the chroot previously got
    # the github tag archive (which lacks version.sh, breaking reversion.sh);
    # the recipe now uses the dotat.at release tarball under the same name.
    rm -f "/Data/Compile/Archives/unifdef-2.12.tar.gz"
    # url_basename staged_name
    while read -r dst src; do
        [ -z "$dst" ] && continue
        if [ -f "$B/$src" ] && [ ! -f "/Data/Compile/Archives/$dst" ]; then
            cp "$B/$src" "/Data/Compile/Archives/$dst"
            log "staged archive $dst <- $src"
        fi
    done <<'EOF'
v2.8.8.tar.gz hyphen-2.8.8.tar.gz
ruby-3.3.12.tar.gz ruby-3.3.12.tar.gz
unifdef-2.12.tar.gz unifdef-2.12.tar.gz
libical-3.0.19.tar.gz libical-3.0.19.tar.gz
webkitgtk-2.46.5.tar.xz webkitgtk-2.46.5.tar.xz
# webkit GTK3 tier deps (step_webkit); pre-stage when the build host has
# them cached so the offline chroot never re-downloads mid-build.
harfbuzz-11.4.0.tar.xz harfbuzz-11.4.0.tar.xz
fribidi-1.0.16.tar.xz fribidi-1.0.16.tar.xz
freetype-2.13.3.tar.xz freetype-2.13.3.tar.xz
fontconfig-2.15.0.tar.xz fontconfig-2.15.0.tar.xz
pixman-0.44.2.tar.gz pixman-0.44.2.tar.gz
cairo-1.18.4.tar.xz cairo-1.18.4.tar.xz
pango-1.56.1.tar.xz pango-1.56.1.tar.xz
lcms2-2.19.1.tar.gz lcms2-2.19.1.tar.gz
gtk+-3.24.43.tar.xz gtk+-3.24.43.tar.xz
nghttp2-1.70.0.tar.xz nghttp2-1.70.0.tar.xz
libsoup-3.6.6.tar.xz libsoup-3.6.6.tar.xz
gstreamer-1.26.1.tar.xz gstreamer-1.26.1.tar.xz
gst-plugins-base-1.26.1.tar.xz gst-plugins-base-1.26.1.tar.xz
cogl-1.22.8.tar.xz cogl-1.22.8.tar.xz
clutter-1.26.4.tar.xz clutter-1.26.4.tar.xz
clutter-gtk-1.8.4.tar.xz clutter-gtk-1.8.4.tar.xz
libchamplain-0.12.21.tar.xz libchamplain-0.12.21.tar.xz
evolution-data-server-3.54.3.tar.xz evolution-data-server-3.54.3.tar.xz
folks-0.15.9.tar.xz folks-0.15.9.tar.xz
gtksourceview-4.8.4.tar.xz gtksourceview-4.8.4.tar.xz
libpeas-2.0.4.tar.xz libpeas-2.0.4.tar.xz
v1.7.2.tar.gz libgit2-1.7.2.tar.gz
libgit2-glib-1.2.0.tar.xz libgit2-glib-1.2.0.tar.xz
v0.28.5.tar.gz exiv2-0.28.5.tar.gz
gexiv2-0.14.3.tar.xz gexiv2-0.14.3.tar.xz
libgphoto2-2.5.31.tar.xz libgphoto2-2.5.31.tar.xz
LibRaw-0.21.3.tar.gz LibRaw-0.21.3.tar.gz
libexif-0.6.24.tar.bz2 libexif-0.6.24.tar.bz2
0.2.3.tar.gz libjcat-0.2.3.tar.gz
1.9.27.tar.gz fwupd-1.9.27.tar.gz
v1.3.6.tar.gz PackageKit-1.3.6.tar.gz
v2.14.tar.gz jansson-2.14.tar.gz
atk-2.36.0.tar.xz atk-2.36.0.tar.xz
gst-plugins-good-1.26.1.tar.xz gst-plugins-good-1.26.1.tar.xz
gst-libav-1.26.1.tar.xz gst-libav-1.26.1.tar.xz
xdg-dbus-proxy-0.1.6.tar.xz xdg-dbus-proxy-0.1.6.tar.xz
dock-8.3.3.tar.gz dock-8.3.3.tar.gz
xdg-desktop-portal-1.22.1.tar.gz xdg-desktop-portal-1.22.1.tar.gz
xdg-desktop-portal-gtk-1.15.3.tar.gz xdg-desktop-portal-gtk-1.15.3.tar.gz
qtwayland-everywhere-src-5.14.1.tar.xz qtwayland-everywhere-src-5.14.1.tar.xz
qtbase-everywhere-src-5.14.1.tar.xz qtbase-everywhere-src-5.14.1.tar.xz
vlc-3.0.21.tar.xz vlc-3.0.21.tar.xz
swaybg-1.2.2.tar.gz swaybg-1.2.2.tar.gz
swaylock-1.8.6.tar.gz swaylock-1.8.6.tar.gz
swayidle-1.9.0.tar.gz swayidle-1.9.0.tar.gz
libdecor-0.2.2.tar.xz libdecor-0.2.2.tar.xz
v0.13.0.tar.gz qcoro-0.13.0.tar.gz
v1.9.tar.gz libndp-1.9.tar.gz
qqc2-desktop-style-6.26.0.tar.xz qqc2-desktop-style-6.26.0.tar.xz
kio-extras-26.08.0.tar.xz kio-extras-26.08.0.tar.xz
ksystemstats-6.7.4.tar.xz ksystemstats-6.7.4.tar.xz
ModemManager-1.24.2.tar.xz ModemManager-1.24.2.tar.xz
modemmanager-qt-6.26.0.tar.xz modemmanager-qt-6.26.0.tar.xz
mobile-broadband-provider-info-20240407.tar.gz mobile-broadband-provider-info-20240407.tar.gz
plasma-nm-6.7.4.tar.xz plasma-nm-6.7.4.tar.xz
0.16.0.tar.gz qtkeychain-0.16.0.tar.gz
# phone/PGP tier (step_devices / step_livefix): sources for GnuPG 2.4.9's
# hard configure deps -- LibGCrypt 1.11.3 (>= 1.9.1) and Libksba 1.6.8
# (>= 1.6.3). The base ISO ships only libgcrypt 1.8.5 and no libksba, so the
# GnuPG compile aborts without these staged.
libgcrypt-1.11.3.tar.bz2 libgcrypt-1.11.3.tar.bz2
libksba-1.6.8.tar.bz2 libksba-1.6.8.tar.bz2
# FS tier (step_fs): XFSProgs + OpenZFS + their build-only deps LibInih
# (github tag archive -> url basename r62.tar.gz) and LibURCU (lttng.org
# release tarball). All build fully offline once staged.
xfsprogs-7.1.1.tar.xz xfsprogs-7.1.1.tar.xz
zfs-2.4.4.tar.gz zfs-2.4.4.tar.gz
r62.tar.gz inih-r62.tar.gz
userspace-rcu-0.15.1.tar.bz2 urcu-0.15.1.tar.bz2
# AppImage tier (step_appimage): libappimage v1.0.0 github tag archive
# (url .../archive/refs/tags/v1.0.0.tar.gz builds a cache under that basename).
v1.0.0.tar.gz v1.0.0.tar.gz
EOF
}

packaged() {
    # Version-exact match: a different-version tarball must not block the
    # pinned build (e.g. step_wayland's LibInput 1.26.2 must not stop
    # step_pantheon from building 1.31.3 that Mutter needs). The merge step
    # replaces older versions, so co-existing tarballs are safe.
    [ -f "$B/Packages/$1--$2--x86_64.tar.bz2" ]
}

# Skip guard: also skip a compile when the program is ALREADY INSTALLED in the
# chroot (live tree present) and no failed-build marker exists. This lets a
# step move on to the next package instead of rebuilding an already-merged
# program (e.g. webkit2) or choking on stale index collisions (Lutris).
installed() {
    local prog="$1" ver="$2"
    [ -d "/Programs/$prog/$ver" ] && [ ! -e "/Programs/$prog/$ver-failed" ]
}

compile() {
    # Optional trailing args are forwarded to Compile (e.g. `compile Pkg Ver
    # --lazy` to RESUME an existing partially-built source tree: Compile --batch
    # would `rm -rf` it first -- hours of kernel build lost. --lazy keeps the
    # tree, reusing built objects, and skips unpack/reconfig/repatch).
    local prog="$1" ver="$2"; shift 2
    local extra=("$@")
    if packaged "$prog" "$ver"
    then log "SKIP: $prog $ver (package tarball already present)"
    elif installed "$prog" "$ver"
    then log "SKIP: $prog $ver (already installed in /Programs)"
    else
        log ">>> Compiling $prog $ver${extra[*]:+ (${extra[*]})}"
        Compile "$prog" "$ver" --batch "${extra[@]}" </dev/null 2>&1 | tee "$B/logs/$prog.log"; [ ${PIPESTATUS[0]} -eq 0 ] || {
            log "FAILED: $prog $ver (see $B/logs/$prog.log)"
            return 1
        }
        log "OK: $prog compiled"
    fi
}

compile_keep() {
    # Same-version rebuild INTO an existing program tree. --keep skips
    # Pre_Installation_Preparation, whose per-file index relink mangles
    # directory symlinks (it moves the tree to -safelinking, wipes the live
    # dir and re-symlinks index entries per file -- include/glib-2.0 ends up
    # pointing at a single header, so meson install fails with ENOENT).
    # With --keep the existing tree stays live (build deps remain loadable)
    # and SandboxInstall overlays the new files onto it.
    local prog="$1" ver="$2"
    if packaged "$prog" "$ver"
    then log "SKIP: $prog $ver (package tarball already present)"
    elif installed "$prog" "$ver"
    then log "SKIP: $prog $ver (already installed in /Programs)"
    else
        log ">>> Compiling $prog $ver (in-place, --keep)"
        Compile "$prog" "$ver" --batch --keep </dev/null 2>&1 | tee "$B/logs/$prog.log"; [ ${PIPESTATUS[0]} -eq 0 ] || {
            log "FAILED: $prog $ver (see $B/logs/$prog.log)"
            return 1
        }
        log "OK: $prog compiled"
    fi
}

compile_forced() {
    # In-place forced rebuild of an ALREADY-INSTALLED program against the
    # current environment (e.g. after a kernel swap: the tarball exists and the
    # program tree is present, but its kernel modules were built for the OLD
    # kernel). --keep skips Pre_Installation_Preparation (avoids mangling the
    # safelinked tree, see compile_keep), and the stale tarball is removed
    # first so package() regenerates it. Used by step_nvidia / step_fs when the
    # module-presence guard fails.
    local prog="$1" ver="$2"
    rm -f "$B/Packages/$prog--$ver--x86_64.tar.bz2"
    log ">>> Forcing in-place rebuild of $prog $ver (--keep)"
    Compile "$prog" "$ver" --batch --keep </dev/null 2>&1 | tee "$B/logs/$prog.log"; [ ${PIPESTATUS[0]} -eq 0 ] || {
        log "FAILED: $prog $ver (see $B/logs/$prog.log)"
        return 1
    }
    log "OK: $prog $ver rebuilt"
}

package() {
    # CreatePackage reads the installed tree at /Programs/<prog>/<ver>, so an
    # already-installed program (compile() skipped it) must still be PACKAGED:
    # merge step (refresh-merge.py) only ships Packages/<prog>--<ver>--*.tar.bz2
    # into the ISO.  Skipping here would leave the program on the chroot but
    # never on the booted ISO.
    local prog="$1" ver="$2"
    if packaged "$prog" "$ver"
    then log "SKIP: packaging $prog $ver (tarball present)"
    else
        log ">>> Packaging $prog $ver"
        cd /Programs
        CreatePackage "$prog" "$ver" -t "$B/Packages" >"$B/logs/$prog-pkg.log" 2>&1 || {
            log "FAILED: packaging $prog (see $B/logs/$prog-pkg.log)"
            return 1
        }
        log "OK: packaged $prog -> $(ls "$B/Packages/$prog"--*--x86_64.tar.bz2)"
        cd /Data/Compile
    fi
}

# ---------------------------------------------------------------------------
# Interactive kernel / auto-driver selection.
# Prompts run only when stdin is a terminal (interactive `run-build.sh linux`
# etc.); non-interactive runs (`all`, piped logs) reuse the saved choice from
# $B/.build-select (same store as the component menu), so pressing Enter keeps
# the previous selection.  Choices currently supported:
#   kernel     = linux (stock mainline 7.1.5) | cachyos (7.2.5-1) | none
#   autodriver = nvidia (Nvidia 580.159.04)   | none
# ---------------------------------------------------------------------------

# Prompt: which kernel to build. Sets KERNEL_CHOICE: linux | cachyos | none.
# NOTE: writes to stdout (used via a global, NOT $(...) -- the prompt would
# otherwise be swallowed by the command-substitution pipe and the read would
# block invisibly).
select_kernel() {
    local def="$(comp_select_default kernel)" ans
    case "$def" in
        cachyos) ;; none) ;; *) def=linux ;;
    esac
    if [ -t 0 ]
    then
        echo
        echo "Kernel selection:"
        echo "  1) mainline Linux 7.1.5    (stock Gobo kernel, XFS + OpenZFS modules)"
        echo "  2) linux-cachyos-zfs 7.2.5 (CachyOS kernel 7.2.5-1 from github.com/CachyOS/linux-cachyos)"
        echo "  n) skip building a kernel"
        printf 'Which kernel? [%s] : ' "$([ "$def" = none ] && echo n || echo "$def")"
        read -r ans || ans=""
        case "${ans,,}" in
            n|no|0|skip|none) def=none ;;
            2|cachyos|cach*)  def=cachyos ;;
            1|linux|main|7.1.5) def=linux ;;
            "") : ;;
            *) echo "  Invalid choice '${ans}'; keeping ${def}" ;;
        esac
    fi
    comp_save_default kernel "$def"
    KERNEL_CHOICE="$def"
}

# Prompt: which auto-driver stack to compile. Sets AUTODRIVER_CHOICE: nvidia | none.
select_autodriver() {
    local def="$(comp_select_default autodriver)" ans
    case "$def" in
        none) ;; *) def=nvidia ;;
    esac
    if [ -t 0 ]
    then
        echo
        echo "Auto-driver selection:"
        echo "  1) Nvidia 580.159.04  (proprietary NVIDIA kernel modules + Xorg/udev wiring)"
        echo "  n) skip auto-drivers"
        printf 'Which auto-driver to compile? [%s] : ' "$([ "$def" = none ] && echo n || echo "$def")"
        read -r ans || ans=""
        case "${ans,,}" in
            n|no|0|skip|none) def=none ;;
            1|nvidia|nv) def=nvidia ;;
            "") : ;;
            *) echo "  Invalid choice '${ans}'; keeping ${def}" ;;
        esac
    fi
    comp_save_default autodriver "$def"
    AUTODRIVER_CHOICE="$def"
}

step_linux() {
    if [ -z "$KERNEL_CHOICE" ]; then select_kernel; fi
    log "Kernel selected: $KERNEL_CHOICE"
    # Always re-stage the Linux recipe from the repo: a standalone
    # `run-build.sh linux` skips step_sync, and a stale recipe (e.g. an
    # outdated 01-gobohide.patch) would silently build the wrong kernel
    # pieces. Compile's do_unpack also re-extracts + re-patches in batch mode.
    rm -rf Recipes/Linux
    cp -a /mnt/repo/Recipes/Linux Recipes/Linux
    log "Linux recipe re-staged from /mnt/repo/Recipes/Linux"
    case "$KERNEL_CHOICE" in
        none)    log "SKIP: kernel build declined (kernel=none)" ;;
        cachyos) log "Building CachyOS kernel 7.2.5-1 (linux-cachyos-zfs)"
                 if [ -d /Data/Compile/Sources/cachyos-7.2.5-1 ]
                 then
                     # Resume --lazy keeps the partially-built tree (hours of
                     # objects) and skips unpack/reconfig/repatch. A stale tree
                     # extracted from an OLD recipe patch still calls strncpy(),
                     # which kernel 7.2.x removed -> self-heal it here (idempotent).
                     sed -i 's/^\tstrncpy(nla_data(na), data, size);$/\tmemcpy(nla_data(na), data, size);/' \
                         /Data/Compile/Sources/cachyos-7.2.5-1/fs/gobohide.c 2>/dev/null \
                     || sed -i 's/strncpy(nla_data(na), data, size);/memcpy(nla_data(na), data, size);/' \
                         /Data/Compile/Sources/cachyos-7.2.5-1/fs/gobohide.c
                     log "CachyOS source tree present -> resuming with --lazy (keeps built objects, skips unpack/reconfig)"
                     compile Linux 7.2.5 --lazy
                 else compile Linux 7.2.5
                 fi
                 package Linux 7.2.5 ;;
        *)       log "Building mainline Linux 7.1.5"
                 compile Linux 7.1.5 && package Linux 7.1.5 ;;
    esac
}

# All five NVIDIA kernel modules must be present in the *Linux program's*
# module tree (/lib/modules -> this via the Index symlink) for bare-metal
# NVIDIA support. The Aug-5 build produced a tarball with an EMPTY drivers/video
# dir because the recipe silently skipped flat-layout .ko files, so a tarball
# alone is NOT proof of a good Nvidia build.
nvidia_modules_ok() {
    local kr="$(ls /Programs/Linux/Current/lib/modules)" d m
    d="/Programs/Linux/Current/lib/modules/$kr/kernel/drivers/video"
    [ -e "/Programs/Nvidia/Current/lib/xorg/modules/drivers/nvidia_drv.so" ] || return 1
    for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem
    do [ -e "$d/$m.ko" ] || return 1
    done
    return 0
}

step_nvidia() {
    if [ -z "$AUTODRIVER_CHOICE" ]; then select_autodriver; fi
    log "Auto-driver selected: $AUTODRIVER_CHOICE"
    if [ "$AUTODRIVER_CHOICE" = none ]
    then log "SKIP: auto-driver build declined (autodriver=none)"
         return 0
    fi
    # Always re-stage the Nvidia recipe from the repo: a standalone
    # `run-build.sh nvidia` skips step_sync, and a stale recipe would silently
    # rebuild with the old, kernel-7.2.5-incompatible sources (strncpy etc.).
    rm -rf Recipes/Nvidia
    cp -a /mnt/repo/Recipes/Nvidia Recipes/Nvidia
    log "Nvidia recipe re-staged from /mnt/repo/Recipes/Nvidia"
    # A tarball OR an installed tree can both predate the current kernel (this
    # step recently packaged a stale tree that compile() had skipped via its
    # installed() guard after a deleted tarball). The module check is the source
    # of truth: if it passes, only a missing tarball needs fixing; otherwise the
    # driver must be rebuilt for the CURRENT kernel regardless of what exists.
    if nvidia_modules_ok
    then if packaged Nvidia 580.159.04
         then log "SKIP: Nvidia 580.159.04 (tarball present, kernel modules verified)"
              return 0
         fi
         log "Nvidia kernel modules present but tarball missing -> packaging installed tree"
         package Nvidia 580.159.04 && log "OK: NVIDIA kernel modules installed under $(ls /Programs/Linux/Current/lib/modules)"
         return 0
    fi
    log "Nvidia kernel modules missing/stale for the current kernel -> forcing rebuild"
    if installed Nvidia 580.159.04
    then compile_forced Nvidia 580.159.04 && package Nvidia 580.159.04
    else compile Nvidia 580.159.04 && package Nvidia 580.159.04
    fi &&
    nvidia_modules_ok && log "OK: NVIDIA kernel modules installed under $(ls /Programs/Linux/Current/lib/modules)"
}

# OpenZFS ships zfs.ko (zstd-compressed as zfs.ko.zst) into the *Linux program's*
# module tree (/Programs/Linux/Current/lib/modules/<release>/extra, which is what
# /lib/modules points at), so a tarball alone is NOT proof the module matches the
# CURRENTLY active kernel -- exactly the same trap as Nvidia. After a kernel swap
# the new release's extra/ dir has no zfs.ko until OpenZFS is rebuilt against it.
openzfs_modules_ok() {
    local kr="$(ls /Programs/Linux/Current/lib/modules 2>/dev/null | grep -vE '^(Current|Settings|Variable)$' | head -1)"
    [ -x "/Programs/OpenZFS/2.4.4/sbin/zpool" ] || return 1
    compgen -G "/Programs/Linux/Current/lib/modules/$kr/extra/zfs.ko*" >/dev/null
}
step_glibc32() { compile Glibc-32 2.43-2 && package Glibc-32 2.43-2; }

# 32-bit libraries for Steam client, Wine/Proton, and games.
# All extracted from Debian bookworm i386 packages into lib32/.
# Build order respects inter-dependencies (Glibc-32 must be done first).
step_lib32() {
    # --- base (no deps beyond Glibc-32) ---
    compile Lib32-zlib 1.2.13 && package Lib32-zlib 1.2.13 &&
    compile Lib32-expat 2.5.0 && package Lib32-expat 2.5.0 &&
    compile Lib32-libgcc 12.2.0 && package Lib32-libgcc 12.2.0 &&
    compile Lib32-libstdcpp 12.2.0 && package Lib32-libstdcpp 12.2.0 &&
    compile Lib32-libpng 1.6.37 && package Lib32-libpng 1.6.37 &&
    compile Lib32-DBus 1.14.10 && package Lib32-DBus 1.14.10 &&
    compile Lib32-FreeType 2.12.1 && package Lib32-FreeType 2.12.1 &&
    compile Lib32-alsa-lib 1.2.8 && package Lib32-alsa-lib 1.2.8 &&
    compile Lib32-libsndfile 1.0.31 && package Lib32-libsndfile 1.0.31 &&
    # --- X11 core ---
    compile Lib32-X11 1.8.12 && package Lib32-X11 1.8.12 &&
    compile Lib32-Xext 1.3.4 && package Lib32-Xext 1.3.4 &&
    compile Lib32-Xrandr 1.5.4 && package Lib32-Xrandr 1.5.4 &&
    compile Lib32-Xinerama 1.1.4 && package Lib32-Xinerama 1.1.4 &&
    compile Lib32-Xcursor 1.2.3 && package Lib32-Xcursor 1.2.3 &&
    compile Lib32-Xi 1.8.2 && package Lib32-Xi 1.8.2 &&
    compile Lib32-Xcomposite 0.4.6 && package Lib32-Xcomposite 0.4.6 &&
    compile Lib32-Xdamage 1.1.6 && package Lib32-Xdamage 1.1.6 &&
    compile Lib32-Xss 1.2.3 && package Lib32-Xss 1.2.3 &&
    compile Lib32-Xfixes 5.0.3 && package Lib32-Xfixes 5.0.3 &&
    compile Lib32-Xtst 1.2.3 && package Lib32-Xtst 1.2.3 &&
    # --- XKB + XML ---
    compile Lib32-xkbcommon 1.5.0 && package Lib32-xkbcommon 1.5.0 &&
    compile Lib32-libxml2 2.9.14 && package Lib32-libxml2 2.9.14 &&
    compile Lib32-libxcb 1.15 && package Lib32-libxcb 1.15 &&
    # --- fontconfig (needs FreeType) ---
    compile Lib32-Fontconfig 2.13.1 && package Lib32-Fontconfig 2.13.1 &&
    # --- audio ---
    compile Lib32-libpulse 16.0 && package Lib32-libpulse 16.0 &&
    # --- GL/Vulkan (needs X11) ---
    compile Lib32-libglvnd 1.4.0 && package Lib32-libglvnd 1.4.0 &&
    compile Lib32-mesa 22.3.5 && package Lib32-mesa 22.3.5 &&
    compile Lib32-vulkan-loader 1.3.261.1 && package Lib32-vulkan-loader 1.3.261.1 &&
    # --- crypto/TLS (no deps beyond base) ---
    compile Lib32-openssl 3.0.17 && package Lib32-openssl 3.0.17 &&
    compile Lib32-gnutls 3.7.9 && package Lib32-gnutls 3.7.9 &&
    # --- image libs ---
    compile Lib32-libjpeg 2.1.5 && package Lib32-libjpeg 2.1.5 &&
    compile Lib32-libtiff 4.5.0 && package Lib32-libtiff 4.5.0 &&
    # --- text/harfbuzz chain (needs FreeType) ---
    compile Lib32-harfbuzz 6.0.0 && package Lib32-harfbuzz 6.0.0 &&
    compile Lib32-fribidi 1.0.8 && package Lib32-fribidi 1.0.8 &&
    compile Lib32-pango 1.50.12 && package Lib32-pango 1.50.12 &&
    # --- Xft (needs FreeType + Fontconfig + X11) ---
    compile Lib32-libxft 2.3.6 && package Lib32-libxft 2.3.6 &&
    # --- GLib / GObject (needs zlib + libffi from Glibc-32) ---
    compile Lib32-glib 2.74.6 && package Lib32-glib 2.74.6 &&
    # --- gdk-pixbuf (needs glib + libjpeg + libtiff) ---
    compile Lib32-gdk-pixbuf 2.42.10 && package Lib32-gdk-pixbuf 2.42.10 &&
    # --- database ---
    compile Lib32-sqlite 3.40.1 && package Lib32-sqlite 3.40.1 &&
    # --- audio/multimedia ---
    compile Lib32-mpg123 1.31.2 && package Lib32-mpg123 1.31.2 &&
    compile Lib32-libogg 1.3.5 && package Lib32-libogg 1.3.5 &&
    compile Lib32-theora 1.1.1 && package Lib32-theora 1.1.1 &&
    compile Lib32-vorbis 1.3.7 && package Lib32-vorbis 1.3.7 &&
    compile Lib32-gsm 1.0.22 && package Lib32-gsm 1.0.22 &&
    compile Lib32-openal 1.19.1 && package Lib32-openal 1.19.1 &&
    compile Lib32-libv4l 1.22.1 && package Lib32-libv4l 1.22.1 &&
    # --- video framework ---
    compile Lib32-gstreamer 1.22.0 && package Lib32-gstreamer 1.22.0 &&
    compile Lib32-gst-plugins-base 1.22.0 && package Lib32-gst-plugins-base 1.22.0 &&
    # --- VA-API ---
    compile Lib32-libva 2.17.0 && package Lib32-libva 2.17.0 &&
    # --- X11 extensions ---
    compile Lib32-xxf86vm 1.1.4 && package Lib32-xxf86vm 1.1.4 &&
    compile Lib32-xrender 0.9.10 && package Lib32-xrender 0.9.10 &&
    compile Lib32-xshmfence 1.3 && package Lib32-xshmfence 1.3 &&
    # --- SDL2 (needs X11 + GL + audio) ---
    compile Lib32-SDL2 2.26.1 && package Lib32-SDL2 2.26.1 &&
    # --- Steam/Proton extras (Debian i386 extracts, no intra-chain deps) ---
    compile Lib32-curl 7.88.1 && package Lib32-curl 7.88.1 &&
    compile Lib32-drm 2.4.114 && package Lib32-drm 2.4.114 &&
    compile Lib32-gpg 1.46 && package Lib32-gpg 1.46 &&
    compile Lib32-gtk 2.24.33 && package Lib32-gtk 2.24.33 &&
    compile Lib32-idn 2.3.3 && package Lib32-idn 2.3.3 &&
    compile Lib32-krb5 1.20.1 && package Lib32-krb5 1.20.1 &&
    compile Lib32-ssh 0.10.6 && package Lib32-ssh 0.10.6 &&
    # --- Steam bootstrap host libs (Debian i386 extracts)
    #     missing-log list from ~/.local/share/Steam/logs/console-linux.txt.
    #     libsystemd0 is ABI-only: GoboLinux runs no systemd daemons.
    compile Lib32-libffi 3.4.8 && package Lib32-libffi 3.4.8 &&
    compile Lib32-PCRE2 10.46 && package Lib32-PCRE2 10.46 &&
    compile Lib32-libblkid 2.41 && package Lib32-libblkid 2.41 &&
    compile Lib32-libselinux 3.8.1 && package Lib32-libselinux 3.8.1 &&
    compile Lib32-libmount 2.41 && package Lib32-libmount 2.41 &&
    compile Lib32-libcap 2.75 && package Lib32-libcap 2.75 &&
    compile Lib32-libdatrie 0.2.13 && package Lib32-libdatrie 0.2.13 &&
    compile Lib32-libthai 0.1.29 && package Lib32-libthai 0.1.29 &&
    compile Lib32-libsystemd 257.13 && package Lib32-libsystemd 257.13 &&
    compile Lib32-graphite2 1.3.14 && package Lib32-graphite2 1.3.14 &&
    compile Lib32-brotli 1.1.0 && package Lib32-brotli 1.1.0 &&
    log "OK: All 32-bit libraries built"
}

step_cmake()  { compile CMake 3.30.4 && package CMake 3.30.4; }
# Rebuild SeatD only (recipe pre_build patches the /dev/dri + /dev/input
# realpath-prefix checks for GoboLinux). Used after editing that recipe.
step_seatd()  { compile_keep SeatD 0.6.4 && package SeatD 0.6.4; }

step_nvdiag() {
    # NVIDIA diagnostic tools (clinfo + vdpauinfo). Built after the driver so
    # the runtime backends exist; OpenCL-Headers must come first (clinfo
    # includes <CL/cl.h> via the index).
    compile OpenCL-Headers 2026.05.29 && package OpenCL-Headers 2026.05.29 &&
    compile Clinfo 3.0.25.02.14 && package Clinfo 3.0.25.02.14 &&
    compile VDPAUInfo 1.4 && package VDPAUInfo 1.4
}

step_tools() {
    if meson --version >/dev/null 2>&1 && ninja --version >/dev/null 2>&1
    then log "meson + ninja already usable"
    else
        log "Installing build tools via Alien PIP (meson, ninja)"
        Alien --install PIP:meson || return 1
        # ninja pinned: 1.13's sdist pyproject.toml is unparseable by this
        # chroot's pip 20.x (vendored pytoml), and it has no cp38 wheel.
        # 1.11.1.2 ships a py3-none-manylinux2010 wheel -> installs as-is.
        Alien --install PIP:"ninja==1.11.1.2" || return 1
        meson --version >/dev/null 2>&1 && ninja --version >/dev/null 2>&1 || {
            log "FAILED: meson/ninja still unusable after Alien install"
            return 1
        }
    fi
}

step_wayland() {
    # Dependency order matters:
    #  XKBcommon needs wayland + wayland-protocols (enable-wayland default true);
    #  EGL-Wayland needs eglexternalplatform (EGL_EXT_external_platform headers);
    #  XorgProto (>= 2022.2) must precede XWayland: XWayland 24.1.2 requires
    #    inputproto >= 2.3.99.1, which the ISO's XorgProto 2019.2 (2.3.2) lacks;
    #  LibDrm (>= 2.4.116) also precedes XWayland (ISO ships 2.4.100); wlroots
    #    0.15.1 additionally needs libdrm >= 2.4.108;
    #  XWayland must be built BEFORE Wlroots so that wlroots' 'auto' xwayland
    #    feature finds the 'Xwayland' binary at its own build time;
    #  Sway last: needs the whole stack + scdoc (man pages);
    #  wlr-protocols needs wayland-scanner for its 'check' target; wlr-randr and
    #    wayland-utils build after the core stack (scdoc optional for wlr-randr).
    step_tools &&
    compile Wayland 1.23.1 && package Wayland 1.23.1 &&
    compile Wayland-Protocols 1.44 && package Wayland-Protocols 1.44 &&
    compile XKBcommon 1.7.0 && package XKBcommon 1.7.0 &&
    compile LibInput 1.26.2 && package LibInput 1.26.2 &&
    compile LibXKBfile 1.1.3 && package LibXKBfile 1.1.3 &&
    compile LibXcvt 0.1.2 && package LibXcvt 0.1.2 &&
    compile EGLExternalPlatform 1.2.1 && package EGLExternalPlatform 1.2.1 &&
    compile EGL-Wayland 1.1.9 && package EGL-Wayland 1.1.9 &&
    compile Scdoc 1.11.3 && package Scdoc 1.11.3 &&
    compile SeatD 0.6.4 && package SeatD 0.6.4 &&
    compile XorgProto 2024.1 && package XorgProto 2024.1 &&
    compile LibDrm 2.4.121 && package LibDrm 2.4.121 &&
    compile XWayland 24.1.2 && package XWayland 24.1.2 &&
    compile Wlroots 0.15.1 && package Wlroots 0.15.1 &&
    compile Sway 1.7 && package Sway 1.7 &&
    compile Wlr-Protocols a741f0a && package Wlr-Protocols a741f0a &&
    compile Wayland-Utils 1.3.0 && package Wayland-Utils 1.3.0 &&
    compile Wlr-Randr 0.5.0 && package Wlr-Randr 0.5.0
}

# Sway ecosystem tools not shipped inside the sway 1.7 tarball (separate
# upstream projects): swaybg (wallpaper), swaylock (lock screen - the default
# config's $mod+Escape binding), swayidle (idle/dpms), libdecor (wayland
# window decorations for SDL2). All four only need the wayland stack (each
# vendors its protocol XML or uses wayland-protocols' staging tree - no
# wlr-protocols build dep), so they sort after step_wayland. Recipes are
# synced fresh from the repo each run (same as step_pantheon); the archive
# staging in step_sync pulls the four tarballs from $B.
step_swayextras() {
    step_sync &&
    step_tools &&
    compile SwayBg 1.2.2 && package SwayBg 1.2.2 &&
    compile SwayLock 1.8.6 && package SwayLock 1.8.6 &&
    compile SwayIdle 1.9.0 && package SwayIdle 1.9.0 &&
    compile LibDecor 0.2.2 && package LibDecor 0.2.2
}

step_vulkan() {
    # Vulkan-Tools' vulkaninfo hard-requires wayland-client when the Wayland
    # WSI is enabled (its default), and the loader should match: build the
    # Wayland stack first so a standalone `vulkan` run is self-sufficient.
    step_wayland &&
    step_cmake &&
    compile Vulkan-Headers 1.4.357.0 && package Vulkan-Headers 1.4.357.0 &&
    compile Vulkan-Loader 1.4.357.0  && package Vulkan-Loader 1.4.357.0 &&
    compile Vulkan-Tools 1.4.357.0   && package Vulkan-Tools 1.4.357.0
}
step_steam() {
    # RenPy 8.5.3 is a prebuilt SDK manifest (bundles its own CPython/SDL2), so
    # it needs no toolchain or runtime deps beyond the ISO base.
    compile Steam 1.0.0.87_bin && package Steam 1.0.0.87_bin &&
    compile RenPy 8.5.3 && package RenPy 8.5.3
}

step_winetools() {
    # Wine helper tools. Protontricks intentionally lives in step_winedev: it
    # must be rebuilt for the new python3.11 main interpreter AFTER the Python
    # 3.11 recipe flips the index's python3 symlink (see step_winedev).
    compile Winetricks 20260125 && package Winetricks 20260125
}

step_lutris() {
    # Self-contained step: builds ONLY what Lutris needs at runtime --
    #   WebKitGTK with introspection (account-login WebViews),
    #   Xrandr (resolution queries), Mesa-Utils (glxinfo), P7zip (7z),
    #   and Lutris itself.
    # It NEVER builds sway/wlroots/wayland: those belong to the 'wayland'
    # step (Sway compiles there) and only run when a desktop component
    # (wayland/swayextras/pantheon/plasma) is part of the selection.
    # Pre-check: report what is still missing and skip the whole step when
    # Lutris's stack is already built + packaged.
    local missing=""
    [ -f "$B/Packages/Lutris--0.5.22--x86_64.tar.bz2" ]   || missing="$missing lutris"
    [ -f "$B/Packages/Xrandr--1.5.2--x86_64.tar.bz2" ]    || missing="$missing xrandr"
    [ -f "$B/Packages/Mesa-Utils--9.0.0--x86_64.tar.bz2" ]|| missing="$missing mesa-utils"
    [ -f "$B/Packages/P7zip--26.00--x86_64.tar.bz2" ]     || missing="$missing p7zip"
    [ -d /Programs/WebKit2GTK/2.46.5 ]                    || missing="$missing webkit"
    if [ -z "$missing" ]
    then
        log "SKIP: Lutris stack fully built + packaged (lutris, xrandr, mesa-utils, p7zip, webkit)"
        return 0
    fi
    log "Lutris step: missing${missing} -- building only those"
    # Lutris' WebConnectDialog (service logins) needs the introspection
    # WebKit2GTK (WebKit2-4.1.typelib).  Ensure the webkit chain is built
    # before Lutris; step_webkit's feature guards keep repeat runs cheap
    # (they only rebuild when the published artifact lacks the typelib or a
    # dep gir), so this is a no-op once the webkit tier is up.
    { tar -tjf "$B/Packages/WebKit2GTK--2.46.5--x86_64.tar.bz2" 2>/dev/null |
        grep -q 'lib/girepository-1.0/WebKit2-4.1.typelib'; } ||
        step_webkit
    # Lutris + its runtime tools in one step. Compile's dependency resolution
    # (recipe Resources/Dependencies) installs Xrandr/Mesa-Utils/P7zip/
    # WebKit2GTK while compiling Lutris; package them all so the merged ISO
    # ships them too.
    # NOTE: do NOT rely on that side-effect for packaging -- if the Lutris
    # tarball already exists compile() skips it and the dependency pass never
    # runs, so the tools would not be in /Programs and CreatePackage fails.
    # Compile each tool explicitly before packaging it.
    # Rebuild guard: if Lutris is ALREADY INSTALLED (live tree present) the
    # compile is skipped (see installed()) -- the tree is complete, and a
    # rebuild over it would choke on the stale /usr index symlinks (EEXIST).
    # The failed sandbox leftover .SandboxInstall_Root must be purged so
    # CreatePackage does not sweep it into the tarball.
    rm -rf /Programs/Lutris/0.5.22/.SandboxInstall_Root /Programs/Lutris/0.5.22-failed &&
    compile Lutris 0.5.22 && package Lutris 0.5.22 &&
    compile Xrandr 1.5.2 && package Xrandr 1.5.2 &&
    compile Mesa-Utils 9.0.0 && package Mesa-Utils 9.0.0 &&
    compile P7zip 26.00 && package P7zip 26.00
}

step_winedev() {
    # Gaming stack for the Live CD. Order matters:
    #  OpenSSL 1.1.1w must precede Python 3.11.12 (Python builds against it;
    #    the ISO only ships 1.1.1d libs, no headers);
    #  PyCairo -> PyGObject -> Lutris follow Python (they target python3.11);
    #  Protontricks is REBUILT here (not in step_winetools) because it must
    #    run on python3.11 with its deps bundled; the old 3.8-targeted
    #    tarball + program tree are cleared so the packaged() skip doesn't
    #    leave a stale build behind;
    #  Wine/Wine-Lutris-GE/DXVK/Vkd3d-Proton/Heroic are prebuilt manifests
    #    (no toolchain needed) and sort after the python chain for clarity.
    compile OpenSSL 1.1.1w && package OpenSSL 1.1.1w &&
    compile Python 3.11.12 && package Python 3.11.12 &&
    compile PyCairo 1.20.1 && package PyCairo 1.20.1 &&
    compile PyGObject 3.44.1 && package PyGObject 3.44.1 &&
    # Lutris' recipe Resources/Dependencies auto-installs its runtime tools
    # (Xrandr + Mesa-Utils glxinfo + P7zip 7z) during `compile Lutris`; compile
    # + package those three trees EXPLICITLY too (the dependency pass only runs
    # when Lutris actually compiles -- a pre-existing tarball would skip it and
    # leave the tools missing from /Programs, and CreatePackage needs them).
    compile Lutris 0.5.22 && package Lutris 0.5.22 &&
    compile Xrandr 1.5.2 && package Xrandr 1.5.2 &&
    compile Mesa-Utils 9.0.0 && package Mesa-Utils 9.0.0 &&
    compile P7zip 26.00 && package P7zip 26.00 &&
    rm -f "$B/Packages/Protontricks--1.14.1--x86_64.tar.bz2" &&
    rm -rf /Programs/Protontricks/1.14.1 /Programs/Protontricks/1.14.1-failed &&
    # Drop stale index symlinks pointing into the wiped program tree (bin entry
    # scripts, share/applications *.desktop, lib{64}/python3.8 site-packages).
    # Left dangling, setuptools install_scripts / install_data open() follows a
    # symlink into the missing package dir -> ENOENT.
    { find /System/Index -type l -lname '/Programs/Protontricks*' -delete 2>/dev/null || :; } &&
    log "Cleared stale 3.8-targeted Protontricks build; rebuilding for python3.11" &&
    compile Protontricks 1.14.1 && package Protontricks 1.14.1 &&
    compile Wine 11.14 && package Wine 11.14 &&
    compile Wine-Lutris-GE 11.14 && package Wine-Lutris-GE 11.14 &&
    compile DXVK 3.0.2 && package DXVK 3.0.2 &&
    compile Vkd3d-Proton 3.0.1 && package Vkd3d-Proton 3.0.1 &&
    compile Heroic 2.22.0 && package Heroic 2.22.0
}

step_protonplus() {
    # ProtonPlus 0.6.8: GUI manager for Wine/Proton + DXVK/Vkd3d compatibility
    # tools. Official sharun "anylinux" AppImage, extracted into lib/protonplus
    # at install time (DwarFS payload; --appimage-extract needs no FUSE). Runs
    # from its bundled GTK4/Adwaita/SDL3 libs -- no build deps. Part of the
    # gaming component (alongside Steam/Lutris/Heroic).
    rm -rf Recipes/ProtonPlus
    cp -a /mnt/repo/Recipes/Gaming/ProtonPlus Recipes/ProtonPlus
    compile ProtonPlus 0.6.8 && package ProtonPlus 0.6.8
}

step_ffxiv() {
    # XIVLauncher (FFXIVQuickLauncher) 7.0.20: the Windows .NET/WPF launcher
    # for Final Fantasy XIV, shipped from the official Squirrel nupkg and run
    # under Wine.  Needs the Wine stack (Wine/Wine-Lutris-GE staging +
    # DXVK/Vkd3d-Proton/P7zip) which step_winedev already built; the recipe
    # declares those in Res/Dependencies so compile() pulls them if missing.
    # This step is a separate optional component from `gaming`; in the interactive
    # menu the default follows .build-select (currently ffxiv=yes).
    ensure_xivlauncher_archive &&
    compile FFXIVQuickLauncher 7.0.20 && package FFXIVQuickLauncher 7.0.20
}

step_music() {
    # LMMS 1.3.0-alpha.2 DAW ('music' optional component, off by default).
    # Build deps are Qt5 (Core/Gui/Widgets/Xml/Svg), FFTW3F and libsndfile --
    # all already present: Qt 5.15.2 is the migrated Programs/Qt/Current (qt
    # tarball exists), FFTW3F 3.3.8 + LibSndfile 1.0.28 come ON the base ISO,
    # so no extra compile is needed.  step_music just re-ensures the Qt 5.15.2
    # tarball is published (merge overlays it over the base 5.14.1) and builds
    # LMMS itself.  compile() guards skip Qt (tarball present) if it's lost.
    compile Qt 5.15.2 && package Qt 5.15.2 &&
    compile LMMS 1.3.0-alpha.2 && package LMMS 1.3.0-alpha.2
}

step_pipewire() {
    # 'pipewire' optional component: system-wide media server + session
    # manager (the modern audio stack).  First bumps ALSA-Lib 1.2.2 -> 1.2.13
    # (PipeWire 1.4.0 hard-requires alsa >= 1.2.10; libasound.so.2 is ABI-
    # stable so the bump is transparent to existing consumers).  Then builds
    # the FULL PipeWire 1.4.0 daemon (systemd-free; adds pipewire daemon,
    # tools, pipewire-pulse, pipewire-alsa on top of the client-only
    # LibPipewire the ISO already ships) and finally WirePlumber 0.5.17 as its
    # session manager (bundled static Lua, no Lua 5.4 needed).  Order matters:
    # PipeWire needs the new alsa.pc, WirePlumber needs libpipewire-0.3.pc.
    #
    # Runtime startup for the Gobo init system (Resources/Tasks/PipeWire +
    # Resources/Tasks/WirePlumber -> /System/Tasks via SymlinkProgram) and the
    # PulseAudio disable switch are applied by apply-live-fixes.sh section 40
    # during 'merge'.  A bare `run-build.sh pipewire` only produces the
    # packages; re-run 'merge' afterwards to wire them into the ISO.
    step_sync
    compile ALSA-Lib 1.2.13 || return 1
    package ALSA-Lib 1.2.13 || return 1
    compile PipeWire 1.4.0 || return 1
    package PipeWire 1.4.0 || return 1
    compile WirePlumber 0.5.17 || return 1
    package WirePlumber 0.5.17 || return 1
    log "OK: ALSA-Lib + PipeWire + WirePlumber built. Run 'merge' (apply-live-fixes section 40) to wire the boot task and disable PulseAudio."
}

step_pycompat() {
    # The Python 3.11.12 recipe flips /System/Index/bin/python3 to the 3.11
    # interpreter, but Gobo's Scripts python modules (PythonUtils, GuessProgramCase,
    # UseFlags, Alien, ...) live in the 3.8 site-packages. PYTHONPATH covers the
    # chroot build (see header); this step ships a .pth so the BOOTED ISO's Gobo
    # tooling (Compile, UseFlags, CheckDependencies, ...) resolves them too. The
    # .pth goes into the 3.11 interpreter's own site-packages (auto-on sys.path),
    # so a plain `python3` on the CD picks it up. Must run after Python is packaged
    # (winedev) and before merge; the Python recipe's post_install writes the same
    # file for future fresh builds, so this is a one-time repackage of the already
    # built tree.
    local pth="/Programs/Python/3.11.12/lib/python3.11/site-packages/gobo-3.8-site.pth"
    local tarball="$B/Packages/Python--3.11.12--x86_64.tar.bz2"
    if [ -f "$tarball" ] && tar -tf "$tarball" 2>/dev/null | grep -q "gobo-3.8-site.pth"
    then
        log "Python tarball already ships gobo-3.8-site.pth; skipping"
        return 0
    fi
    log "Injecting gobo-3.8-site.pth into the Python 3.11 tree + repackaging"
    mkdir -p "$(dirname "$pth")"
    printf '/System/Index/lib/python3.8/site-packages\n' > "$pth"
    rm -f "$tarball"
    cd /Programs
    CreatePackage Python 3.11.12 -t "$B/Packages" >"$B/logs/Python-pkg.log" 2>&1 || {
        log "FAILED: repackaging Python (see $B/logs/Python-pkg.log)"
        cd /Data/Compile
        return 1
    }
    log "OK: repackaged Python with gobo.pth -> $(ls "$B"/Packages/Python--*--x86_64.tar.bz2)"
    cd /Data/Compile
}

ensure_pyxml() {
    # The ISO's ITSTool 2.0.6 is a Python script that does `import libxml2`
    # (the libxml2 Python bindings). The base ISO's LibXML2 2.9.10 ships NO
    # python module, so any meson build that merges translations via itstool
    # dies with "ModuleNotFoundError: No module named 'libxml2'" (AppStream
    # 1.0.6's org.freedesktop.appstream.cli.metainfo.xml target). Build the
    # bindings from the matching 2.9.10 source against python3.11 and install
    # them into the Python 3.11 tree, then repackage Python so the booted ISO
    # ships them too (same pattern as step_pycompat). libxml2 2.9.10's
    # bindings compile on python 3.11 (PyEval_CallObject/PyUnicode_AsUTF8String
    # still exist there; they were only dropped in 3.12/3.13).
    local arch="/Data/Compile/Archives/libxml2-2.9.10.tar.gz"
    local srcdir="/Data/Compile/Sources/libxml2-2.9.10"
    local tarball="$B/Packages/Python--3.11.12--x86_64.tar.bz2"
    if python3 -c "import libxml2" >/dev/null 2>&1
    then
        log "python libxml2 bindings already importable"
        if [ -f "$tarball" ] && tar -tf "$tarball" 2>/dev/null | grep -q "libxml2mod"
        then log "Python tarball already ships libxml2mod; skipping repackage"
        fi
        return 0
    fi
    log ">>> Building python3.11 libxml2 bindings (itstool dep for AppStream)"
    # xmlsoft.org's HTTPS cert is expired, so prefer the host-staged copy in
    # $B (bind-mounted); fall back to plain http (works, http -> no TLS).
    # Re-stage whenever the archive is missing OR empty (a failed wget can
    # leave a 0-byte file that would otherwise block re-downloading).
    if [ ! -s "$arch" ]
    then
        rm -f "$arch"
        if [ -s "$B/libxml2-2.9.10.tar.gz" ]
        then cp "$B/libxml2-2.9.10.tar.gz" "$arch"
        else wget -q -O "$arch" "http://xmlsoft.org/sources/libxml2-2.9.10.tar.gz" || {
            log "FAILED: downloading libxml2-2.9.10.tar.gz"
            return 1
        }
        fi
    fi
    rm -rf "$srcdir"
    tar -xzf "$arch" -C /Data/Compile/Sources || return 1
    cd "$srcdir/python" || return 1
    # libxml.c/types.c use `} else if PyUnicode_Check (ret) {` (and similar)
    # bare, relying on old Python macros expanding to a fully parenthesized
    # expression. Python 3.11's Py*_Check expand to a bare PyType_FastSubclass
    # call, which is a syntax error in an if/else-if condition ("expected '('
    # before 'PyType_HasFeature'"). Wrap every `(else )?if Py*_Check(...)`
    # call in parens. Matches the verification done on the host toolchain.
    sed -i -E 's/(else if |if )Py([A-Za-z_]*)Check *\( *([^)]*) *\)/\1(Py\2Check (\3))/g' libxml.c types.c || return 1
    python3 setup.py build_ext >/dev/null 2>"$B/logs/libxml2-py-build.log" || {
        log "FAILED: libxml2 python bindings build (see $B/logs/libxml2-py-build.log)"
        cd /Data/Compile
        return 1
    }
    python3 setup.py install --prefix=/Programs/Python/3.11.12 >/dev/null 2>"$B/logs/libxml2-py-install.log" || {
        log "FAILED: libxml2 python bindings install (see $B/logs/libxml2-py-install.log)"
        cd /Data/Compile
        return 1
    }
    cd /Data/Compile
    if ! python3 -c "import libxml2" >/dev/null 2>&1
    then
        log "FAILED: libxml2 still not importable by python3"
        return 1
    fi
    log "OK: libxml2 python bindings built for python3.11"
    rm -f "$tarball"
    cd /Programs
    CreatePackage Python 3.11.12 -t "$B/Packages" >"$B/logs/Python-pkg.log" 2>&1 || {
        log "FAILED: repackaging Python (see $B/logs/Python-pkg.log)"
        cd /Data/Compile
        return 1
    }
    log "OK: repackaged Python with libxml2 bindings -> $(ls "$B"/Packages/Python--*--x86_64.tar.bz2)"
    cd /Data/Compile
}

step_pyxml() { ensure_pyxml; }

ensure_libx11_archive() {
    # Stage the host-downloaded libX11 1.8.13 tarball into the chroot's archive
    # cache before Compile runs, so the build never depends on x.org being
    # reachable (same pattern as the libxml2 staging in ensure_pyxml).
    local arch="/Data/Compile/Archives/libX11-1.8.13.tar.xz"
    if [ ! -s "$arch" ]
    then
        rm -f "$arch"
        if [ -s "$B/libX11-1.8.13.tar.xz" ]
        then cp "$B/libX11-1.8.13.tar.xz" "$arch"
        else wget -q -O "$arch" "https://www.x.org/releases/individual/lib/libX11-1.8.13.tar.xz" || {
            log "FAILED: downloading libX11-1.8.13.tar.xz"
            return 1
        }
        fi
        log "OK: staged libX11-1.8.13.tar.xz into /Data/Compile/Archives"
    fi
}

ensure_libxfixes_archive() {
    # Stage the host-downloaded libXfixes 6.0.1 tarball into the chroot's
    # archive cache before Compile runs (same pattern as ensure_libx11_archive).
    local arch="/Data/Compile/Archives/libXfixes-6.0.1.tar.xz"
    if [ ! -s "$arch" ]
    then
        rm -f "$arch"
        if [ -s "$B/libXfixes-6.0.1.tar.xz" ]
        then cp "$B/libXfixes-6.0.1.tar.xz" "$arch"
        else wget -q -O "$arch" "https://www.x.org/releases/individual/lib/libXfixes-6.0.1.tar.xz" || {
            log "FAILED: downloading libXfixes-6.0.1.tar.xz"
            return 1
        }
        fi
        log "OK: staged libXfixes-6.0.1.tar.xz into /Data/Compile/Archives"
    fi
}

ensure_libgudev_archive() {
    # Stage the host-downloaded libgudev 238 tarball into the chroot's archive
    # cache before Compile runs (same pattern as ensure_libx11_archive).
    local arch="/Data/Compile/Archives/libgudev-238.tar.xz"
    if [ ! -s "$arch" ]
    then
        rm -f "$arch"
        if [ -s "$B/libgudev-238.tar.xz" ]
        then cp "$B/libgudev-238.tar.xz" "$arch"
        else wget -q -O "$arch" "https://download.gnome.org/sources/libgudev/238/libgudev-238.tar.xz" || {
            log "FAILED: downloading libgudev-238.tar.xz"
            return 1
        }
        fi
        log "OK: staged libgudev-238.tar.xz into /Data/Compile/Archives"
    fi
}

ensure_xivlauncher_archive() {
    # Stage the host-downloaded XIVLauncher-7.0.20-full.nupkg into the chroot's
    # archive cache before Compile runs (same pattern as ensure_libx11_archive).
    # The repo recipe pins file_size=112025386 / file_md5=f1d38b52..., so a
    # stale/partial copy is re-fetched.
    local arch="/Data/Compile/Archives/XIVLauncher-7.0.20-full.nupkg"
    if [ ! -s "$arch" ]
    then
        rm -f "$arch"
        if [ -s "$B/XIVLauncher-7.0.20-full.nupkg" ]
        then cp "$B/XIVLauncher-7.0.20-full.nupkg" "$arch"
        else wget -q -O "$arch" "https://github.com/goatcorp/FFXIVQuickLauncher/releases/download/7.0.20/XIVLauncher-7.0.20-full.nupkg" || {
            log "FAILED: downloading XIVLauncher-7.0.20-full.nupkg"
            return 1
        }
        fi
        log "OK: staged XIVLauncher-7.0.20-full.nupkg into /Data/Compile/Archives"
    fi
}

ensure_gnome_desktop_legacy() {
    # gnome-settings-daemon 48.1 links the GTK3-era gnome-desktop-3.0 API
    # (meson: dependency 'gnome-desktop-3.0' >= 3.37.1), so Gnome-Desktop 44.5
    # must be built with -Dlegacy_library=true to also ship
    # lib/pkgconfig/gnome-desktop-3.0.pc. Tarballs made before that option was
    # enabled lack the pc file; wipe them (tarball + index symlinks + program
    # tree) so the rebuild picks it up. Idempotent.
    local tarball="$B/Packages/Gnome-Desktop--44.5--x86_64.tar.bz2"
    if [ -f "$tarball" ] && ! tar -tjf "$tarball" 2>/dev/null | grep -q 'lib/pkgconfig/gnome-desktop-3.0.pc'
    then
        log "Wiping Gnome-Desktop 44.5 (tarball lacks gnome-desktop-3.0.pc; gsd 48.1 needs it)"
        rm -f "$tarball"
        { find /System/Index -type l -lname '/Programs/Gnome-Desktop*' -delete 2>/dev/null || :; }
        rm -rf /Programs/Gnome-Desktop/44.5 /Programs/Gnome-Desktop/44.5-failed
    fi
}

ensure_libostree_curl() {
    # The flatpak closure must be desktop-free: libostree must NOT link
    # libsoup3 (a Pantheon package). The recipe now builds --with-curl
    # --without-soup{,3}, but any tarball made before that change still links
    # libsoup-3.0.so, and plain packaged() would silently keep it (exactly
    # what bit the flatpak closure). Detect the soup linkage and wipe the
    # tarball + index symlinks + program tree so step_core rebuilds it with
    # the curl-only recipe. Idempotent after one rebuild.
    local tarball="$B/Packages/LibOstree--2025.6--x86_64.tar.bz2"
    local tmp
    [ -f "$tarball" ] || return 0
    tmp="$(mktemp -d)" || return 0
    if tar -xjf "$tarball" -C "$tmp" --wildcards 'LibOstree/*/lib/libostree-1.so*' 2>/dev/null &&
       grep -rlq 'libsoup-3.0.so.0' "$tmp" 2>/dev/null
    then
        log "Wiping LibOstree 2025.6 (tarball links libsoup3; flatpak closure must be desktop-free)"
        rm -f "$tarball"
        { find /System/Index -type l -lname '/Programs/LibOstree*' -delete 2>/dev/null || :; }
        rm -rf /Programs/LibOstree/2025.6 /Programs/LibOstree/2025.6-*
    fi
    rm -rf "$tmp"
}

step_mingw() {
    # MinGW-w64 cross toolchain (x86_64-w64-mingw32): prerequisite for building
    # Wine 11, DXVK and vkd3d(-proton) from source on the chroot.
    compile Mingw-w64 12.0.0 && package Mingw-w64 12.0.0
}

step_fastfetch() {
    # FastFetch 2.68.1: fast system-info fetcher (neofetch replacement).
    # Prebuilt official binary tarball (glibc-only, self-contained); no
    # toolchain or runtime deps beyond the ISO base.
    rm -rf Recipes/FastFetch
    cp -a /mnt/repo/Recipes/FastFetch Recipes/FastFetch
    compile FastFetch 2.68.1 && package FastFetch 2.68.1
}

step_nodejs() {
    # Node.js 24.21.0 (Krypton LTS) + bundled npm/npx/corepack. Self-contained
    # official linux-x64 tarball; no toolchain deps. The 'programming'
    # component builds this via step_go/step_odin siblings.
    rm -rf Recipes/NodeJS
    cp -a /mnt/repo/Recipes/Programming/NodeJS Recipes/NodeJS
    compile NodeJS 24.21.0 && package NodeJS 24.21.0
}

step_go() {
    # Go 1.27.1 (official linux-amd64 tarball, self-contained toolchain:
    # compiler + gofmt + std). GOROOT is derived from the go binary's location
    # so the manifest keeps bin/ a sibling of pkg/src/lib like /usr/local/go.
    rm -rf Recipes/Go
    cp -a /mnt/repo/Recipes/Programming/Go Recipes/Go
    compile Go 1.27.1 && package Go 1.27.1
}

step_odin() {
    # Odin dev-2026-09 (official linux-amd64 nightly release). Fully static
    # single binary; stdlib (base/core/shared/vendor) ships beside it and is
    # located via /proc/self/exe, so no ODIN_ROOT export is needed. Linking
    # uses the ISO's cc (GCC 14.2.0) + ld (BinUtils 2.33.1).
    rm -rf Recipes/Odin
    cp -a /mnt/repo/Recipes/Programming/Odin Recipes/Odin
    compile Odin dev-2026-09 && package Odin dev-2026-09
}

step_v() {
    # V language 0.5.2 (official github release v_linux.zip). Prebuilt
    # compiler binary + vlib/thirdparty shipped beside the program root and
    # located via /proc/self/exe. Needs GLIBC_2.34, so it only works on ISOs
    # built after the glibc 2.44-2 merge. Linking uses the ISO's cc (GCC).
    rm -rf Recipes/V
    cp -a /mnt/repo/Recipes/Programming/V Recipes/V
    compile V 0.5.2 && package V 0.5.2
}

step_extras() {
    # Discord is a self-updating desktop bootstrap binary and is NOT part of
    # the shared core. Bubblewrap moved into step_core (Flatpak backend) and
    # ECM + SDDM moved into step_sddm, so `extras` no longer drags in any
    # shareable build.
    # VLC 3.0.21 uses the Qt 5.15.2 interface, so run 'extras' after the SDDM
    # Qt5 migration (Recipe/VLC marks the rest of its deps as ISO base).
    compile Discord 1.0.152 && package Discord 1.0.152 &&
    compile VLC 3.0.21 && package VLC 3.0.21
}

# Elogind seat/session foundation: the tiny shared subset that SDDM, Flatpak
# and the Pantheon desktop all need. Nothing here pulls in any desktop
# package -- every dep (DBus, Eudev, Linux-PAM, Util-Linux, LibCap) is ISO
# base.
step_elogind_base() {
    # elogind's pam module needs Linux-PAM's headers, but the ISO program
    # never links include/security into the index (nothing else builds
    # against PAM). libpam.so is already in the index.
    { test -e /System/Index/include/security -o -L /System/Index/include/security ||
      ln -s /Programs/Linux-PAM/Current/include/security /System/Index/include/security; } &&
    # 7.1.5 kernel headers (VMADDR_CID_LOCAL, x25_hdlc_proto) replace the ISO's
    # 5.4.15 set so elogind's bundled kernel-6.14 UAPI compiles cleanly.
    compile Linux-Headers 7.1.5 && package Linux-Headers 7.1.5 &&
    compile Elogind 257.16 && package Elogind 257.16 &&
    # Boot wiring for elogind: a recipe PostInstall can't do this (Run_PostInstall
    # runs in a UnionSandbox that discards writes outside the program tree), so
    # append here instead. Idempotent across rebuilds.
    if grep -q "Elogind Start" "$goboSettings/BootScripts/BootUp"
    then log "elogind boot line already present"
    else echo 'Exec "Starting elogind daemon..."        Elogind Start' >> "$goboSettings/BootScripts/BootUp" || return 1
         log "wired elogind into BootUp"
    fi
}

# Shared desktop-agnostic foundation: the GLib/GNOME substrate plus the whole
# Flatpak chain. Reaches a WORKING flatpak with NO Pantheon desktop package on
# the index -- `build.sh flatpak` (or the --flatpak component) stops here.
#
# Everything below is used by at least the flatpak runtime AND the Pantheon
# desktop (flatpak -> PantheonSideload; gdk-pixbuf/json-glib/appstream also
# feed GTK3/GTK4; elogind feeds polkit + SDDM). Keeping it one step means each
# package is built exactly once no matter which component pulls it in.
step_core() {
    # Always pull fresh recipes from the repo first: step_sync is not part of
    # the default flow, and stale recipes here silently rebuild with old
    # options (bit us with Fwupd's introspection flag).
    step_sync &&
    step_tools &&
    compile PCRE2 10.47 && package PCRE2 10.47 &&
    # GLib bootstrap: pass 1 without introspection (no GI tooling yet) ->
    # GObject-Introspection 1.84 against it -> pass 2 WITH introspection so
    # glib emits its own .gir/.typelibs. Pass 1 must be a FRESH install (wipe
    # any leftover tree + stale index symlinks) or Pre_Installation_Preparation
    # dangles them mid-install. Pass 2 uses compile_keep: --keep leaves the
    # pass-1 tree live so g-ir-scanner can load libgirepository during the
    # build, and the install overlays the introspection files onto it.
    # Idempotent: both flatpak and pantheon call step_core, so skip the full
    # wipe+rebuild once an introspection-enabled GLib tarball already exists
    # (Gio typelib present), keeping the "built exactly once" promise.
    if [ -f "$B/Packages/GLib--2.84.4--x86_64.tar.bz2" ] &&
       tar -tjf "$B/Packages/GLib--2.84.4--x86_64.tar.bz2" 2>/dev/null |
           grep -q 'lib/girepository/Gio-2.0'
    then
        log "GLib 2.84.4 introspection tarball present; skipping two-pass rebuild"
        compile GObject-Introspection 1.84.0 && package GObject-Introspection 1.84.0
    else
        rm -f "$B/Packages/GLib--2.84.4--x86_64.tar.bz2" &&
        { find /System/Index -type l -lname '/Programs/GLib/2.84.4*' -delete 2>/dev/null || :; } &&
        rm -rf /Programs/GLib/2.84.4 /Programs/GLib/2.84.4-* &&
        GLIB_INTROSPECTION=disabled compile GLib 2.84.4 && package GLib 2.84.4 &&
        compile GObject-Introspection 1.84.0 && package GObject-Introspection 1.84.0 &&
        rm -f "$B/Packages/GLib--2.84.4--x86_64.tar.bz2" &&
        GLIB_INTROSPECTION=enabled compile_keep GLib 2.84.4 && package GLib 2.84.4
    fi &&
    # GdkPixbuf: flatpak's flatpak-validate-icon libexec helper links
    # gdk-pixbuf-2.0 UNCONDITIONALLY (meson.build), so it must pre-exist on
    # the index before Flatpak. Only needs GLib + libpng + jpeg/tiff (ISO).
    compile GdkPixbuf 2.42.12 && package GdkPixbuf 2.42.12 &&
    # JSON-GLib: flatpak depends on json-glib-1.0 unconditionally.
    compile JSON-GLib 1.10.0 && package JSON-GLib 1.10.0 &&
    step_elogind_base &&
    # Duktape must precede Polkit: polkit 126's embedded JS rules engine
    # (libpolkit-backend) does `dependency('duktape', version: '>= 2.2.0')`
    # when polkitd is built (libs-only=false). Provides libduktape.so + headers.
    compile Duktape 2.7.0 && package Duktape 2.7.0 &&
    # LibSeccomp: flatpak sandboxing (-Dseccomp=enabled); also needed later by
    # gnome-desktop (sandbox helper), kept in core so it stays buildable
    # desktop-free.
    compile LibSeccomp 2.6.1 && package LibSeccomp 2.6.1 &&
    # /etc/xml/catalog must exist before AppStream: its docs/meson.build runs
    # `xsltproc --nonet http://docbook.sourceforge.net/.../manpages/docbook.xsl`
    # UNCONDITIONALLY (no option disables the man pages). libxml2's compiled-in
    # default catalog is file:///etc/xml/catalog, but /etc -> /System/Settings
    # ships no xml/ dir, so without this link xsltproc cannot resolve the
    # stylesheet and meson setup dies. Link the ISO's working catalog
    # (/var/lib/xml/catalog -> /Data/Variable/lib/xml/catalog). Idempotent.
    { mkdir -p /System/Settings/xml; } &&
    { test -e /System/Settings/xml/catalog -o -L /System/Settings/xml/catalog ||
      ln -s /Data/Variable/lib/xml/catalog /System/Settings/xml/catalog; } &&
    # AppStream needs the libxml2 python bindings for its itstool translation
    # merge (ISO LibXML2 2.9.10 builds none). ensure_pyxml installs them into
    # the Python 3.11 tree and repackages Python (pattern of step_pycompat).
    ensure_pyxml &&
    compile LibYaml 0.2.5 && package LibYaml 0.2.5 &&
    # compile_keep: same-version rebuild (recipe now emits Xmlb-2.0.gir
    # for Fwupd's introspection build).
    compile_keep LibXmlb 0.3.29 && package LibXmlb 0.3.29 &&
    compile_keep AppStream 1.0.6 && package AppStream 1.0.6 &&
    # Vala must exist before the GTK4/desktop tier: libadwaita's vapi is
    # generated from its GIR via vapigen (valac --pkg appstream also needs the
    # AppStream vapi emitted above). Kept here because AppStream's gir/vapi
    # turns it into a flatpak-closure dep too.
    compile Vala 0.56.19 && package Vala 0.56.19 &&
    # Polkit must be built for flatpak's system helper: meson keeps
    # build_system_helper ON by default and hard-requires polkit-agent-1
    # (>= 0.98). Full polkitd is built (duktape available), session tracking
    # via elogind, authfw=shadow. polkitd runs as the pre-existing polkitd user.
    compile Polkit 126 && package Polkit 126 &&
    # ---- Flatpak backend chain (bottom-up) ----
    # Bubblewrap: unprivileged sandbox backend (needs libcap, ISO). Flatpak's
    # system_bubblewrap option is a STRING; pointing at this binary avoids the
    # [wrap-git] subproject (offline chroot).
    compile Bubblewrap 0.11.0 && package Bubblewrap 0.11.0 &&
    # LibGpg-Error rebuilds every run: its do_patch makes estream_t
    # unconditional so consumers (gpgme, libostree, flatpak) compile against
    # ISO-era libassuan 2.5.3 without defining GPGRT_ENABLE_ES_MACROS.
    rm -f "$B/Packages/LibGpg-Error--1.52--x86_64.tar.bz2" &&
    compile_keep LibGpg-Error 1.52 && package LibGpg-Error 1.52 &&
    compile Gpgme 1.24.0 && package Gpgme 1.24.0 &&
    # libostree uses curl (recipe --with-curl --without-soup{3}), so it does
    # NOT need the Pantheon libsoup3. ensure_libostree_curl first: any tarball
    # from before that recipe change still links libsoup-3.0 and would be kept
    # by packaged().
    ensure_libostree_curl &&
    compile LibOstree 2025.6 && package LibOstree 2025.6 &&
    # Flatpak's vendored variant-schema-compiler imports pyparsing; the ISO
    # Python has no such module and the chroot has no network, so install the
    # host-staged pure-python wheel (Recipes/Flatpak/1.16.2/) via pip offline.
    # Idempotent: skipped once 'import pyparsing' succeeds.
    { python3 -c 'import pyparsing' 2>/dev/null ||
      python3 -m pip install --no-index --no-deps \
        /Data/Compile/Recipes/Flatpak/1.16.2/pyparsing-3.3.2-py3-none-any.whl; } &&
    # Flatpak's subprojects/dbus-proxy is a [wrap-git] network clone too, so
    # system_dbus_proxy points at this 0.1.6 build instead.
    compile XDG-DBus-Proxy 0.1.6 && package XDG-DBus-Proxy 0.1.6 &&
    compile Flatpak 1.16.2 && package Flatpak 1.16.2
}

step_flatpak() {
    # Standalone Flatpak runtime (CLI + sandboxing), no Pantheon desktop.
    # The shared core above terminates with a working flatpak; nothing more.
    step_core
}

step_sddm() {
    # SDDM 0.20.0 display manager (native Wayland greeter) built standalone.
    #
    # Prerequisites that are NOT built here (they predate this step):
    #   Qt 5.15.2 migration   Programs/Qt/Current -> 5.15.2 (-DQt5_DIR pins it);
    #   wayland stack         xkbcommon.pc/XCB/etc. via the 'wayland' step;
    #   weston                runtime greeter compositor (CompositorCommand);
    #   elogind seat/session  from step_elogind_base (below), works desktop-free.
    step_sync &&
    step_elogind_base &&
    step_tools &&
    step_cmake &&
    compile Extra-CMake-Modules 5.115.0 && package Extra-CMake-Modules 5.115.0 &&
    compile SDDM 0.20.0 && package SDDM 0.20.0
}

step_pantheon() {
    # elementary OS 8 Pantheon desktop stack. Order is a topo sort of the
    # GNOME 48 foundation + session stack + elementary recipes; each recipe's
    # Resources/Dependencies is honored (Granite6/GTK3 before Granite7/GTK4
    # apps, Wingpanel before its indicators, Switchboard before its plugs,
    # Mutter after LibGudev, gsd after its deps). All session-stack packages
    # are pinned systemd=false (no libsystemd on the ISO).
    #
    # step_core builds the desktop-agnostic foundation (recipe sync + meson
    # tooling + GLib/GI/gdk-pixbuf/json-glib + elogind + the whole Flatpak
    # chain). Everything below is the Pantheon-specific stream: font stack,
    # GTK3/GTK4, Mesa/Mutter, session stack, elementary apps. To build only
    # the shared foundation (a working flatpak, no desktop) use `build.sh
    # flatpak`; the compile commands below are the desktop-only remainder.
    step_core &&
    if python3 -c "import mako" >/dev/null 2>&1
    then log "python-mako already present (Mesa build-time dep)"
    else log "Installing python-mako via Alien PIP (Mesa build-time dep)"
         Alien --install PIP:mako || return 1
    fi &&
    # HarfBuzz rebuilt WITH ICU: the first 11.4.0 build disabled it (the
    # "ISO doesn't ship ICU" assumption was wrong -- LibICU4C 65.1 provides
    # icu-uc/icu-i18n pcs). WebKit's FindHarfBuzz REQUIRED the ICU component;
    # pkg-config fell back to the stale ISO 2.6.4 harfbuzz-icu.pc and the
    # Generate step died HarfBuzz_ICU_INCLUDE_DIR-NOTFOUND. Same-version
    # rebuild: wipe the no-ICU tarball + compile_keep (recipe now
    # -Dicu=enabled).
    rm -f "$B/Packages/HarfBuzz--11.4.0--x86_64.tar.bz2" &&
    compile_keep HarfBuzz 11.4.0 && package HarfBuzz 11.4.0 &&
    compile Fribidi 1.0.16 && package Fribidi 1.0.16 &&
    compile FreeType 2.13.3 && package FreeType 2.13.3 &&
    compile Fontconfig 2.15.0 && package Fontconfig 2.15.0 &&
    compile Pixman 0.44.2 && package Pixman 0.44.2 &&
    compile Cairo 1.18.4 && package Cairo 1.18.4 &&
    # Pango rebuilt in place (--keep): a 1.56.1 tree already exists, so plain
    # compile's Pre_Installation_Preparation safe-copy dangles /usr/include/
    # pango-1.0 and meson install dies ENOENT (same as GTK+ 3.24.43). The
    # recipe now builds with introspection ENABLED so Pango 1.56.1 ships its
    # own girs (Pango-1.0.gir etc.) for GTK4's Gdk GIR step. Wipe the tarball
    # so the packaged() skip drops it.
    rm -f "$B/Packages/Pango--1.56.1--x86_64.tar.bz2" &&
    compile_keep Pango 1.56.1 && package Pango 1.56.1 &&
    # Rebuild Graphene in-place (--keep) with introspection ENABLED: GTK4's
    # Gsk GIR needs Graphene-1.0.gir (g-ir-scanner: "Couldn't find include
    # 'Graphene-1.0.gir'"). Wipe the tarball so the packaged() skip drops it.
    rm -f "$B/Packages/Graphene--1.10.8--x86_64.tar.bz2" &&
    compile_keep Graphene 1.10.8 && package Graphene 1.10.8 &&
    compile LCMS2 2.19.1 && package LCMS2 2.19.1 &&
    if python3 -c "import jinja2" >/dev/null 2>&1
    then log "python-jinja2 already present (Libei build-time dep)"
    else log "Installing python-jinja2 via Alien PIP (Libei build-time dep)"
         Alien --install PIP:jinja2 || return 1
    fi &&
    # Libei 1.3.901 must ship libeis-1.0 (Mutter 48 hard-depends on it); the
    # original recipe disabled libeis. If the packaged tree lacks the EIS pc
    # file, wipe the stale tarball + program tree so it rebuilds with the
    # fixed recipe (libeis needs only libutil). Idempotent.
    { if [ -f "$B/Packages/Libei--1.3.901--x86_64.tar.bz2" ] &&
          ! tar -tf "$B/Packages/Libei--1.3.901--x86_64.tar.bz2" 2>/dev/null | grep -q "libeis-1.0.pc"
      then
          log "Libei tarball lacks libeis-1.0.pc; wiping for rebuild with EIS enabled"
          rm -f "$B/Packages/Libei--1.3.901--x86_64.tar.bz2"
          { find /System/Index -type l -lname '/Programs/Libei*' -delete 2>/dev/null || :; }
          rm -rf /Programs/Libei/1.3.901 /Programs/Libei/1.3.901-failed
      fi; } &&
    compile Libei 1.3.901 && package Libei 1.3.901 &&
    compile HWData 0.410 && package HWData 0.410 &&
    compile Libdisplay-Info 0.3.0 && package Libdisplay-Info 0.3.0 &&
    compile GSettings-Desktop-Schemas 48.0 && package GSettings-Desktop-Schemas 48.0 &&
    compile Sysprof-Capture 48.0 && package Sysprof-Capture 48.0 &&
    # LibGudev MUST come BEFORE Libwacom: libwacom 2.16's meson.build does
    # `dependency('gudev-1.0')` unconditionally (no fallback, not gated by any
    # option), so gudev-1.0.pc must already be on /System/Index or its
    # meson setup dies. Build order here also honors Libgweather4/UPower/gsd,
    # which also pull LibGudev (built later).
    # Bump 237 -> 238: Mutter 48.7 does `dependency('gudev-1.0', '>= 238')`.
    # The 238 recipe's pre_build relaxes the libudev >= 251 pin to >= 243
    # (Eudev 3.2.9); all libudev API gudev uses exists in 243.
    { if [ -f "$B/Packages/LibGudev--237--x86_64.tar.bz2" ]
      then
          log "Wiping LibGudev 237 (Mutter needs gudev-1.0 >= 238)"
          rm -f "$B/Packages/LibGudev--237--x86_64.tar.bz2"
          { find /System/Index -type l -lname '/Programs/LibGudev*' -delete 2>/dev/null || :; }
          rm -rf /Programs/LibGudev/237 /Programs/LibGudev/237-failed
      fi; } &&
    ensure_libgudev_archive &&
    compile LibGudev 238 && package LibGudev 238 &&
    compile Libwacom 2.16.0 && package Libwacom 2.16.0 &&
    # LibEvdev must precede LibInput 1.31.3: its meson.build does
    # dependency('libevdev', version: '>= 1.10.0') unconditionally, and the
    # ISO's LibEvdev 1.9.0 is too old (libevdev.so.2 soname unchanged).
    compile LibEvdev 1.13.6 && package LibEvdev 1.13.6 &&
    compile LibInput 1.31.3 && package LibInput 1.31.3 &&
    # (Linux-Headers + PAM symlink + Elogind + its BootUp wiring live in
    # step_elogind_base, invoked from step_core above, since SDDM + Flatpak
    # need the same seat/session foundation.)
    compile LibGLVnd 1.7.0 && package LibGLVnd 1.7.0 &&
    compile LLVM 19.1.7 && package LLVM 19.1.7 &&
    # Mesa is built from the current recipe (no packaged() skip): the recipe
    # can change driver scope (e.g. the virtio gallium driver for the QEMU/KVM
    # build VM), and there's no recipe-hash tracking in the compile stack --
    # packaged() only checks the tarball's existence, so an edited recipe would
    # otherwise orphan a stale build. Drop the tarball and rebuild IN PLACE via
    # compile_keep (--keep). Do NOT rm -rf the program tree: that leaves no
    # /System/Index/lib/dri, so mesa's sandboxed install tries to create it
    # fresh in the UnionSandbox overlay and reliably dies ENOENT during the
    # libdril_dri.so copy. Keeping the existing tree lets Pre_Installation_
    # Preparation/--keep relocate the prior lib/dri, and install succeeds.
    rm -f "$B/Packages/Mesa--25.3.6--x86_64.tar.bz2" &&
    compile_keep Mesa 25.3.6 && package Mesa 25.3.6 &&
    compile LibPipewire 1.4.0 && package LibPipewire 1.4.0 &&
    compile LibCanberra 0.30 && package LibCanberra 0.30 &&
    # (LibGudev built earlier — see comment above the Libwacom compile.)
    # GUsb must precede Colord: colord 1.4.8's meson.build does
    # `dependency('gusb', version: '>= 0.2.7')` unconditionally (daemon's
    # colorimeter sensors link it), so gusb-1.0.pc must be on the index.
    # compile_keep: same-version rebuild over an installed tree (plain
    # compile dangles safelinked index entries). Recipe now emits
    # GUsb-1.0.gir/vapi for Fwupd's introspection build.
    compile_keep GUsb 0.4.9 && package GUsb 0.4.9 &&
    # Duktape must precede Polkit: polkit 126's embedded JS rules engine
    # (libpolkit-backend) does `dependency('duktape', version: '>= 2.2.0')`
    # when polkitd is built (libs-only=false). Provides libduktape.so + headers.
    # (Duktape + Polkit precede Colord — built in step_core above.)
    compile Colord 1.4.8 && package Colord 1.4.8 &&
    # GTK4 must precede Gnome-Desktop: gnome-desktop 44.5's meson.build does
    # `dependency('gtk4', required: get_option('build_gtk4'))` (default on,
    # the gnome-desktop-4 ABI), so gtk4.pc must be on the index.
    # 4.20.0 (not the ROADMAP's 4.18.6) because libadwaita 1.8.0 hard-requires
    # GTK >= 4.19.4; the 4.18.6 package tarball is dropped from Packages/.
    rm -f "$B/Packages/GTK4--4.18.6--x86_64.tar.bz2" &&
    # Rebuild 4.20.0 in-place (--keep) with introspection ENABLED: libadwaita
    # 1.8.0's GIR includes Gtk-4.0 (its vapi -- needed for valac's --pkg
    # libadwaita-1 -- is generated from that GIR). Wipe the tarball so the
    # packaged() skip doesn't leave the old one behind; the live tree stays.
    rm -f "$B/Packages/GTK4--4.20.0--x86_64.tar.bz2" &&
    compile_keep GTK4 4.20.0 && package GTK4 4.20.0 &&
    # IsoCodes must precede Gnome-Desktop: its meson.build does
    # dependency('iso-codes') unconditionally and reads its prefix var to
    # define ISO_CODES_PREFIX.
    compile IsoCodes 4.17.0 && package IsoCodes 4.17.0 &&
    # (LibSeccomp must precede Gnome-Desktop — built in step_core above.)
    # ATK 2.36.0 + GTK+ 3.24.43 must precede EVERY gtk+-3.0 consumer (the first
    # is Gnome-Desktop below): the ISO's atk.pc is 2.34.1, which fails GTK+'s
    # `atk >= 2.35.1` check, so meson falls back to the bundled atk subproject
    # and stringifies its internal dep as `dep<id>` into the generated
    # gtk+-3.0.pc `Requires:` line — poisoning every downstream pkg-config
    # lookup. Built here (before any consumer) so the index always holds a clean
    # 3.24.43 pc; ATK 2.36.0 (final standalone ATK, meson) satisfies the gate.
    # GTK+ 3.24.43 also provides gdk-wayland-3.0.pc (Wingpanel 8.0.4
    # hard-requires it; the ISO's x11-only 3.24.13 does not). Both only need the
    # base (GLib/Pango/GdkPixbuf/cairo/epoxy/wayland/gobject-introspection),
    # already built above. package merges GTK+ over the ISO's 3.24.13.
    # GTK+ is compiled --keep (compile_keep): a 3.24.43 tree already exists
    # from an earlier run, and a plain re-compile would trigger
    # Pre_Installation_Preparation's safe-copy, which dangles the index's
    # /usr/include/gtk-3.0 symlink and makes meson install die with ENOENT on
    # gdkenumtypes.h. --keep overlays the fresh (clean-pc) install onto the
    # existing tree; the package tarball was dropped so this runs.
    compile ATK 2.36.0 && package ATK 2.36.0 &&
    compile_keep GTK+ 3.24.43 && package GTK+ 3.24.43 &&
    ensure_gnome_desktop_legacy &&
    compile Gnome-Desktop 44.5 && package Gnome-Desktop 44.5 &&
    # (AppStream + LibYaml + LibXmlb + ensure_pyxml + /etc/xml/catalog + Vala
    # all live in step_core above — LibAdwaita consumes those from the index.)
    # Rebuild LibAdwaita in-place (--keep) with introspection + vapi ENABLED:
    # the original build shipped no GIR/vapi (valac: "Package `libadwaita-1'
    # not found"). The GIR includes Gtk-4.0 (GTK4 rebuilt with introspection
    # above); generate_vapi needs vapigen (Vala, built just before).
    rm -f "$B/Packages/LibAdwaita--1.8.0--x86_64.tar.bz2" &&
    compile_keep LibAdwaita 1.8.0 && package LibAdwaita 1.8.0 &&
    # ISO libX11 1.6.9 < Mutter's required 1.7.0; build a current one.
    ensure_libx11_archive &&
    compile LibX11 1.8.13 && package LibX11 1.8.13 &&
    # ISO libXfixes 5.0.3 < Mutter's required 6; build a current one.
    ensure_libxfixes_archive &&
    compile LibXfixes 6.0.1 && package LibXfixes 6.0.1 &&
    compile Mutter 48.7 && package Mutter 48.7 &&
    compile LibNghttp2 1.70.0 && package LibNghttp2 1.70.0 &&
    compile_keep Libsoup3 3.6.6 && package Libsoup3 3.6.6 &&
    compile GweatherLocations 2026.2 && package GweatherLocations 2026.2 &&
    compile Gcr3 3.41.2 && package Gcr3 3.41.2 &&
    compile GeocodeGlib 3.26.4 && package GeocodeGlib 3.26.4 &&
    compile Libgweather4 4.6.0 && package Libgweather4 4.6.0 &&
    compile Geoclue 2.8.1 && package Geoclue 2.8.1 &&
    compile UPower 1.90.9 && package UPower 1.90.9 &&
    compile GnomeKeyring 48.0 && package GnomeKeyring 48.0 &&
    compile GnomeSettingsDaemon 48.1 && package GnomeSettingsDaemon 48.1 &&
    compile GnomeSession 45.0 && package GnomeSession 45.0 &&
    compile DesktopFileUtils 0.27 && package DesktopFileUtils 0.27 &&
    compile SessionSettings 8.1.0 && package SessionSettings 8.1.0 &&
    compile ElementaryIconTheme 8.2.0 && package ElementaryIconTheme 8.2.0 &&
    compile ElementaryWallpapers 8.0.0 && package ElementaryWallpapers 8.0.0 &&
    compile GtkThemeElementary 8.2.2 && package GtkThemeElementary 8.2.2 &&
    compile SoundThemeElementary 1.1.0 && package SoundThemeElementary 1.1.0 &&
    # Libgee must precede every Vala-based elementary app (Contractor,
    # Granite6/7, Libhandy, Calculator, ...): their meson.build calls
    # `add_languages('vala')` / dependency('gee-0.8') at setup time. Libgee
    # 0.20.8 is plain autotools. (Vala itself is built earlier, before
    # LibAdwaita, so libadwaita's vapi can be generated.)
    compile Libgee 0.20.8 && package Libgee 0.20.8 &&
    compile Contractor 0.3.5 && package Contractor 0.3.5 &&
    compile Granite 6.2.0 && package Granite 6.2.0 &&
    # Granite7 (GTK4 lib) must precede every Granite7 app: PantheonCalculator's
    # src/meson.build does dependency('granite-7') unconditionally.
    compile Granite7 7.8.1 && package Granite7 7.8.1 &&
    compile_keep Libhandy 1.8.3 && package Libhandy 1.8.3 &&
    compile PantheonCalculator 8.0.1 && package PantheonCalculator 8.0.1 &&
    compile PantheonDefaultSettings 8.1.1 && package PantheonDefaultSettings 8.1.1 &&
    compile PantheonNotifications 8.1.2 && package PantheonNotifications 8.1.2 &&
    compile PantheonWayland 1.1.0 && package PantheonWayland 1.1.0 &&
    # ----- New middleware for the kept apps (Core + Media + Flatpak scope) -----
    # LightdmPantheonGreeter stays DROPPED: it needs liblightdm-gobject-1 (no
    # LightDM on the ISO; the DM is SDDM with its own QML greeter).
    # GTK+ 3.24.43 + ATK are built EARLY (foundation, right before Gnome-Desktop)
    # — see the comment up there. GStreamer core + plugins-base: PantheonMusic/
    # Videos/Camera link gstreamer-1.0, gstreamer-pbutils/-tag/-video (pcs from
    # core + plugins-base).
    compile GStreamer 1.26.1 && package GStreamer 1.26.1 &&
    compile Gst-Plugins-Base 1.26.1 && package Gst-Plugins-Base 1.26.1 &&
    # Gst-Plugins-Good + Gst-LibAV: playback codecs so the desktop ISO can
    # actually PLAY media (MP3/FLAC/WAV via good; H.264/AAC/MPEG/VP8/VP9/WebM
    # via gst-libav against the ISO's FFmpeg 4.2.2).
    compile Gst-Plugins-Good 1.26.1 && package Gst-Plugins-Good 1.26.1 &&
    compile Gst-LibAV 1.26.1 && package Gst-LibAV 1.26.1 &&
    # VTE (gtk4): PantheonTerminal 8.1.0 (dependency('vte-2.91-gtk4')).
    compile VTE 0.80.1 && package VTE 0.80.1 &&
    # libportal: PantheonScreenshot (libportal-gtk4) + PantheonFiles (libportal-gtk3).
    compile LibPortal 0.9.0 && package LibPortal 0.9.0 &&
    # Gcr4: PantheonPolkitAgent 8.1.0 (dependency('gcr-4')); gcr3 only ships
    # gcr-base-3/gcr-3 pcs (GTK3-era), the agent is gtk4-era.
    compile Gcr4 4.3.1 && package Gcr4 4.3.1 &&
    # (Flatpak + Gpgme + LibOstree + LibGpg-Error all live in step_core above —
    # the index already holds flatpak-interfaces.pc + the dbus-proxy binary.)
    # xdg-desktop-portal daemon + GTK backend: needed at runtime by libportal
    # apps (Screenshot/Files) and any Flatpak app. Uses flatpak's
    # flatpak-interfaces pc (step_core) and LibPipewire for the screencast
    # portal. Deliberately EXCLUDED from step_flatpak (CLI+runtime closure;
    # portals are desktop scope only).
    compile XDG-Desktop-Portal 1.22.1 && package XDG-Desktop-Portal 1.22.1 &&
    compile XDG-Desktop-Portal-GTK 1.15.3 && package XDG-Desktop-Portal-GTK 1.15.3 &&
    # ----- Restored apps: dependency tiers (full desktop scope) -----
    # Order is a topo sort: each tier only needs things built before it. The
    # restored apps (Calendar/Mail/Tasks/Code/Photos/SettingsDaemon/CapnetAssist)
    # are compiled further down in the apps block.
    #
    # Code tier: LibGit2 -> LibGit2-Glib, then GtkSourceView + LibPeas (all
    # independent of each other; Code links all four + VTE's GTK3 vte-2.91.pc,
    # which the dual-backend VTE build above now provides).
    # Pinned to LibGit2 1.7.2: 1.8.x moved git_error_set_str into
    # git2/sys/errors.h (not included by git2.h), breaking LibGit2-Glib 1.2.0's
    # LIBGIT2_VER_MAJOR>0 branch. Wipe the 1.8.4 tree + tarball so the index
    # refresh resolves git2.h to 1.7.2 (the only remaining candidate).
    rm -f "$B/Packages/LibGit2--1.8.4--x86_64.tar.bz2" &&
    rm -rf /Programs/LibGit2/1.8.4 &&
    # First 1.7.2 build ran with its cmake options silently dropped (the
    # recipe wrongly used configure_options; the cmake build type reads
    # cmake_options), yielding a no-HTTPS, non-Release lib. Now that the array
    # is fixed, wipe + rebuild so USE_HTTPS=OpenSSL + Release actually apply.
    # Same-version rebuild via compile_keep (plain recompile dangles index
    # symlinks); headers unchanged, so LibGit2-Glib stays as-is.
    rm -f "$B/Packages/LibGit2--1.7.2--x86_64.tar.bz2" &&
    compile_keep LibGit2 1.7.2 && package LibGit2 1.7.2 &&
    compile LibGit2-Glib 1.2.0 && package LibGit2-Glib 1.2.0 &&
    compile GtkSourceView 4.8.4 && package GtkSourceView 4.8.4 &&
    compile LibPeas 2.0.4 && package LibPeas 2.0.4 &&
    # Webkit tier: Ruby (JSC codegen; WebKitCommon.cmake requires the
    # interpreter >= 2.5) + LibHyphen (FindHyphen via /usr->Index) + Unifdef
    # (find_program on PATH) are hard deps of both webkit builds. WebKitGTK
    # 2.46.5 builds ONE API per port (USE_GTK4 either/or), so the GTK3 4.1
    # build (PantheonMail) and the GTK4 6.0 build (PantheonCapnetAssist) are
    # separate program trees sharing the same tarball. libwpe/wpebackend-fdo
    # are NOT needed by the 2.46 GTK port. GStreamer 1.26 + plugins-base
    # (built above) give webkit its media stack.
    compile Ruby 3.3.12 && package Ruby 3.3.12 &&
    compile LibHyphen 2.8.8 && package LibHyphen 2.8.8 &&
    compile Unifdef 2.12 && package Unifdef 2.12 &&
    compile WebKit2GTK 2.46.5 && package WebKit2GTK 2.46.5 &&
    compile WebKitGTK 2.46.5 && package WebKitGTK 2.46.5 &&
    # EDS/clutter tier: LibIcal 3.0.x (libical-glib >= 3.0.7 for EDS) ->
    # Cogl -> Clutter -> ClutterGtk -> LibChamplain; then
    # EvolutionDataServer -> Folks (EDS addressbook backend).
    compile LibIcal 3.0.19 && package LibIcal 3.0.19 &&
    compile Cogl 1.22.8 && package Cogl 1.22.8 &&
    compile Clutter 1.26.4 && package Clutter 1.26.4 &&
    compile ClutterGtk 1.8.4 && package ClutterGtk 1.8.4 &&
    compile LibChamplain 0.12.21 && package LibChamplain 0.12.21 &&
    compile EvolutionDataServer 3.54.3 && package EvolutionDataServer 3.54.3 &&
    compile_keep Folks 0.15.9 && package Folks 0.15.9 &&
    # Photos tier: LibExif first (LibGphoto2 links it), Exiv2 -> GExiv2
    # (gexiv2-0.16 dependency falls back to gexiv2.pc). LibRaw standalone.
    compile LibExif 0.6.24 && package LibExif 0.6.24 &&
    compile LibRaw 0.21.3 && package LibRaw 0.21.3 &&
    compile Exiv2 0.28.5 && package Exiv2 0.28.5 &&
    compile LibGphoto2 2.5.31 && package LibGphoto2 2.5.31 &&
    compile GExiv2 0.14.3 && package GExiv2 0.14.3 &&
    # SettingsDaemon tier: Jansson -> PackageKit; LibJcat (needs gpgme from
    # the flatpak chain) -> Fwupd (needs xmlb >= 0.3.6, already built as
    # LibXmlb 0.3.29 for AppStream, and jcat).
    compile Jansson 2.14 && package Jansson 2.14 &&
    # compile_keep: same-version rebuild over installed tree. Recipe now
    # emits Pk-1.0.gir + packagekit-glib2.vapi (SettingsDaemon needs the
    # 1.2.x-era details_with_deps_size property).
    compile_keep PackageKit 1.3.6 && package PackageKit 1.3.6 &&
    compile LibJcat 0.2.3 && package LibJcat 0.2.3 &&
    # Fwupd is already installed+indexed (Aug 20); a plain `compile` re-runs
    # Pre_Installation_Preparation, whose safelinking repoint sends meson's
    # policy install into non-rw sandbox space -> ENOENT (see compile_keep).
    compile_keep Fwupd 1.9.27 && package Fwupd 1.9.27 &&
    # ----- Kept apps (see pantheon-recipes.md) -----
    compile PantheonFiles 7.3.2 && package PantheonFiles 7.3.2 &&
    compile PantheonGeoclue2Agent 1.0.6 && package PantheonGeoclue2Agent 1.0.6 &&
    compile PantheonSideload 6.3.1 && package PantheonSideload 6.3.1 &&
    compile PantheonVideos 8.0.2 && package PantheonVideos 8.0.2 &&
    # ----- Restored apps (full desktop scope; all deps built above) -----
    # Calendar/Tasks need EDS (libecal-2.0 >= 3.46), champlain+clutter (map
    # picker), folks; Mail needs EDS + webkit2gtk-4.1; Code needs gtksourceview
    # + libpeas + libgit2-glib + vte-2.91; Photos needs gexiv2 + gstreamer +
    # libgphoto2 + libraw + libexif + libportal-gtk3; SettingsDaemon needs
    # fwupd + packagekit-glib2 + gexiv2; CapnetAssist needs webkitgtk-6.0 +
    # gcr-4. None of them depend on each other, so they sit together here.
    compile PantheonCalendar 8.0.2 && package PantheonCalendar 8.0.2 &&
    compile PantheonMail 8.0.1 && package PantheonMail 8.0.1 &&
    compile PantheonTasks 6.3.3 && package PantheonTasks 6.3.3 &&
    compile PantheonCode 8.3.2 && package PantheonCode 8.3.2 &&
    compile PantheonPhotos 8.0.2 && package PantheonPhotos 8.0.2 &&
    compile PantheonSettingsDaemon 8.5.0 && package PantheonSettingsDaemon 8.5.0 &&
    compile CapnetAssist 8.0.2 && package CapnetAssist 8.0.2 &&
    # Gala before Wingpanel: wingpanel-interface/meson.build does
    # dependency('gala') unconditionally.
    compile Gala 8.5.1 && package Gala 8.5.1 &&
    compile Wingpanel 8.0.4 && package Wingpanel 8.0.4 &&
    compile PantheonCamera 8.0.2 && package PantheonCamera 8.0.2 &&
    compile PantheonMusic 8.1.0 && package PantheonMusic 8.1.0 &&
    compile PantheonOnboarding 8.1.0 && package PantheonOnboarding 8.1.0 &&
    compile PantheonPolkitAgent 8.1.0 && package PantheonPolkitAgent 8.1.0 &&
    compile PantheonScreenshot 8.0.4 && package PantheonScreenshot 8.0.4 &&
    compile PantheonShortcutOverlay 8.1.0 && package PantheonShortcutOverlay 8.1.0 &&
    compile PantheonTerminal 8.1.0 && package PantheonTerminal 8.1.0 &&
    # Support libs for indicators/plugs (audit Aug 22; see PROGRESS.md):
    # dconf -> IBus (keyboard indicator + keyboard/locale plugs);
    # Accountsservice w/ elogind (session indicator, locale plug);
    # LibGTop (power indicator, About plug); LibBlockDev+UDisks2 (About);
    # Cups (Printers plug). Dropped for sysvinit ISO: network indicator/plug
    # (needs NetworkManager), ParentalControls (hard-requires systemd),
    # SecurityPrivacy (zeitgeist, dead upstream).
    compile Dconf 0.40.0 && package Dconf 0.40.0 &&
    compile IBus 1.5.29 && package IBus 1.5.29 &&
    compile Accountsservice 23.13.9 && package Accountsservice 23.13.9 &&
    compile LibGTop 2.41.1 && package LibGTop 2.41.1 &&
    compile LibBlockDev 3.1.1 && package LibBlockDev 3.1.1 &&
    compile UDisks2 2.10.1 && package UDisks2 2.10.1 &&
    compile Cups 2.4.12 && package Cups 2.4.12 &&
    compile Switchboard 8.0.3 && package Switchboard 8.0.3 &&
    compile PantheonApplicationsMenu 8.0.4 && package PantheonApplicationsMenu 8.0.4 &&
    compile WingpanelIndicatorA11y 1.0.2 && package WingpanelIndicatorA11y 1.0.2 &&
    compile WingpanelIndicatorBluetooth 8.0.0 && package WingpanelIndicatorBluetooth 8.0.0 &&
    compile WingpanelIndicatorDatetime 2.4.2 && package WingpanelIndicatorDatetime 2.4.2 &&
    compile WingpanelIndicatorKeyboard 2.4.2 && package WingpanelIndicatorKeyboard 2.4.2 &&
    compile WingpanelIndicatorNightlight 2.1.3 && package WingpanelIndicatorNightlight 2.1.3 &&
    compile WingpanelIndicatorNotifications 7.1.1 && package WingpanelIndicatorNotifications 7.1.1 &&
    compile WingpanelIndicatorPower 8.0.2 && package WingpanelIndicatorPower 8.0.2 &&
    compile WingpanelIndicatorSession 2.3.1 && package WingpanelIndicatorSession 2.3.1 &&
    compile WingpanelIndicatorSound 8.0.3 && package WingpanelIndicatorSound 8.0.3 &&
    # Dock (io.elementary.dock): elementary 8's GTK4 dock, the replacement for
    # Plank in the secure session - without it the desktop boots panel-only.
    # It does dependency('gtk4-wayland')/('gtk4-x11'); our GTK4 build ships
    # those GIRs but not the thin wrapper vapis upstream installs from
    # gdk4-wayland/gdk4-x11 sources. A working pair already lives in the
    # VERSIONED vapidir (base image, Aug 14); valac finds it there, so only
    # generate when genuinely absent. Regenerating is a LAST resort - against
    # the post-rebuild Gio-2.0.gir, vapigen 0.56 dies on known gio metadata
    # gaps (SimpleAction overrides, async out-params, stacked arrays).
    # NOTE: the whole block is one chained compound (`if ... fi &&`) so an
    # earlier chain failure still skips it, and its failure breaks the chain
    # instead of silently producing a panel-only desktop.
    gtk4_vapidir="$(pkg-config --variable=vapidir_versioned vapigen 2>/dev/null)"
    case "$gtk4_vapidir" in
        /*) ;;
        *) gtk4_vapidir=/usr/share/vala-0.56/vapi ;;
    esac
    if [ ! -f "$gtk4_vapidir/gtk4-wayland.vapi" ]; then
        log ">>> Generating gtk4-wayland / gtk4-x11 vapis into $gtk4_vapidir"
        mkdir -p "$gtk4_vapidir"
        gtk4_vapis_ok=1
        for pair in gtk4-wayland:GdkWayland-4.0 gtk4-x11:GdkX11-4.0; do
            vapi="${pair%%:*}"; gir="${pair##*:}"
            # vapigen has no -o; --library writes <name>.vapi into --directory
            if ! vapigen --library="$vapi" --directory="$gtk4_vapidir" \
                    --girdir=/System/Index/share/gir-1.0 \
                    "/System/Index/share/gir-1.0/$gir.gir"; then
                log "FAILED: vapigen $vapi"
                gtk4_vapis_ok=0
                break
            fi
            echo gtk4 > "$gtk4_vapidir/$vapi.deps"
        done
        [ "$gtk4_vapis_ok" = 1 ]
    fi &&
    compile Dock 8.3.3 && package Dock 8.3.3 &&
    compile SwitchboardPlugAbout 8.2.3 && package SwitchboardPlugAbout 8.2.3 &&
    compile SwitchboardPlugApplications 8.3.0 && package SwitchboardPlugApplications 8.3.0 &&
    compile SwitchboardPlugBluetooth 8.0.2 && package SwitchboardPlugBluetooth 8.0.2 &&
    compile SwitchboardPlugDatetime 8.1.0 && package SwitchboardPlugDatetime 8.1.0 &&
    compile SwitchboardPlugDesktop 8.3.0 && package SwitchboardPlugDesktop 8.3.0 &&
    compile SwitchboardPlugDisplay 8.0.3 && package SwitchboardPlugDisplay 8.0.3 &&
    compile SwitchboardPlugKeyboard 8.1.1 && package SwitchboardPlugKeyboard 8.1.1 &&
    compile SwitchboardPlugLocale 8.0.3 && package SwitchboardPlugLocale 8.0.3 &&
    compile SwitchboardPlugMouseTouchpad 8.1.0 && package SwitchboardPlugMouseTouchpad 8.1.0 &&
    compile SwitchboardPlugNotifications 8.0.1 && package SwitchboardPlugNotifications 8.0.1 &&
    # SwitchboardPlugOnlineAccounts DROPPED: needs libgoa-1.0.pc (no gnome-online-accounts).
    # SwitchboardPlugNetwork/WingpanelIndicatorNetwork DROPPED: NetworkManager stack.
    # SwitchboardPlugParentalControls DROPPED: hard dependency('systemd').
    # SwitchboardPlugSecurityPrivacy DROPPED: zeitgeist-2.0 (unmaintained).
    compile SwitchboardPlugPower 8.1.0 && package SwitchboardPlugPower 8.1.0 &&
    compile SwitchboardPlugPrinters 8.0.2 && package SwitchboardPlugPrinters 8.0.2 &&
    compile SwitchboardPlugSharing 8.0.3 && package SwitchboardPlugSharing 8.0.3 &&
    compile SwitchboardPlugSound 8.0.3 && package SwitchboardPlugSound 8.0.3 &&
    compile SwitchboardPlugWacom 8.0.2 && package SwitchboardPlugWacom 8.0.2
}

step_webkit() {
    # Fast-path: when BOTH the installed tree and the published tarball carry
    # the introspection typelib, WebKit2GTK is already built AND packaged (a
    # fresh compile is a multi-hour job) -- nothing to do.
    if [ -f /Programs/WebKit2GTK/2.46.5/lib/girepository-1.0/WebKit2-4.1.typelib ] &&
       { tar -tjf "$B/Packages/WebKit2GTK--2.46.5--x86_64.tar.bz2" 2>/dev/null |
         grep -q 'lib/girepository-1.0/WebKit2-4.1.typelib'; }
    then
        log "SKIP: WebKit2GTK 2.46.5 already installed AND packaged (typelib present)"
        return 0
    fi
    # Standalone WebKit2GTK 2.46.5 (GTK3 API 4.1) for the Gaming/Lutris stack.
    # Lutris' WebConnectDialog (service logins: Steam/Epic/GOG/itch/...)
    # drives a GTK3 WebView through PyGObject:
    #     gi.require_version("WebKit2", "4.1"); from gi.repository import WebKit2
    # so this step ships the webkit2gtk-4.1 engine WITH introspection ON (the
    # WebKit2-4.1.typelib). No Pantheon session stack, GTK4, Mutter, Mesa or
    # elementary apps -- only the desktop-agnostic deps the web tier needs.
    #
    # Structure:
    #  - step_core builds the shared foundation (GLib + gobject-introspection,
    #    GdkPixbuf, JSON-GLib, elogind, LibSeccomp, Bubblewrap, the Flatpak
    #    chain).
    #  - This step owns its recipes the way step_proton owns GE-Proton: the
    #    canonical WebKit2GTK comes from Recipes/WebKit/ (introspection build),
    #    the dependency recipes are copied in from Recipes/Pantheon/ (they are
    #    not otherwise synced into a Plasma-only chroot).
    #  - Same-version rebuilds use compile_keep (--keep), which skips
    #    Pre_Installation_Preparation: its per-file index relink would dangle
    #    the /usr/include/<pkg> directory symlinks under a live install and
    #    make meson install die with ENOENT. Feature guards wipe the tarball
    #    only when the PUBLISHED artifact lacks what WebKit needs (harfbuzz
    #    ICU pc, Pango gir), so repeated runs do not needlessly rebuild.
    #
    # Order mirrors step_pantheon's webkit tier (which built with this exact
    # set): font stack -> GTK3 -> soup3 -> gstreamer -> build tools -> webkit.
    step_core &&
    step_cmake &&
    # ---- recipe sync: canonical sources for THIS step ----
    { rm -rf Recipes/WebKit2GTK &&
      cp -a /mnt/repo/Recipes/WebKit/WebKit2GTK Recipes/WebKit2GTK; } &&
    { for r in HarfBuzz Fribidi FreeType Fontconfig Pixman Cairo Pango LCMS2 \
               ATK GTK+ LibNghttp2 Libsoup3 GStreamer Gst-Plugins-Base \
               Ruby LibHyphen Unifdef
      do
          rm -rf "Recipes/$r"
          cp -a "/mnt/repo/Recipes/Pantheon/$r" "Recipes/$r" || return 1
      done; } &&
    # ---- font/text stack (newer than the ISO's for webkit's version gates) --
    # HarfBuzz: WebKit's FindHarfBuzz hard-REQUIREDs the ICU component
    # (HarfBuzz::ICU), so publish a build with harfbuzz-icu.pc.
    { tar -tjf "$B/Packages/HarfBuzz--11.4.0--x86_64.tar.bz2" 2>/dev/null |
        grep -q 'lib/pkgconfig/harfbuzz-icu.pc' ||
      rm -f "$B/Packages/HarfBuzz--11.4.0--x86_64.tar.bz2"; } &&
    compile_keep HarfBuzz 11.4.0 && package HarfBuzz 11.4.0 &&
    compile Fribidi 1.0.16 && package Fribidi 1.0.16 &&
    compile FreeType 2.13.3 && package FreeType 2.13.3 &&
    compile Fontconfig 2.15.0 && package Fontconfig 2.15.0 &&
    compile Pixman 0.44.2 && package Pixman 0.44.2 &&
    compile Cairo 1.18.4 && package Cairo 1.18.4 &&
    # Pango: must ship its own Pango-1.0.gir/PangoCairo-1.0.gir (GTK+ 3.24.43's
    # introspection emits Gtk-3.0.gir including them).
    { tar -tjf "$B/Packages/Pango--1.56.1--x86_64.tar.bz2" 2>/dev/null |
        grep -q 'share/gir-1.0/Pango-1.0.gir' ||
      rm -f "$B/Packages/Pango--1.56.1--x86_64.tar.bz2"; } &&
    compile_keep Pango 1.56.1 && package Pango 1.56.1 &&
    compile LCMS2 2.19.1 && package LCMS2 2.19.1 &&
    # ---- GTK 3.24.43 (wayland+x11; needs atk >= 2.35.1; ISO's 2.34.1 would
    # poison gtk+-3.0.pc via the bundled atk subproject) ----
    compile ATK 2.36.0 && package ATK 2.36.0 &&
    compile_keep GTK+ 3.24.43 && package GTK+ 3.24.43 &&
    # ---- HTTP stack: libsoup3 on nghttp2 (TLS via glib-networking at
    # runtime -- HTTPS login pages need the Gio TLS backend on the ISO) ----
    compile LibNghttp2 1.70.0 && package LibNghttp2 1.70.0 &&
    compile_keep Libsoup3 3.6.6 && package Libsoup3 3.6.6 &&
    # ---- media stack: GStreamer core + plugins-base (WebKitWebProcess' audio/
    # video pipeline; ISO has no gstreamer) ----
    compile GStreamer 1.26.1 && package GStreamer 1.26.1 &&
    compile Gst-Plugins-Base 1.26.1 && package Gst-Plugins-Base 1.26.1 &&
    # ---- JSC build tools (release tarball ships generated parse.c, so no
    # bison/gperf) ----
    compile Ruby 3.3.12 && package Ruby 3.3.12 &&
    compile LibHyphen 2.8.8 && package LibHyphen 2.8.8 &&
    compile Unifdef 2.12 && package Unifdef 2.12 &&
    # ---- WebKit2GTK 2.46.5 (GTK3 4.1, introspection ON) ----
    # Replace a stale no-typelib tarball/tree (e.g. from a Pantheon port
    # build) with the introspection build Lutris needs. Feature guard so an
    # already-correct package is kept instead of rebuilding WebKit (~hours).
    # Consider the guard satisfied when EITHER the installed tree OR the
    # published tarball carries the typelib -- do NOT wipe the installed tree
    # just because the tarball is missing, package() below CreatePackages it.
    { [ -f /Programs/WebKit2GTK/2.46.5/lib/girepository-1.0/WebKit2-4.1.typelib ] ||
      { tar -tjf "$B/Packages/WebKit2GTK--2.46.5--x86_64.tar.bz2" 2>/dev/null |
        grep -q 'lib/girepository-1.0/WebKit2-4.1.typelib'; } ||
      { rm -f "$B/Packages/WebKit2GTK--2.46.5--x86_64.tar.bz2"
        rm -rf /Programs/WebKit2GTK/2.46.5 /Programs/WebKit2GTK/2.46.5-failed
        { find /System/Index -type l -lname '/Programs/WebKit2GTK*' -delete 2>/dev/null || :; }
      }; } &&
    # WebKit's WebCore is the -j bear of this build: several translation units
    # (JSC/GC + WebCore platform files) routinely peak >2-3 GB RSS each, so
    # `make -j$(nproc)` can trip the OOM killer mid-WebCore at ~93%. Cap the
    # webkit arch make to ~2 GB RAM per job (the WebKit-CI heuristic); the
    # subshell keeps the build-wide MAKEFLAGS=-j$(nproc) untouched.
    ra_cap=$(awk '/MemTotal/ {print int($2/2097152)}' /proc/meminfo 2>/dev/null)
    [ -n "$ra_cap" ] && [ "$ra_cap" -gt 0 ] || ra_cap=$(nproc)
    log "webkit: capping make parallelism to -j${ra_cap} (RAM-based; default -j$(nproc))"
    ( export MAKEFLAGS="-j${ra_cap}"
      compile WebKit2GTK 2.46.5 ) &&
    package WebKit2GTK 2.46.5 &&
    if [ -f "/Programs/WebKit2GTK/2.46.5/lib/girepository-1.0/WebKit2-4.1.typelib" ]
    then log "OK: WebKit2-4.1.typelib present (PyGObject web connect ready)"
    else log "!! WebKit2GTK built but WebKit2-4.1.typelib MISSING (introspection failed)"
    fi
    # HTTPS login pages travel through Gio's TLS backend; on a Gobo ISO that is
    # Glib-Networking (GnuTLS). The base ISO is a full desktop, so this is
    # normally present; flag it so a bare/flatpak-only rebuild doesn't silently
    # ship a webkit that cannot load tls:// URLs.
    if [ -d /Programs/Glib-Networking ]
    then log "OK: glib-networking present (webkit HTTPS via Gio/GnuTLS)"
    else log "!! glib-networking NOT on this tree: webkit HTTPS login pages may fail to load"
    fi
}

step_appimage() {
    # AppImage tooling. AppImageKit 13 ships the classic appimagetool writer
    # plus its runtimes/AppRuns (binary recipe of the official v13 x86_64
    # assets -- upstream tags are frozen/obsolete; newer appimagetools are the
    # Go rewrite). libappimage 1.0.0 provides the create/inspect/integrate C++
    # library + AppImageUpdate/AppImageExtract tools.
    #
    # RUNNING AppImages needs none of this: the ISO kernel FUSE + libfuse
    # (2.9.9/3.16.2) already execute them, with --appimage-extract as fallback.
    #
    # Build notes: AppImageKit is a plain binary install. libappimage's cmake
    # consumes system liblzma/libarchive (USE_SYSTEM_XZ/LIBARCHIVE=ON) but
    # bundles boost, squashfuse and xdg-utils-cxx via ExternalProject_Add, which
    # fetch at CONFIGURE time -> the chroot needs network + git + autotools.
    #
    # Compile's Find_Recipe matches recipe dirs case-insensitively (grep -i), so
    # a leftover lowercase 'libappimage' dir from an older run would alias the
    # renamed LibAppimage and make the recipe lookup fail. Purge both spellings.
    { rm -rf Recipes/AppImageKit Recipes/LibAppimage Recipes/libappimage &&
      cp -a /mnt/repo/Recipes/AppImage/AppImageKit Recipes/AppImageKit &&
      cp -a /mnt/repo/Recipes/AppImage/LibAppimage Recipes/LibAppimage; } &&
    compile AppImageKit 13 && package AppImageKit 13 &&
    compile LibAppimage 1.0.0 && package LibAppimage 1.0.0 &&
    if [ -x /Programs/AppImageKit/13/bin/appimagetool ]
    then log "OK: appimagetool ready (create/inspect/integrate AppImages)"
    else log "!! appimagetool not found after install"
    fi
}

step_fs() {
    # Filesystem tooling for the Live CD. XFS: the kernel driver is already
    # built in (CONFIG_XFS_FS=m in the Linux 7.1.5 config -- also in the
    # CachyOS 7.2.5 config), so XFSProgs 7.1.1
    # only adds mkfs.xfs/xfs_repair/xfs_db/... (xfs_scrub stays excluded).
    # Note: Gobo names it XFSProgs (cf. E2FSProgs), so the recipe dir is
    # capitalized.
    #
    # XFSProgs 7.1.1's configure has UNCONDITIONAL libinih + liburcu probes
    # (NOTE: not gated on --enable-scrub, unlike the libicu one). The shipped
    # tools never actually link either library, so LibInih (inih) and LibURCU
    # (userspace-rcu) are build-time-only deps -- compile them first so the
    # headers/libs land in the chroot /System/Index for the XFSProgs configure
    # run, but nothing on the ISO needs them at runtime.
    #
    # OpenZFS 2.4.4 compiles its userspace (zpool/zfs/zfsd/zdb) AND its kernel
    # modules against the exact kernel installed by the Linux package
    # (/Programs/Linux/Current/lib/modules/<release>/build), the same approach
    # as the Nvidia step -- so 'fs' must run AFTER 'linux'. The GitHub release
    # tarball ships no generated configure: its autogen.sh (autoreconf) needs
    # autoconf/automake/libtool on the build system.
{ rm -rf Recipes/XFSProgs Recipes/xfsprogs Recipes/OpenZFS Recipes/LibInih Recipes/LibURCU &&
       cp -a /mnt/repo/Recipes/Fs/XFSProgs Recipes/XFSProgs &&
       cp -a /mnt/repo/Recipes/Fs/OpenZFS Recipes/OpenZFS &&
       cp -a /mnt/repo/Recipes/Fs/LibInih Recipes/LibInih &&
       cp -a /mnt/repo/Recipes/Fs/LibURCU Recipes/LibURCU; } &&
     compile LibInih r62 && package LibInih r62 &&
     compile LibURCU 0.15.1 && package LibURCU 0.15.1 &&
     compile XFSProgs 7.1.1 && package XFSProgs 7.1.1 &&
     { if openzfs_modules_ok
       then if packaged OpenZFS 2.4.4
            then log "SKIP: OpenZFS 2.4.4 (tarball present, kernel modules verified)"
            else log "OpenZFS kernel modules present but tarball missing -> packaging installed tree"
                 package OpenZFS 2.4.4
            fi
       elif packaged OpenZFS 2.4.4
       then log "OpenZFS tarball present but zfs.ko missing for current kernel -> forcing rebuild"
            compile_forced OpenZFS 2.4.4 && package OpenZFS 2.4.4
       else compile OpenZFS 2.4.4 && package OpenZFS 2.4.4
       fi; } &&
     local krel kole
     krel=$(ls /Programs/Linux/Current/lib/modules 2>/dev/null | grep -vE '^(Current|Settings|Variable)$' | head -1)
     kole=$(find /Programs/Linux/Current/lib/modules/$krel -name 'zfs.ko*' 2>/dev/null | head -1)
     if [ -x /Programs/OpenZFS/2.4.4/sbin/zpool ] && [ -n "$kole" ]
     then log "OK: zpool/zfs present; $kole installed in kernel tree (release $krel)"
     else log "!! ZFS userspace or kernel module missing after install"
     fi
}

merge_qml_index() {
    # Gobo's SymlinkProgram only mirrors bin/sbin/lib/libexec/share/... dirs, so
    # the qt/ qml/ trees never appear under /System/Index. But ECMFindQmlModule
    # (used by KCMUtils, KDeclarative, Plasma, ...) resolves QT_INSTALL_QML to
    # /System/Index/qml and reads qmldir from THERE. Mirror every installed
    # program's qml/ tree into /System/Index/qml the same way SymlinkProgram
    # patches /System/Index/bin etc: per-entry symlinks, last-one-wins.
    #
    # RUNTIME note: plasmashell/kwin resolve the import path from the env
    # exports in apply-live-fixes.sh section 30
    # (QML_IMPORT_PATH=/System/Index/lib/qml) -- the LIVE tree is the
    # lib/qml one, NOT /System/Index/qml.  Mirror BOTH: the plain one keeps
    # in-chroot build tooling happy, the lib/ one feeds the running desktop.
    # (Section 30's module-level relink then repairs stub shadowing on top.)
    #
    # The legacy Qt5 QML tree (/Programs/Qt/<5.x>/qml, globbed before the Qt6
    # modules) would place its QtQuick/Controls.2, Extras, QtQml/Models.2
    # categories and QML plugins in the Index, where the Qt6 runtime rejects
    # them ("module ... is not installed", blank icons).  Skip it -- the Index
    # is a Qt6 tree.  Also mirror plugin symlinks (`-type l`) so module .so
    # entries whose program dir stores them as links are not silently dropped.
    [ -d /Programs ] || return 0
    for root in /System/Index/qml /System/Index/lib/qml; do
        mkdir -p "$root"
        for prog in /Programs/*/*/qml /Programs/*/*/lib/qml; do
            [ -d "$prog" ] || continue
            case "$prog" in /Programs/Qt/*/qml) continue ;; esac
            ( cd "$prog" && find . -mindepth 1 \( -type d -o -type f -o -type l \) -print0 ) | \
                while IFS= read -r -d "" p; do
                    p="${p#./}"
                    if [ -d "$prog/$p" ]; then
                        mkdir -p "$root/$p"
                    else
                        mkdir -p "$root/$(dirname "$p")" 2>/dev/null
                        ln -sfn "$prog/$p" "$root/$p"
                    fi
                done
        done
    done
}

step_plasma() {
    merge_qml_index
    # KDE Plasma 6.7 desktop stack (Qt 6.10 + KF 6.26 + Plasma 6.7 + Gear 26.08).
    # ALL recipes live in ONE flat dir (Recipes/Plasma6-core/), synced by the
    # glob loop in step_sync. Four build phases are tracked as ORDER here, not
    # as directories:
    #   Phase A - Qt 6.10 base (install to /Programs/Qt6/<ver>, NEVER
    #             Programs/Qt: the Qt5 SDDM/greeter closure must stay intact).
    #   Phase B - KDE Frameworks 6.26.0 (in upstream tier order).
    #   Phase D - Gear apps (Dolphin + Konsole): plain Qt6/KF6 consumers, NO
    #             Plasma deps - build right after Phase B certifies so the file
    #             manager + terminal land before the shell marathon.
    #   Phase C - Plasma 6.7.x desktop modules (topo: kwayland -> kdecoration ->
    #             kwin -> kdeclarative -> libplasma -> plasma-workspace ->
    #             plasma-desktop -> ... shell extras).
    #
    # Whole stack is systemd-FREE: link elogind, never libsystemd.
    step_core &&
    step_cmake &&
    # ---- Phase A: Qt 6.10 ---- qtbase FIRST, then the modules Plasma/KF6
    # actually consume. Qt 6.10 requires CMake >= 3.22 (chroot has 3.30.4)
    # + Ninja (both present). Install to /Programs/Qt6/<ver>.
    compile QtBase 6.10.3 && package QtBase 6.10.3 &&
    compile QtShaderTools 6.10.3 && package QtShaderTools 6.10.3 &&
    compile QtDeclarative 6.10.3 && package QtDeclarative 6.10.3 &&
    compile Qt5Compat 6.10.3 && package Qt5Compat 6.10.3 &&
    compile QtSVG 6.10.3 && package QtSVG 6.10.3 &&
    compile QtWayland 6.10.3 && package QtWayland 6.10.3 &&
    compile QtTools 6.10.3 && package QtTools 6.10.3 &&
    compile Qtimageformats 6.10.3 && package Qtimageformats 6.10.3 &&
    # qtmultimedia (no backend; Prison/plasma-workspace need the API libs only)
    compile QtMultimedia 6.10.3 && package QtMultimedia 6.10.3 &&
    # qtspeech: KF6 requires Qt6TextToSpeech (KTextWidgets/KTextEditor
    # find_package REQUIRED). No flite/speechdispatcher on the ISO; the module
    # builds standalone with only the mock engine plugin.
    compile QtTextToSpeech 6.10.3 && package QtTextToSpeech 6.10.3 &&
    # ---- Phase B: KDE Frameworks 6.26.0 (Tier 1 first) ----
    # KF6 6.26.0 frameworks require ECM >= 6.26.0 at configure time; the ISO's
    # 5.115.0 (Qt5/SDDM-era) is too old. Sibling version in the same program
    # flips Extra-CMake-Modules/Current so /System/Index/share/ECM is 6.26.0.
    compile Extra-CMake-Modules 6.26.0 && package Extra-CMake-Modules 6.26.0 &&
    # KF6 6.26 + Plasma 6.7.4 need recent wayland-protocols (kwindowsystem >=
    # 1.46, kwin >= 1.48) and the PlasmaWaylandProtocols config package at
    # configure time (kwindowsystem/kguiaddons do find_package(PlasmaWayland...))
    # wayland-protocols 1.49 generates enum headers with wayland-scanner; the
    # ISO's 1.23.1 DTD lacks 'frozen'. Build wayland 1.26.0 (scanner >= 1.24,
    # libwayland ABI unchanged) as a sibling first so /usr/bin/wayland-scanner
    # flips before the protocol headers are produced.
    compile Wayland 1.26.0 && package Wayland 1.26.0 &&
    compile Wayland-Protocols 1.49 && package Wayland-Protocols 1.49 &&
    compile Plasma-Wayland-Protocols 1.21.0 && package Plasma-Wayland-Protocols 1.21.0 &&
    compile KCoreAddons 6.26.0 && package KCoreAddons 6.26.0 &&
    compile KConfig 6.26.0 && package KConfig 6.26.0 &&
    compile KI18n 6.26.0 && package KI18n 6.26.0 &&
    compile KWidgetsAddons 6.26.0 && package KWidgetsAddons 6.26.0 &&
    compile KGuiAddons 6.26.0 && package KGuiAddons 6.26.0 &&
    compile KDBusAddons 6.26.0 && package KDBusAddons 6.26.0 &&
    compile KCrash 6.26.0 && package KCrash 6.26.0 &&
    compile KWindowSystem 6.26.0 && package KWindowSystem 6.26.0 &&
    compile Kirigami 6.26.0 && package Kirigami 6.26.0 &&
    # QQC2-Desktop-Style (KF6): the QtQuick.Controls 2 desktop style Plasma 6
    # themes QtQuick apps with. REQUIRED Qt6 Core/Quick/Gui/Widgets/
    # QuickControls2 + KF6 Config + KirigamiPlatform, so it lands right after
    # Kirigami; KF6IconThemes/ColorScheme + X11 are optional finds.
    compile QQC2-Desktop-Style 6.26.0 && package QQC2-Desktop-Style 6.26.0 &&
    # KSvg needs KF6ColorScheme (find_package(KF6 COMPONENTS ColorScheme));
    # KColorScheme is Tier 2 (needs only Config/GuiAddons/I18n, all built above),
    # so build it right before KSvg to keep the file manager + terminal early.
    compile KColorScheme 6.26.0 && package KColorScheme 6.26.0 &&
    compile KSvg 6.26.0 && package KSvg 6.26.0 &&
    compile KCodecs 6.26.0 && package KCodecs 6.26.0 &&
    compile KArchive 6.26.0 && package KArchive 6.26.0 &&
    compile Solid 6.26.0 && package Solid 6.26.0 &&
    # ---- Tier 2 KF6 (Tier 1 deps) ----
    compile KConfigWidgets 6.26.0 && package KConfigWidgets 6.26.0 &&
    compile KService 6.26.0 && package KService 6.26.0 &&
    compile KNotifications 6.26.0 && package KNotifications 6.26.0 &&
    compile KPackage 6.26.0 && package KPackage 6.26.0 &&
    compile KJobWidgets 6.26.0 && package KJobWidgets 6.26.0 &&
    # ---- Tier 2 KF6 (bottom-up for the KXmlGui/KTextEditor/KParts cluster) ----
    # KGlobalAccel is a KXmlGui REQUIRED component (USE_DBUS=ON on Linux); it
    # owns the kglobalacceld daemon too. Deps: Qt6 DBus/Gui/Widgets only.
    compile KGlobalAccel 6.26.0 && package KGlobalAccel 6.26.0 &&
    # Sonnet + KCompletion MUST precede KTextWidgets (both are plain REQUIRED
    # there), and KTextWidgets gets CheckDependencies-dragged into KXmlGui's
    # build, so every one of them sits above KXmlGui.
    # Hunspell is Sonnet's only spell backend on the ISO (aspell/hspell/voikko
    # absent); must be built and packaged before Sonnet so pkg-config finds it.
    compile Hunspell 1.7.2 && package Hunspell 1.7.2 &&
    compile Sonnet 6.26.0 && package Sonnet 6.26.0 &&
    compile KCompletion 6.26.0 && package KCompletion 6.26.0 &&
    compile KTextWidgets 6.26.0 && package KTextWidgets 6.26.0 &&
    # KIconThemes + KItemViews are also KXmlGui REQUIRED components (IconThemes
    # feeds KIO as well); deps (Breeze-Icons, Archive/ColorScheme/I18n/
    # WidgetsAddons, Qt6 Svg/DBus) all built above.
    compile Breeze-Icons 6.26.0 && package Breeze-Icons 6.26.0 &&
    compile KIconThemes 6.26.0 && package KIconThemes 6.26.0 &&
    compile KItemViews 6.26.0 && package KItemViews 6.26.0 &&
    compile KXmlGui 6.26.0 && package KXmlGui 6.26.0 &&
    compile KItemModels 6.26.0 && package KItemModels 6.26.0 &&
    compile KBookmarks 6.26.0 && package KBookmarks 6.26.0 &&
    compile KDocTools 6.26.0 && package KDocTools 6.26.0 &&
    compile KFileMetadata 6.26.0 && package KFileMetadata 6.26.0 &&
    compile KSyntaxHighlighting 6.26.0 && package KSyntaxHighlighting 6.26.0 &&
    # KIO at the END of the KF6 tiers: its full REQUIRED set (Service, Solid,
    # Bookmarks, ColorScheme, Completion, IconThemes, ItemViews, JobWidgets,
    # KNotifications, ...) now precedes it. KParts and KTextEditor both require
    # KF6Kio, so they come after; KTextEditor additionally needs KParts +
    # KF6Auth (ENABLE_KAUTH default ON). KAuth only needs Qt6 Gui/DBus +
    # KF6CoreAddons.
    compile KIO 6.26.0 && package KIO 6.26.0 &&
    compile KParts 6.26.0 && package KParts 6.26.0 &&
    compile KAuth 6.26.0 && package KAuth 6.26.0 &&
    compile KTextEditor 6.26.0 && package KTextEditor 6.26.0 &&
    compile KPTY 6.26.0 && package KPTY 6.26.0 &&
    # Dolphin's find_package(KF6 COMPONENTS KCMUtils NewStuff) pulls these two
    # into its closure, so build them before the Phase D file manager.
    compile KCMUtils 6.26.0 && package KCMUtils 6.26.0 &&
    # KNewStuff REQUIRES Attica + KPackage (both above/below); Attica is only
    # Qt6 Core/Network, so build it right here for KNewStuff's REQUIRED find.
    compile Attica 6.26.0 && package Attica 6.26.0 &&
    compile KNewStuff 6.26.0 && package KNewStuff 6.26.0 &&
    # ---- Phase D: Gear 26.08.0 (Dolphin + Konsole). Both are plain Qt6/KF6
    # consumers (no Plasma deps) needing the Tier 2 KF6 above (Dolphin: kio,
    # kparts, kfilemetadata, kitemviews, kconfigwidgets, kservice, kdoctools,
    # solid, kcompletion; Konsole: kconfigwidgets, ktexteditor, kpty, sonnet,
    # kservice). Build BEFORE the Tier 3 + Plasma shell marathon so the file
    # manager + terminal land early.
    compile Dolphin 26.08.0 && package Dolphin 26.08.0 &&
    # Konsole REQUIRES KF6NotifyConfig (not a recipe before today); deps are
    # Completion/Config/I18n/KIO + Qt6 Widgets/DBus/Multimedia, all built above.
    compile KNotifyConfig 6.26.0 && package KNotifyConfig 6.26.0 &&
    compile Konsole 26.08.0 && package Konsole 26.08.0 &&
    # ---- Tier 3 KF6 ----
    compile KRunner 6.26.0 && package KRunner 6.26.0 &&
    compile KStatusNotifierItem 6.26.0 && package KStatusNotifierItem 6.26.0 &&
    compile KDeclarative 6.26.0 && package KDeclarative 6.26.0 &&
    # ---- Tier 3.5 KF6 (frameworks Plasma 6.7.4 actually links against).
    # All 6.26.0; wiring mirrors the framework deps extracted from the release
    # tarballs (leaf-level first, KAuth/icon/KNewStuff trees later).
    compile KHolidays 6.26.0 && package KHolidays 6.26.0 &&
    compile KIdleTime 6.26.0 && package KIdleTime 6.26.0 &&
    compile KUserFeedback 6.26.0 && package KUserFeedback 6.26.0 &&
    # NetworkManager-Qt 6.26.0: Plasma-Workspace 6.7.4 hard-requires
    # KF6NetworkManagerQt on LINUX (CMakeLists.txt:104), so the NetworkManager
    # stack returns: LibNDP -> NetworkManager (libnm, trimmed) -> NetworkManager-Qt.
    compile LibNDP 1.9 && package LibNDP 1.9 &&
    compile NetworkManager 1.51.4 && package NetworkManager 1.51.4 &&
    compile NetworkManager-Qt 6.26.0 && package NetworkManager-Qt 6.26.0 &&
    # ---- 'modem' component (4G/5G mobile broadband). Separate selectable
    # menu item; off unless the last .build-select run had it 'yes' or there is
    # no saved choice yet (default ON preserves the network applet). ModemManager
    # daemon MUST precede ModemManagerQt (pkg-searches ModemManager.pc+headers),
    # which plasma-nm hard-requires (find_package(KF6 ... ModemManagerQt) in the
    # REQUIRED list, PUBLIC-linked in libs) -- so when 'modem' is 'no' plasma-nm
    # is skipped too (Base NM still runs, just no tray applet usable).
    if [ "$(comp_select_default modem)" != no ]; then
        # ModemManagerQt 6.26.0 (KF6 framework, plasma-nm REQUIRED find): its
        # cmake/FindModemManager.cmake pkg-searches ModemManager, so the 1.24.2
        # daemon must be installed first (provides ModemManager.pc + headers;
        # glib/gudev/udev/polkit/dbus all already on the ISO).
        compile ModemManager 1.24.2 && package ModemManager 1.24.2 &&
        compile ModemManagerQt 6.26.0 && package ModemManagerQt 6.26.0 &&
        # Mobile-Broadband-Provider-Info (meson) exports its `database` pc
        # variable for plasma-nm's mobile editor; QtKeyChain provides the
        # Qt6KeychainConfig plasma-nm CONFIG-requires. Neither needs KDE builds.
        compile Mobile-Broadband-Provider-Info 20240407 && package Mobile-Broadband-Provider-Info 20240407 &&
        compile QtKeyChain 0.16.0 && package QtKeyChain 0.16.0
    fi &&
    compile KQuickCharts 6.26.0 && package KQuickCharts 6.26.0 &&
    compile KWallet 6.26.0 && package KWallet 6.26.0 &&
    compile KDED 6.26.0 && package KDED 6.26.0 &&
    compile Polkit-Qt-1 0.201.1 && package Polkit-Qt-1 0.201.1 &&
    # LMDB is REQUIRED by Baloo; plain-Makefile lib using -C override recipe
    compile LMDB 0.9.31 && package LMDB 0.9.31 &&
    # baloo pulls in kfilemetadata + kidletime (both above); needs kio first
    compile Baloo 6.26.0 && package Baloo 6.26.0 &&
    compile Kirigami-Addons 1.13.1 && package Kirigami-Addons 1.13.1 &&
    # Prison REQUIRED backends: qrencode, libdmtx, zxing-cpp (all native)
    compile Qrencode 4.1.1 && package Qrencode 4.1.1 &&
    compile Dmtx 0.7.8 && package Dmtx 0.7.8 &&
    compile ZXing 3.1.1 && package ZXing 3.1.1 &&
    compile Prison 6.26.0 && package Prison 6.26.0 &&
    # Qt/Qt5Compat may have been (re)built since the step-start merge; mirror
    # their qml trees again so ECMFindQmlModule finds Qt5Compat.GraphicalEffects.
    merge_qml_index
    # ---- Phase C: Plasma 6.7.4 desktop modules ----
    compile KWayland 6.7.4 && package KWayland 6.7.4 &&
    compile KDecoration 6.7.4 && package KDecoration 6.7.4 &&
    # QtPositioning supplies Qt6Positioning, REQUIRED by KNightTime
    compile QtPositioning 6.10.3 && package QtPositioning 6.10.3 &&
    # QtLocation supplies Qt6Location + OSM geoservices, REQUIRED by Plasma-Workspace
    compile QtLocation 6.10.3 && package QtLocation 6.10.3 &&
    # KNightTime is REQUIRED by kwin (night-light DBus helper), build it here
    compile KNightTime 6.7.4 && package KNightTime 6.7.4 &&
    # kwin's configure needs PlasmaConfig (libplasma) + KScreenLockerConfig, so
    # libplasma/kscreenlocker must be built BEFORE kwin, not after
    compile KGlobalacceld 6.7.4 && package KGlobalacceld 6.7.4 &&
    compile LibKScreen 6.7.4 && package LibKScreen 6.7.4 &&
    compile Kactivitymanagerd 6.7.4 && package Kactivitymanagerd 6.7.4 &&
    compile Plasma-Activities 6.7.4 && package Plasma-Activities 6.7.4 &&
    compile Plasma-Activities-Stats 6.7.4 && package Plasma-Activities-Stats 6.7.4 &&
    # KF6UnitConversion (kunitconversion) is REQUIRED by Plasma5Support
    compile KUnitConversion 6.26.0 && package KUnitConversion 6.26.0 &&
    compile Plasma5Support 6.7.4 && package Plasma5Support 6.7.4 &&
    # PlasmaWaylandProtocols built in Phase B (kwindowsystem/kguiaddons need it)
    compile LibPlasma 6.7.4 && package LibPlasma 6.7.4 &&
    # KScreenLocker needs libplasma's PlasmaQuick config + layer-shell-qt, so
    # both precede it; kwin then needs configs from libplasma/kscreenlocker.
    compile Layer-Shell-QT 6.7.4 && package Layer-Shell-QT 6.7.4 &&
    compile KScreen 6.7.4 && package KScreen 6.7.4 &&
    compile KScreenlocker 6.7.4 && package KScreenlocker 6.7.4 &&
    compile KWin 6.7.4 && package KWin 6.7.4 &&
    compile FFmpeg6 6.1.1 && package FFmpeg6 6.1.1 &&
    compile KPipewire 6.7.4 && package KPipewire 6.7.4 &&
    compile QCoro 0.13.0 && package QCoro 0.13.0 &&
    compile KSysGuard 6.7.4 && package KSysGuard 6.7.4 &&
    # KIO-Extras (Gear) + ksystemstats (Plasma): first point where KCMUtils +
    # Plasma-Activities(-Stats) + QCoro already precede them, which KIO-Extras
    # optional subdirs want. libproxy OFF (not on ISO, WPAD probe) and the
    # libssh/libmtp/Samba/TIRPC/bump workers fall out as optional finds.
    # ksystemstats needs only KSysGuardConfig >= 6.7.0 + KF6NetworkManagerQt;
    # Sensors/NL/UDev/Libcap/Devinfo finds are all optional (LM-Sensors + LibNL
    # are in-tree anyway).
    compile KIO-Extras 26.08.0 && package KIO-Extras 26.08.0 &&
    compile KSystemStats 6.7.4 && package KSystemStats 6.7.4 &&
    compile Plasma-Workspace 6.7.4 && package Plasma-Workspace 6.7.4 &&
    # KWayland-Integration DROPPED: its 6.7.4 tarball is the legacy Qt5/KF5
    # plugin (CMakeLists requires Qt5 Core/Widgets/WaylandClient, Qt5XkbCommonSupport,
    # KF5Wayland, KF5WindowSystem). No KF5 toolchain on the ISO (KF6 only);
    # it only ships runtime plugins for Qt5 Wayland clients, which run under
    # XWayland here. Qt6 Plasma stack unaffected.
    # SDL 2.30.2 first so the merged /System/Index/lib/cmake/SDL2 reports >=
    # 2.0.16 at Plasma-Desktop configure time (the kcms/gamecontroller KCM is
    # only built when TARGET SDL2::SDL2 is found).
    compile SDL 2.30.2 && package SDL 2.30.2 &&
    compile Plasma-Desktop 6.7.4 && package Plasma-Desktop 6.7.4 &&
    # Plasma-NM (built only with 'modem' = yes, see the NM/modem block above):
    # NM + ModemManager frontends (tray applet, kcm_networkmanagement,
    # mobile-broadband editor). Needs LibPlasma's PlasmaConfig >= 6.7.0, KF6
    # NetworkManagerQt/ModemManagerQt + Qt6Keychain + provider-info + prison/
    # formcard qmlmodules (all built above). Its applet QML is copied by the
    # same ECM QT_NO_PLUGIN pre_link() hook as plasma-desktop/workspace.
    if [ "$(comp_select_default modem)" != no ]; then
        compile Plasma-NM 6.7.4 && package Plasma-NM 6.7.4
    fi &&
    # Milou (KRunner search widget for overview + Kickoff): Deps are KF6
    # KRunner/KService/KDeclarative/KPackage/KSvg + LibPlasma, all of which
    # now precede it. KWin's overview QML hard-imports org.kde.milou, so this
    # must land before the shell is exercised.
    compile Milou 6.7.4 && package Milou 6.7.4 &&
    compile KGamma 6.7.4 && package KGamma 6.7.4 &&
    compile Breeze 6.7.4 && package Breeze 6.7.4 &&
    compile Plasma-Integration 6.7.4 && package Plasma-Integration 6.7.4 &&
    compile Powerdevil 6.7.4 && package Powerdevil 6.7.4 &&
    compile Polkit-KDE-Agent-1 6.7.4 && package Polkit-KDE-Agent-1 6.7.4 &&
    compile Systemsettings 6.7.4 && package Systemsettings 6.7.4 &&
    compile Kinfocenter 6.7.4 && package Kinfocenter 6.7.4 &&
    compile KMenuEdit 6.7.4 && package KMenuEdit 6.7.4 &&
    # KDeplasma-Addons DROPPED: requires find_package(Corrosion REQUIRED)
    # (CMakeLists.txt:114) + a Rust toolchain; its one Rust target pulls tokio/
    # zbus/etc from crates.io at build time (kameleon QMK keyboard LED helper).
    # No Rust/Corrosion on the ISO; optional desktop widgets only - none of the
    # remaining packages depend on it at build time.
    compile Ocean-Sound-Theme 6.7.4 && package Ocean-Sound-Theme 6.7.4 &&
    compile PulseAudio-Qt 1.6.0 && package PulseAudio-Qt 1.6.0 &&
    compile Plasma-PA 6.7.4 && package Plasma-PA 6.7.4 &&
    # Plasma-NM (plasma-nm) is built above (after Plasma-Desktop, gated on the
    # 'modem' component); when disabled the ModemManager chain is skipped too.
    compile XDG-Desktop-Portal-KDE 6.7.4 && package XDG-Desktop-Portal-KDE 6.7.4
}

# glibc 2.44-2: upgrade the ISO's 64-bit libc from 2.30 to 2.44-2, copied from
# Debian's libc6 package overlaid on a clone of the base glibc tree (see
# Recipes/Glibc). Required by every modern third-party binary on the ISO:
# FastFetch's official build needs GLIBC_2.34 and ProtonPlus's bundled
# GTK4/Adwaita need up to GLIBC_2.44. Compiling it first ALSO switches this
# build chroot's own index to 2.44, so the ProtonPlus rebuild right after runs
# on it. refresh-merge.py installs the package into work/rootfs with
# `SymlinkProgram -c overwrite`, re-pointing /System/Index/lib/libc.so.6 etc.
# to 2.44 in the shipped image. Idempotent (compile/package skip when present).
ensure_glibc244() {
    cd /Data/Compile
    rm -rf Recipes/Glibc
    cp -a /mnt/repo/Recipes/Glibc Recipes/Glibc
    compile Glibc 2.44-2 && package Glibc 2.44-2 || return 1
    log "OK: glibc upgraded to 2.44-2 (index now resolves to it)"
}

# ProtonPlus 0.6.8 repack: the first build's --appimage-extract came out EMPTY
# in the chroot (the DwarFS runtime could not self-extract there), so the
# package shipped an empty lib/protonplus and the wrapper died with "AppRun:
# No such file or directory". Rebuild IN PLACE (compile_forced --keep) with the
# fixed recipe, which self-extracts under glibc 2.44 and falls back to the baked
# AppDir in the staged recipe (BakedAppDir/) if it still cannot. Once the
# tarball actually holds AppDir/AppRun, subsequent runs skip. Must run after
# ensure_glibc244.
ensure_protonplus() {
    cd /Data/Compile
    if tar tjf "$B/Packages/ProtonPlus--0.6.8--x86_64.tar.bz2" 2>/dev/null | grep -q 'ProtonPlus/0.6.8/lib/protonplus/AppRun'
    then
        log "SKIP: ProtonPlus package already contains its AppDir payload"
        return 0
    fi
    rm -rf Recipes/ProtonPlus
    cp -a /mnt/repo/Recipes/Gaming/ProtonPlus Recipes/ProtonPlus
    # Rebuild over the (empty-lib) installed tree when one exists; plain
    # compile for a chroot where ProtonPlus was never built.
    if installed ProtonPlus 0.6.8
    then compile_forced ProtonPlus 0.6.8 || return 1
    else compile ProtonPlus 0.6.8 || return 1
    fi
    package ProtonPlus 0.6.8 || return 1
    log "OK: ProtonPlus repackaged with its AppDir payload"
}

# SDL 2.30.2 upgrade + Plasma-Desktop 6.7.4 Game-Controller-KCM rebuild. The
# base ISO ships SDL 2.0.12 whose cmake config reports 2.0.12, below the
# `find_package(SDL2 2.0.16)` gate in plasma-desktop's kcms/CMakeLists.txt, so
# kcm_gamecontroller.so is never built and the KCM is missing from System
# Settings on the booted ISO. Fix: build the new SDL recipe (its sdl2-config-
# config.cmake reports 2.30.2, ABI-compatible with 2.0.12), then FORCE an
# in-place rebuild of the merged Plasma-Desktop 6.7.4 tree so the gate now
# passes and the plugin lands in the package. Must run after the SDL package
# exists; idempotent (skips once the Plasma-Desktop tarball carries the KCM).
ensure_sdl_kcm() {
    cd /Data/Compile
    # Sync the new SDL recipe into the chroot (step_sync's SDL loop only runs
    # on a full `sync` step; this makes livefix/merge self-contained).
    rm -rf Recipes/SDL
    cp -a /mnt/repo/Recipes/SDL Recipes/SDL
    compile SDL 2.30.2 && package SDL 2.30.2 || return 1
    # Rebuild plasma-desktop IN PLACE (--keep) so /System/Index/lib/cmake/SDL2
    # now points at 2.30.2 when its cmake re-configures. Only a --keep rebuild
    # keeps the already-installed tree loadable for its build dir; a plain
    # compile would rm -rf it and lose build deps / qml index state.
    if tar tjf "$B/Packages/Plasma-Desktop--6.7.4--x86_64.tar.bz2" 2>/dev/null | grep -q 'lib/plugins/plasma/kcms/systemsettings/kcm_gamecontroller.so'
    then
        log "SKIP: Plasma-Desktop 6.7.4 already ships kcm_gamecontroller.so"
        return 0
    fi
    rm -rf Recipes/Plasma-Desktop
    cp -a /mnt/repo/Recipes/Plasma6-core/Plasma-Desktop Recipes/Plasma-Desktop
    if installed Plasma-Desktop 6.7.4
    then compile_forced Plasma-Desktop 6.7.4 || return 1
    else compile Plasma-Desktop 6.7.4 || return 1
    fi
    package Plasma-Desktop 6.7.4 || return 1
    log "OK: Plasma-Desktop 6.7.4 rebuilt with the Game Controller KCM"
}

# The three ISO runtime repairs that must be baked by the NEXT merge: the glibc
# 2.44-2 upgrade (unblocks FastFetch + ProtonPlus on the booted ISO), the
# ProtonPlus repack (its previous tarball had an empty lib/protonplus) and the
# SDL 2.30.2 upgrade + plasma-desktop gamecontroller KCM rebuild. Called
# by step_merge BEFORE refresh-merge.py and by the standalone `livefix` step.
ensure_livefix_builds() {
    ensure_glibc244 || return 1
    ensure_protonplus || return 1
    ensure_sdl_kcm || return 1
}

step_merge() {
    log ">>> Refreshing LiveCD (merge + initramfs)"
    cd "$B"
    # Bake the runtime fixes FIRST so the merge ships them: 64-bit glibc 2.30
    # -> 2.44-2 (FastFetch + ProtonPlus need it) and the ProtonPlus repack.
    ensure_livefix_builds || return 1
    # Unmount any stale proc/dev mounts left over from a prior failed merge.
    # InChroot.exec() in refresh-merge.py binds /proc and /dev into work/rootfs;
    # if the script crashes the umount in the finally-block may not fully clean up.
    # /proc/mounts shows canonical host paths. In GoboLinux, proc is a symlink
    # to System/Kernel/Status, so the mount lands on that path. Match broadly.
    for mp in $(awk '/work\/rootfs\/(proc|dev|System\/Kernel\/Status|System\/Kernel\/Devices)/ { print $2 }' /proc/mounts 2>/dev/null | sort -r); do
        log "Unmounting stale mount: $mp"
        umount -l "$mp" 2>/dev/null || true
    done
    rm -rf "$B/work"
    python3 /mnt/gobo-build/refresh-merge.py \
        "$B/GoboLinux-017.01-x86_64.iso" \
        "$B/work" \
        "$B/Packages" >"$B/logs/refresh.log" 2>&1 || {
        log "FAILED: RefreshLiveCD merge (see $B/logs/refresh.log)"
        return 1
    }
    log "OK: merge complete (work/ ready for ISO finalization)"
    # Hand the build products back to whoever owns the mounted repo (no
    # user-specific owner is hardcoded).
    chown -R --reference="$B" "$B/work" "$B/Packages" "$B/logs" 2>/dev/null || true
    step_livefix
}

# Runtime fixes that must exist in every ISO but are not (fully) handled by
# the recipes: SDDM greeter Qt paths, sddm system user, seatd/elogind boot
# wiring, elogind D-Bus activation path. Idempotent; safe to run repeatedly.
step_network() {
    # 'network' component/step: boot-time networking tooling for the LiveCD.
    #
    # Provides the CLI tools GoboNet (wpa_supplicant + dhcpcd, the Gobo
    # network manager wired by apply-live-fixes.sh section 41) and ModemManager
    # expect on the live session:
    #   - iw          nl80211 WiFi CLI (complements wireless-tools' iwlist)
    #   - ethtool     wired-NIC diagnostics (built with --enable-netlink=no:
    #                 libmnl is NOT on the ISO, so use the classic ioctl path)
    #   - usb_modeswitch 4G/5G stick mode-switching (CD-ROM -> modem)
    #   - libmbim     MBIM backend (glib)
    #   - libqmi      QMI backend (glib)
    #   - ModemManager REBUILT (same 1.24.2) with -Dqmi=true -Dmbim=true:
    #                 the base ISO shipped -Dqmi=false -Dmbim=false so most
    #                 4G/5G sticks were invisible to the daemon; rebuilt below.
    #   - BIND        dig/host/nslookup DNS client tools.
    #
    # Runtime wiring (rfkill unblock, GoboNet autoconnect Network task,
    # ModemManager+Bluetooth Start in StartLiveCD/BootUp) is applied by
    # apply-live-fixes.sh section 41 during 'merge' -- not here.  A bare
    # `run-build.sh network` only produces the packages; re-run 'merge'
    # afterwards to bake the runtime wiring into the ISO.
    step_sync
    compile IW 6.9 && package IW 6.9 || return 1
    compile Ethtool 6.11 && package Ethtool 6.11 || return 1
    compile USB-Modeswitch 2.6.1 && package USB-Modeswitch 2.6.1 || return 1
    compile Libmbim 1.30.0 && package Libmbim 1.30.0 || return 1
    compile Libqmi 1.34.0 && package Libqmi 1.34.0 || return 1
    # ModemManager same-version rebuild: the base ISO ships 1.24.2 built with
    # -Dqmi=false -Dmbim=false, so most 4G/5G sticks are invisible to the daemon.
    # compile()/compile_keep() both skip an already-installed tree, so do what
    # step_pycompat/step_glib do for their same-version rebuilds: drop the old
    # tarball + program tree, then compile fresh with QMI+MBIM=$(true).
    rm -f "$B/Packages/ModemManager--1.24.2--x86_64.tar.bz2"
    rm -rf /Programs/ModemManager/1.24.2 /Programs/ModemManager/1.24.2-failed
    # Same-version rebuild leaves ~82 dangling /System/Index symlinks (bin,
    # include, pkgconfig, udev rules, share/locale/*.mo) pointing into the
    # just-deleted tree. meson install() then opens a *dangling* link -> ENOENT.
    # Drop them so install re-creates clean files through the /usr union.
    find /System/Index -type l -lname '/Programs/ModemManager/*' -delete
    compile ModemManager 1.24.2 && package ModemManager 1.24.2 || return 1
    compile Bind 9.18.33 && package Bind 9.18.33 || return 1
    log "OK: network tooling packages built (iw/ethtool/usb-modeswitch/libmbim/libqmi/ModemManager-Rebuild/bind). Run 'merge' (apply-live-fixes section 41) to wire GoboNet/ModemManager/Bluetooth boot tasks + rfkill."
}

step_devices() {
    # 'devices' component/step: phone / MTP / USB-gadget tooling for the
    # LiveCD. Builds the recipes that mount a modern phone (Android MTP /
    # iOS + the flatpak/phone PGP stack) by baking the exact packages that
    # apply-live-fixes.sh section 43 ("phone / MTP automount") wires into
    # the live session:
    #
    #   - Libusb 1.0.27        userspace USB access (libusb-1.0.so.0)
    #   - Libmtp 1.1.21        MTP protocol stack (libmtp.so.9)
    #   - Simple-Mtpfs 0.4.0   FUSE driver that gives /Mount/phone a real
    #                          file tree over MTP (the mountpoint + boot-time
    #                          automount task live in section 43)
    #   - LibGCrypt 1.11.3     crypto core GnuPG 2.4.9 hard-requires
    #                          (>= 1.9.1; the ISO ships only 1.8.5) -- built
    #                          by ensure_gpg_chain below
    #   - Libksba 1.6.8        X.509/CMS library GnuPG 2.4.9 hard-requires
    #                          (>= 1.6.3; absent on the ISO) -- built by
    #                          ensure_gpg_chain below
    #   - GnuPG 2.4.9          gpg / gpgv engine flatpak needs for its GPG
    #                          verification + the phone PGP identity workflow
    #   - Nvidia-Settings 580.159.04  nvidia-settings/xrandr CLI the NVIDIA
    #                          runtime enablement (livefix 14b) exposes under
    #                          Wayland/Xorg
    #
    # A bare `run-build.sh devices` only produces the packages; run 'merge'
    # afterwards (apply-live-fixes section 43 bakes the /Mount/phone
    # mountpoint + Fuse setuid/fuse.conf fix + MtpPhone automount task into
    # the ISO).
    step_sync
    compile Libusb 1.0.27 && package Libusb 1.0.27 || return 1
    compile Libmtp 1.1.21 && package Libmtp 1.1.21 || return 1
    compile Simple-Mtpfs 0.4.0 && package Simple-Mtpfs 0.4.0 || return 1
    ensure_gpg_chain || return 1
    compile Nvidia-Settings 580.159.04 && package Nvidia-Settings 580.159.04 || return 1
    log "OK: phone/MTP package set built (Libusb 1.0.27, Libmtp 1.1.21, Simple-Mtpfs 0.4.0, LibGCrypt 1.11.3, Libksba 1.6.8, GnuPG 2.4.9, Nvidia-Settings 580.159.04). Run 'merge' (apply-live-fixes section 43) to wire the /Mount/phone mount + MtpPhone automount task into the ISO."
}

# GnuPG 2.4.9 build chain repair (phone/PGP tier). The base ISO ships only
# libgcrypt 1.8.5 (below the >= 1.9.1 GnuPG 2.4.9's configure hard-requires)
# and NO libksba (>= 1.6.3 required), so a bare GnuPG compile aborts with
# "Required libraries not found. ... You need libgcrypt / libksba to build
# this program." Building both as top-level packages flips the LibGCrypt
# Current symlink to 1.11.3 and creates Libksba 1.6.8, satisfying configure
# (libgcrypt keeps its libgcrypt.so.20 SONAME, so 1.8.x-era consumers such as
# p11-kit/Gcr3/GnomeKeyring on the merged ISO keep working).
#
# Called by step_devices (right before GnuPG) and by step_livefix (so a bare
# `run-build.sh livefix` repairs the gpg build chain too, even before a
# merge exists -- the compile part needs no rootfs). Idempotent: compile()/
# package() skip once the package tarball exists, step_sync only runs when
# the recipe is absent so `livefix` stays light.
ensure_gpg_chain() {
    cd /Data/Compile
    [ -f /Data/Compile/Recipes/LibGCrypt/1.11.3/Recipe ] || step_sync
    for f in libgcrypt-1.11.3.tar.bz2 libksba-1.6.8.tar.bz2; do
        if [ -f "$B/$f" ] && [ ! -f "/Data/Compile/Archives/$f" ]; then
            cp "$B/$f" "/Data/Compile/Archives/$f"
            log "staged archive $f (gpg chain)"
        fi
    done
    compile LibGCrypt 1.11.3 && package LibGCrypt 1.11.3 || return 1
    compile Libksba 1.6.8 && package Libksba 1.6.8 || return 1
    compile GnuPG 2.4.9 && package GnuPG 2.4.9 || return 1
    log "OK: GnuPG build chain satisfied (LibGCrypt 1.11.3, Libksba 1.6.8, GnuPG 2.4.9)"
}

step_livefix() {
    log ">>> Applying LiveCD runtime fixes (SDDM/seatd/elogind/menu icons/NVIDIA)"
    # Ensure the phone/PGP compile chain (LibGCrypt >= 1.9.1, Libksba >= 1.6.3,
    # GnuPG) is built+packaged in the chroot -- no-op once the tarballs exist --
    # so a bare `run-build.sh livefix` repairs the gpg build deps AND re-applies
    # the runtime fixes below in one command.
    ensure_gpg_chain || return 1
    # ISO libc fixes that must land in Packages/ before the NEXT merge: the
    # glibc 2.44-2 upgrade (FastFetch + ProtonPlus need it) and the ProtonPlus
    # repack (its shipped tarball had an empty lib/protonplus). Running before
    # the work/rootfs guard keeps `livefix` usable even before a merge exists.
    ensure_livefix_builds || return 1
    [ -d "$B/work/rootfs" ] || {
        log "No $B/work/rootfs yet — run 'merge' first"
        return 1
    }
    bash /mnt/gobo-build/apply-live-fixes.sh "$B/work/rootfs" || return 1
    # Hand the tree back to whoever owns the mounted repo (files created by
    # apply-live-fixes.sh -- 14b's /usr/share/applications + pixmaps -- are
    # otherwise left root-owned, breaking later user-run host steps).
    chown -R --reference="$B" "$B/work" 2>/dev/null || true
    # The chown -R above re-owns the setuid helpers to the repo owner, and
    # chown() to a non-root owner CLEARS the setuid/setgid bits on Linux --
    # undoing apply-live-fixes.sh's 15c) setuid sweep, so sudo says "must be
    # owned by uid 0 and have the setuid bit set".  Re-apply root ownership +
    # mode 4755 AFTER the hand-back so the tree stays correct in the ISO.
    for helper in \
        "Sudo/bin/sudo" \
        "Polkit/bin/pkexec" \
        "Linux-PAM/sbin/unix_chkpwd" \
        "DBus/lib/dbus-daemon-launch-helper" \
    ; do
        prog=${helper%%/*}; rel=${helper#*/}
        pdir=$(readlink -f "$B/work/rootfs/Programs/$prog/Current" 2>/dev/null || true)
        [ -n "$pdir" ] && [ -e "$pdir/$rel" ] || continue
        chown root:root "$pdir/$rel" 2>/dev/null || true
        chmod 4755 "$pdir/$rel" 2>/dev/null || true
        log "setuid re-applied (post-chown): $prog/$rel"
    done
    # polkit agent helper path varies; sweep it, then re-own sudo plug-ins.
    polkit_dir=$(readlink -f "$B/work/rootfs/Programs/Polkit/Current" 2>/dev/null || true)
    if [ -n "$polkit_dir" ] && [ -d "$polkit_dir/lib" ]; then
        find "$polkit_dir/lib" -name polkit-agent-helper-1 \
            -exec chown root:root {} \; -exec chmod 4755 {} \; 2>/dev/null || true
        log "setuid re-applied (post-chown): polkit-agent-helper-1"
    fi
    sudo_dir=$(readlink -f "$B/work/rootfs/Programs/Sudo/Current" 2>/dev/null || true)
    if [ -n "$sudo_dir" ] && [ -d "$sudo_dir/lib/sudo" ]; then
        chown -R root:root "$sudo_dir/lib/sudo" 2>/dev/null || true
        chmod 755 "$sudo_dir"/lib/sudo/sudo/*.so "$sudo_dir"/lib/sudo/*.so* 2>/dev/null || true
        log "setuid re-applied (post-chown): sudo plug-ins"
    fi
    # /System/Settings/sudoers -> Programs/Sudo/Settings/sudoers is a real file
    # (not under the version dir); the chown -R sweep above re-owns it to the
    # repo owner, so sudo refuses it ("sudoers is owned by uid 1000 should be
    # 0").  Re-own root:root + mode 0440 AFTER the hand-back, matching
    # apply-live-fixes.sh's 15c) sudoers fix.
    if [ -f "$B/work/rootfs/Programs/Sudo/Settings/sudoers" ]; then
        chown root:root "$B/work/rootfs/Programs/Sudo/Settings/sudoers" 2>/dev/null || true
        chmod 0440 "$B/work/rootfs/Programs/Sudo/Settings/sudoers" 2>/dev/null || true
        log "sudoers re-owned (post-chown): Programs/Sudo/Settings/sudoers"
    fi
    # /var/empty (sshd privsep sandbox) and the OpenSSH host keys are root-only
    # requirements; the chown -R sweep re-owns both to the repo owner, so sshd
    # dies with "/var/empty must be owned by root..." / "no hostkeys specified"
    # (kex reset).  Re-assert root ownership AFTER the hand-back.
    if [ -d "$B/work/rootfs/var/empty" ]; then
        chown root:root "$B/work/rootfs/var/empty" 2>/dev/null || true
        chmod 755 "$B/work/rootfs/var/empty" 2>/dev/null || true
        log "re-owned (post-chown): /var/empty"
    fi
    sshkeys="$B/work/rootfs/Programs/OpenSSH/Settings/ssh"
    if [ -d "$sshkeys" ]; then
        chown root:root "$sshkeys"/ssh_host_*_key "$sshkeys"/ssh_host_*_key.pub 2>/dev/null || true
        chmod 600 "$sshkeys"/ssh_host_*_key 2>/dev/null || true
        chmod 644 "$sshkeys"/ssh_host_*_key.pub 2>/dev/null || true
        log "re-owned (post-chown): OpenSSH host keys"
    fi
    log "OK: live fixes applied"
}

step_test() {
    log "== Chroot environment test =="
    echo "Gobo version:        $(cat /etc/GoboLinuxVersion 2>/dev/null || cat /System/Settings/GoboLinuxVersion 2>/dev/null || echo unknown)"
    echo "goboPrefix:          ${goboPrefix:-/}"
    echo "PATH head:           $goboExecutables"
    echo "bash:                $(command -v bash)"
    echo "Compile:             $(command -v Compile) ($(Compile --version 2>&1 | head -1))"
    echo "CreatePackage:       $(command -v CreatePackage)"
    echo "mount:               $(command -v mount)"
    echo "chroot:              $(command -v chroot)"
    echo "python3:             $(command -v python3)"
    echo "git:                 $(command -v git)"
    echo "gcc:                 $(command -v gcc) ($(gcc --version | head -1))"
    echo "make:                $(command -v make)"
    echo "cmake:               $(command -v cmake) ($(cmake --version | head -1))"
    echo "Network check:       $(wget -q -T 10 -O /dev/null https://cdn.kernel.org 2>/dev/null && echo OK || echo FAIL)"
    echo "DNS check:           $(getent hosts github.com >/dev/null 2>&1 && echo OK || echo FAIL)"
    ls /Programs/Linux/Current/lib/modules/ 2>/dev/null
    echo "== test complete =="
}

# ---------------------------------------------------------------------------
# Component-select CLI: interactive menu (default when no step given) or
# --flag-driven non-interactive builds. Selections are saved to $B/.build-select
# and re-used as defaults on the next interactive run.
# ---------------------------------------------------------------------------
SELECT_CFG="$B/.build-select"

SELECT_CORE="proton sync linux nvidia nvdiag glibc32"

# Optional components: label for the menu prompt.
clabel() {
    case "$1" in
        lib32)    echo "32-bit compatibility libraries (Steam/Wine)" ;;
        wayland)  echo "Wayland core stack + Sway compositor" ;;
        swayextras) echo "Sway extras (swaybg/swaylock/swayidle/libdecor)" ;;
        vulkan)   echo "Vulkan loader/headers/tools" ;;
        gaming)   echo "Gaming stack (Steam/Wine/Proton/Lutris/Heroic/ProtonPlus)" ;;
        ffxiv)    echo "XIVLauncher (FFXIV Quick Launcher, runs under Wine)" ;;
        lutris)   echo "Lutris game launcher (self-contained: wine stack + webkit, no sway)" ;;
        fastfetch) echo "FastFetch system-info tool (neofetch replacement)" ;;
        extras)   echo "Discord + VLC desktop apps" ;;
        flatpak)  echo "Flatpak runtime (desktop-free, CLI + sandboxing)" ;;
        sddm)     echo "SDDM display manager (Wayland greeter)" ;;
        pantheon) echo "Pantheon (elementary OS 8) desktop" ;;
        webkit)   echo "WebKitGTK web engine (Lutris/GTK3 account logins)" ;;
        plasma)   echo "Plasma 6.7 desktop (Qt6/KF6/Plasma/Gear)" ;;
        modem)    echo "4G/5G mobile broadband (ModemManager daemon + provider DB + Plasma-NM network applet)" ;;
        network)  echo "Network tooling (iw NL80211 CLI, ethtool, usb_modeswitch, ModemManager rebuilt with QMI+MBIM backends, BIND dig/host/nslookup)" ;;
        pipewire) echo "PipeWire media server + WirePlumber session manager (system-wide audio)" ;;
        music)    echo "LMMS 1.3.0-alpha.2 music production DAW (Qt5; needs FFTW3F + libsndfile)" ;;
        programming) echo "Programming languages: Node.js 24 (npm 12.1.0) + Go 1.27 + Odin dev + V 0.5.2" ;;
        appimage) echo "AppImage tooling (appimagetool + libappimage)" ;;
        fs)       echo "Filesystem tools (XFS + OpenZFS)" ;;
        iso)      echo "Assemble final ISO + live fixes" ;
    esac
}

# Steps each component pulls in (canonical step names, see the case dispatch).
csteps() {
    case "$1" in
        lib32)    echo "lib32" ;;
        wayland)  echo "wayland" ;;
        swayextras) echo "swayextras" ;;
        vulkan)   echo "vulkan" ;;
        gaming)   echo "steam winetools mingw winedev pycompat pyxml protonplus" ;;
        ffxiv)    echo "ffxiv" ;;
        lutris)   echo "lutris" ;;
        fastfetch) echo "fastfetch" ;;
        network)  echo "network" ;;
        modem)    echo "network" ;;
        extras)   echo "extras" ;;
        flatpak)  echo "flatpak" ;;
        sddm)     echo "sddm" ;;
        pantheon) echo "pantheon" ;;
        webkit)   echo "webkit" ;;
        plasma)   echo "plasma" ;;
        music)    echo "music" ;;
        programming) echo "nodejs go odin v" ;;
        pipewire) echo "pipewire" ;;
        appimage) echo "appimage" ;;
        fs)       echo "fs" ;;
        iso)      echo "merge aliens" ;;
    esac
}

# Components that must also be selected when $1 is selected.
cdeps() {
    case "$1" in
        swayextras|vulkan) echo "wayland" ;;
        gaming)            echo "lib32 webkit" ;;
        ffxiv)             echo "winedev" ;;
        lutris)            echo "winedev webkit" ;;
        pantheon)          echo "wayland sddm" ;;
        plasma)            echo "wayland sddm" ;;
        *)                 echo "" ;;
    esac
}

# Highest-level step ordering used to flatten a component selection into a
# single run list (mirrors the 'all' case). Only these appear in the run list.
SELECT_ORDER="proton sync linux nvidia nvdiag glibc32 fs lib32 wayland swayextras vulkan steam winetools mingw winedev protonplus lutris ffxiv pycompat pyxml flatpak sddm extras fastfetch appimage webkit pantheon plasma pipewire network music nodejs go odin v merge aliens"
SELECT_ALL="lib32 wayland swayextras vulkan gaming ffxiv lutris fastfetch fs extras flatpak sddm appimage pantheon webkit plasma modem network music programming pipewire iso"

comp_select_default() { awk -F= -v k="$1" '$1==k{print $2}' "$SELECT_CFG" 2>/dev/null; }

comp_save_default() {
    grep -q "^$1=" "$SELECT_CFG" 2>/dev/null &&
        sed -i "s|^$1=.*|$1=$2|" "$SELECT_CFG" ||
        printf '%s=%s\n' "$1" "$2" >> "$SELECT_CFG"
}

# Flatten "core + selected components" into a canonical ordered run list.
flatten_selection() {
    # $1 = space-separated component list (core implied). Sets RUN_LIST.
    local comps="$SELECT_CORE $1" changed=1 dep c s sel=""
    # resolve transitive deps onto the component set
    while [ "$changed" -eq 1 ]; do
        changed=0
        for c in $comps; do
            for dep in $(cdeps "$c"); do
                case " $comps " in *" $dep "*) : ;; *)
                    comps="$comps $dep"; changed=1 ;; esac
            done
        done
    done
    # map components -> step names; core names ARE step names
    for c in $comps; do
        [ "$(csteps "$c")" = "" ] && sel="$sel $c" || sel="$sel $(csteps "$c")"
    done
    # canonical order: only emit a step once, in SELECT_ORDER position
    RUN_LIST=""
    local s
    for s in $SELECT_ORDER; do
        case " $sel " in *" $s "*) RUN_LIST="$RUN_LIST $s" ;; esac
    done
    RUN_LIST="${RUN_LIST# }"
}

build_selection() {
    # $1 = space-separated component list. Resolve deps + run, or print plan.
    flatten_selection "$1"
    [ "$2" != run ] && {
        log "Selected components:$1"
        log "Resolved run list:$RUN_LIST"
        for c in $1; do comp_save_default "$c" yes; done
        return 0
    }
    log "=== Building components:$1 ==="
    log "Resolved run list:$RUN_LIST"
    for c in $1; do comp_save_default "$c" yes; done
    local step rc=0
    for step in $RUN_LIST; do
        run "$step" || { rc=1; break; }
    done
    [ "$rc" -eq 0 ] || log "!! Component build FAILED at step '$step'"
    return $rc
}

menu_select() {
    echo
    echo "LiveCD build component selection (core is always built)."
    echo "Hitting Enter keeps the shown default; defaults come from the last selection."
    echo
    select_kernel
    select_autodriver
    echo
    local choices="" c def hint ans
    for c in $SELECT_ALL; do
        def="$(comp_select_default "$c")"
        if [ -z "$def" ]; then
            # First-run default: most components default to 'yes'; the heavy
            # optional extras (music/LMMS, programming languages) default to
            # 'no' so a quickly-browsed menu never drags in a big build by
            # accident.
            case "$c" in music|programming) def=no ;; *) def=yes ;; esac
        fi
        hint=Y/n; [ "$def" = no ] && hint=y/N
        printf 'Include %-11s %-45s [%s] : ' "$c" "$(clabel "$c")" "$hint"
        read -r ans || exit 130
        case "${ans,,}" in
            "") val="$def" ;;
            y|yes|1) val=yes ;;
            n|no|0) val=no ;;
            *) val="$def" ;;
        esac
        comp_save_default "$c" "$val"
        [ "$val" = yes ] && choices="$choices $c"
    done
    echo
    log "Selected components:${choices:- (none)}"
    [ -n "$choices" ] || { log "Nothing selected; aborting"; return 130; }
    flatten_selection "$choices"
    log "Planned run list:$RUN_LIST"
    printf 'Start build now? [Y/n] : '; read -r go || exit 130
    case "${go,,}" in n|no|0) log "Aborted by user"; return 130 ;; esac
    build_selection "$choices" run
}

component_build() {
    # Entry point shared by the no-arg default, 'menu', and --flag invocations.
    BUILD_COMP="" MODE=run
    if [ $# -eq 0 ] || [ "$1" = menu ]
    then
        menu_select
        return $?
    fi
    local arg
    for arg in "$@"; do
        case "$arg" in
            --all)  BUILD_COMP="$SELECT_ALL" ;;
            --lib32|--wayland|--swayextras|--vulkan|--gaming|--extras|--flatpak|--sddm|--pantheon|--webkit|--plasma|--appimage|--fs|--iso|--music|--lutris|--fastfetch|--pipewire|--programming)
                case " $BUILD_COMP " in *" ${arg#--} "*) : ;; *)
                    BUILD_COMP="$BUILD_COMP ${arg#--}" ;; esac ;;
            --list)
                echo "Available components:"
                for c in $SELECT_ALL; do
                    printf '  --%-10s %s\n' "$c" "$(clabel "$c")"
                done
                echo "  --all       every component (+ final ISO)"
                exit 0 ;;
            --plan) MODE=plan ;;
            *)  log "Unknown option: $arg (try --list)"
                return 1 ;;
        esac
    done
    [ -n "$BUILD_COMP" ] || BUILD_COMP="$SELECT_ALL"
    build_selection "$BUILD_COMP" "$MODE"
}

run() {
    log "== Starting step: $1"
    if ! step_$1
    then log "!! Step '$1' FAILED"
         exit 1
    fi
    log "== Step '$1' done"
}

case "$STEP" in
    menu|-|--*|'')
        # Interactive menu, or --flag component selection. 'menu' / flags arrive
        # here via the STEP var; a bare default (STEP=all) is caught below by
        # 'all' unless the user explicitly passed 'menu' or a --flag.
        component_build "$@"
        ;;
    test)     run test ;;
    proton)   run proton ;;
    sync)     run sync ;;
    aliens)   run aliens ;;
    linux)    run linux ;;
    nvidia)   run nvidia ;;
    nvdiag)   run nvdiag ;;
    glibc32)  run glibc32 ;;
    lib32)    run lib32 ;;
    cmake)    run cmake ;;
    seatd)    run seatd ;;
    tools)    run tools ;;
    wayland)  run wayland ;;
    swayextras) run swayextras ;;
    vulkan)   run vulkan ;;
    steam)    run steam ;;
    winetools) run winetools ;;
    mingw)    run mingw ;;
    winedev)  run winedev ;;
    pycompat) run pycompat ;;
    pyxml)    run pyxml ;;
    core)     run core ;;
    elogind_base) run elogind_base ;;
    flatpak)  run flatpak ;;
    sddm)     run sddm ;;
    extras)   run extras ;;
    lutris)   run lutris ;;
    protonplus) run protonplus ;;
    fastfetch) run fastfetch ;;
    ffxiv)    run ffxiv ;;
    music)    run music ;;
    nodejs)   run nodejs ;;
    go)       run go ;;
    odin)     run odin ;;
    v)        run v ;;
    network)  run network ;;
    modem)    run network ;;
    devices)  run devices ;;
    phone)    run devices ;;
    pipewire) run pipewire ;;
    pantheon) run pantheon ;;
    webkit)   run webkit ;;
    appimage) run appimage ;;
    fs)       run fs ;;
    plasma)   run plasma ;;
    merge)    run merge ;;
    livefix)
        # Full repair + re-bake in ONE command: step_merge FIRST rebuilds the
        # ISO runtime fixes (ensure_livefix_builds: Glibc 2.44-2 upgrade +
        # ProtonPlus repack), then refreshes work/rootfs from the ISO, then runs
        # step_livefix (apply-live-fixes.sh + gpg chain) on the fresh tree --
        # so the booted ISO actually contains every fix livefix covers.
        log "== Repairing and re-baking the LiveCD (glibc 2.44-2, ProtonPlus, runtime fixes)"
        step_merge
        ;;
    gamekcm)
        # Build ONLY the Game Controller KCM: SDL 2.30.2 (bump over the base
        # 2.0.12 so plasma-desktop's `find_package(SDL2 2.0.16)` gate passes),
        # then an in-place --keep rebuild of Plasma-Desktop 6.7.4 so
        # kcms/gamecontroller compiles. Self-contained: ensure_sdl_kcm syncs
        # both recipes from /mnt/repo and leaves the updated tarball in
        # Packages/ until the next merge.
        log "== Building Game Controller KCM (SDL 2.30.2 + Plasma-Desktop 6.7.4 in-place)"
        ensure_sdl_kcm
        ;;
    pkg)
        [ $# -ge 3 ] || { echo "usage: build.sh pkg <Program> <Version>"; exit 1; }
        compile "$2" "$3" && package "$2" "$3"
        ;;
    pkgkeep)
        # Same-version rebuild into an installed tree (compile_keep skips
        # Pre_Installation_Preparation; plain `pkg` over an indexed package
        # dies in the sandbox). Usage: build.sh pkgkeep <Program> <Version>
        [ $# -ge 3 ] || { echo "usage: build.sh pkgkeep <Program> <Version>"; exit 1; }
        compile_keep "$2" "$3" && package "$2" "$3"
        ;;
    all)
        run proton
        run sync
        run linux
        run nvidia
        run nvdiag
run glibc32
    run fs
    run lib32
        run wayland
        run swayextras
        run vulkan
        run steam
        run winetools
        run mingw
        run winedev
        # ProtonPlus (prebuilt AppImage) ships with the gaming stack.
        run protonplus
        # pycompat repackages Python with a .pth so the booted ISO's Gobo tools
        # (Compile/UseFlags/CheckDependencies) see the Scripts modules under the
        # new python3.11 main interpreter. Must run after winedev (Python built
        # + packaged there) and before merge.
        run pycompat
        # pyxml builds the libxml2 python bindings into the Python 3.11 tree and
        # repackages it (itstool needs `import libxml2`; AppStream hits it).
        run pyxml
        # SDDM has its own step since the refactor (was folded into extras);
        # builds the elogind foundation + ECM + Wayland greeter, feeds pantheon.
        run sddm
run extras
        # FastFetch system-info tool (tiny self-contained prebuilt).
        run fastfetch
        # AppImage tooling is independent of the desktops; nothing builds from it.
        run appimage
        # WebKitGTK (GTK3 4.1 + introspection) for Lutris' web connect dialogs;
        # must land before pantheon so a co-selected pantheon reuses its tarball.
        run webkit
        run pantheon
        run plasma
        # PipeWire system-wide audio server + WirePlumber session manager
        # (build its packages; merge -- via step_livefix section 40 -- wires
        # the /System/Tasks boot task into BootUp/StartLiveCD and disables
        # the old on-demand PulseAudio paths).
        run pipewire
        # Network tooling (iw + ethtool + usb_modeswitch + ModemManager rebuilt
        # with QMI+MBIM backends + BIND dig/host/nslookup).  Its packages are
        # baked into the ISO by 'merge' (recipe set is self-contained; the
        # runtime GoboNet/rfkill/StartLiveCD wiring lives in apply-live-fixes
        # section 41).
        run network
        run merge
        # aliens must run after merge (writes into $B/work/rootfs, which merge wipes)
        run aliens
        ;;
    *) echo "Unknown step: $STEP"; exit 1 ;;
esac

log "== All requested steps finished =="
