#!/bin/bash
#
# clean-desktop.sh — interactive desktop-environment cleanup for the LiveCD.
#
# Removes a whole desktop environment (program trees, all System/Index|usr
# links pointing into it, its package tarballs, compile sources and synced
# chroot recipe copies) from BOTH staged trees:
#   $GB/rootfs        (the chroot used by `pkg` / `compile`)
#   $GB/work/rootfs   (the staged ISO rootfs used by `merge` / `finalize-iso`)
#
# THE ORDER MATTERS: run this only AFTER `sudo ./run-build.sh merge`, as the
# very last step before finalize-iso.sh.  The merge step wipes work/rootfs and
# re-extracts the base GoboLinux ISO, which ships bare Pantheon session files
# (usr/share/xsessions/pantheon.desktop + wayland-sessions/pantheon.desktop)
# and the elementary theme/wallpaper packages directly -- so any pre-merge
# cleanup is silently undone (the extraction re-creates them as plain regular
# files, not Programs/ symlinks).  Do NOT re-run merge after cleaning.
#
# The login screen (SDDM reads usr/share/xsessions + usr/share/wayland-sessions)
# is then hard-pruned to ONLY show the desktops actually kept:
#   X11     -> plasma (plasmax11/plasma) + awesome  [hard rule]
#   Wayland -> plasma + weston                       [hard rule]
# so no stale session from a previously-removed desktop ever reappears.
#
# It is interactive, in the same Y/N style as the main build file:
#   * one prompt per desktop (pantheon, gnome, sway, awesome, plasma),
#   * an optional per-package KEEP exception (e.g. keep PantheonCode as a
#     standalone code editor, keep Konsole/Dolphin from Plasma, keep SwayBg/
#     SwayIdle/SwayLock extras from the Sway family),
#   * a "really sure?" confirmation that warns removal means a RE-COMPILE if
#     the desktop is wanted back (authoritative recipes live in the canonical
#     BuildLiveCD repo and are restored by `run-build.sh sync`),
#   * a final "apply now?" confirmation before anything is deleted.
#
# Plasma removal is scoped to the desktop-shell packages (Plasma-*, KWin,
# LibPlasma, Konsole, Dolphin, KWindowSystem).  The shared Qt6/KF6/wlroots
# platform libraries are deliberately KEPT — they are dependencies of other
# apps on the ISO - so only the desktop environment's own packages go.
#
# Usage:
#   sudo ./clean-desktop.sh            # interactive cleanup + login prune
#   sudo ./clean-desktop.sh --dry-run  # review the plan without deleting
#   sudo ./clean-desktop.sh --help     # this text
#
# Afterwards:  sudo ./clean-desktop.sh runs AFTER merge; then ./finalize-iso.sh.
# Sequence:   sudo ./run-build.sh merge  ->  [cleanup the ISO here]  ->  ./finalize-iso.sh

set -euo pipefail

GB=$(cd "$(dirname "$0")" && pwd)
TREES=(
    "$GB/rootfs"
    "$GB/work/rootfs"
)

# ---- desktop definitions --------------------------------------------------
# D_PROGS["<desktop>"]    = space-separated program dir names (Programs/)
# D_SOURCES["<desktop>"]  = upstream compile-source dir globs (Sources/)
# KEEP_LABEL["<prog>"]    = human label offered as a "keep this app" option
# KEEP_OF["<prog>"]       = desktop the keepable program belongs to

declare -A D_PROGS D_SOURCES KEEP_LABEL KEEP_OF DESKTOP_LABEL

D_PROGS[pantheon]="
    PantheonApplicationsMenu PantheonCalculator PantheonCalendar PantheonCamera
    PantheonCode PantheonDefaultSettings PantheonFiles PantheonGeoclue2Agent
    PantheonMail PantheonMusic PantheonNotifications PantheonOnboarding
    PantheonPhotos PantheonPolkitAgent PantheonScreenshot PantheonSettingsDaemon
    PantheonShortcutOverlay PantheonSideload PantheonTasks PantheonTerminal
    PantheonVideos PantheonWayland
    Wingpanel WingpanelIndicatorA11y WingpanelIndicatorBluetooth
    WingpanelIndicatorDatetime WingpanelIndicatorKeyboard WingpanelIndicatorNetwork
    WingpanelIndicatorNightlight WingpanelIndicatorNotifications
    WingpanelIndicatorPower WingpanelIndicatorSession WingpanelIndicatorSound
    Switchboard SwitchboardPlugAbout SwitchboardPlugApplications
    SwitchboardPlugBluetooth SwitchboardPlugDatetime SwitchboardPlugDesktop
    SwitchboardPlugDisplay SwitchboardPlugKeyboard SwitchboardPlugLocale
    SwitchboardPlugMouseTouchpad SwitchboardPlugNetwork SwitchboardPlugNotifications
    SwitchboardPlugOnlineAccounts SwitchboardPlugParentalControls
    SwitchboardPlugPower SwitchboardPlugPrinters SwitchboardPlugSecurityPrivacy
    SwitchboardPlugSharing SwitchboardPlugSound SwitchboardPlugUserAccounts
    SwitchboardPlugWacom
    Gala Dock Contractor SessionSettings LightdmPantheonGreeter
"
D_SOURCES[pantheon]="
    pantheon* gala* wingpanel* switchboard* contractor*
    session-settings* dock-* sound-theme* elementary* lightdm-pantheon*
"

D_PROGS[gnome]="GnomeSession GnomeSettingsDaemon Gnome-Desktop GnomeKeyring"
D_SOURCES[gnome]="
    gnome-session* gnome-settings-daemon* gnome-desktop* gnome-keyring*
"

D_PROGS[sway]="Sway SwayBg SwayIdle SwayLock"
D_SOURCES[sway]="sway*"

D_PROGS[awesome]="Awesome"
D_SOURCES[awesome]="awesome*"

D_PROGS[plasma]="
    Plasma-Workspace Plasma-Desktop Plasma-Integration Plasma5Support
    Plasma-Activities Plasma-Activities-Stats Plasma-NM Plasma-PA
    Plasma-Wayland-Protocols KWin KWindowSystem LibPlasma Konsole Dolphin
    KDeplasma-Addons
"
D_SOURCES[plasma]="
    plasma* kwin* kactivities* libplasma* konsole* dolphin*
"

KEEP_LABEL[PantheonCode]="PantheonCode (IDE/code editor)"
KEEP_LABEL[PantheonTerminal]="Pantheon Terminal"
KEEP_LABEL[PantheonFiles]="Pantheon Files (file manager)"
KEEP_LABEL[PantheonCalculator]="Pantheon Calculator"
KEEP_LABEL[PantheonCalendar]="Pantheon Calendar"
KEEP_LABEL[PantheonMail]="Pantheon Mail"
KEEP_LABEL[PantheonMusic]="Pantheon Music"
KEEP_LABEL[PantheonVideos]="Pantheon Videos"
KEEP_LABEL[PantheonPhotos]="Pantheon Photos"
KEEP_LABEL[SwayBg]="SwayBg (wallpaper tool)"
KEEP_LABEL[SwayIdle]="SwayIdle (idle/lock trigger)"
KEEP_LABEL[SwayLock]="SwayLock (screen locker)"
KEEP_LABEL[Konsole]="Konsole (terminal emulator)"
KEEP_LABEL[Dolphin]="Dolphin (file manager)"
KEEP_LABEL[Plasma-NM]="Plasma-NM (network manager applet)"
KEEP_LABEL[Plasma-PA]="Plasma-PA (sound applet)"

for k in "${!KEEP_LABEL[@]}"; do
    for d in pantheon gnome sway awesome plasma; do
        for t in ${D_PROGS[$d]}; do
            [ "$t" = "$k" ] && KEEP_OF[$k]="$d" && break
        done
    done
done

# ---- modes ----------------------------------------------------------------

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
        sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

# ---- helpers --------------------------------------------------------------

ask_yn() {
    # ask_yn "message" < default: y|n >  -> 0 (yes) / 1 (no)
    local msg="$1" def="$2" ans hint
    if [ "$def" = y ]; then hint=Y/n; else hint=y/N; fi
    printf '%s [%s] : ' "$msg" "$hint"
    read -r ans || { echo; return 1; }
    case "${ans,,}" in
        "") [ "$def" = y ] ;;
        y|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

desktop_installed() {
    # any program of the desktop present in either tree?
    local d="$1" tree p
    for tree in "${TREES[@]}"; do
        [ -d "$tree/Programs" ] || continue
        for p in ${D_PROGS[$d]}; do
            [ -d "$tree/Programs/$p" ] && return 0
        done
    done
    return 1
}

remove_program() {
    # remove_program <tree> <program>: program dir + every index entry pointing
    # into it + synced recipe + BOTH package-tarball locations.
    local tree="$1" prog="$2"
    if [ -d "$tree/Programs/$prog" ]; then
        run rm -rf -- "$tree/Programs/$prog"
        run find "$tree/System/Index" "$tree/usr" -lname "/Programs/$prog/*" -delete || true
    fi
    if [ -d "$tree/Data/Compile/Recipes/$prog" ]; then
        run rm -rf -- "$tree/Data/Compile/Recipes/$prog"
    fi
    run find "$GB/Packages" -maxdepth 1 -iname "$prog--*.tar.bz2" -delete || true
    if [ -d "$tree/Data/Compile/Packages" ]; then
        run find "$tree/Data/Compile/Packages" -maxdepth 1 -iname "$prog--*.tar.bz2" -delete || true
    fi
}

prune_login_sessions() {
    # HARD RULE: X11 login shows only plasma + awesome; Wayland shows only
    # plasma + weston.  Anything else at the login screen is removed.
    local tree="$1" f name
    local x11_keep="awesome.desktop plasma.desktop plasmax11.desktop"
    local wl_keep="plasma.desktop weston.desktop"

    for d in usr/share/xsessions System/Index/share/xsessions; do
        [ -d "$tree/$d" ] || continue
        for f in "$tree/$d"/*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            name="$(basename "$f")"
            case " $x11_keep " in *" $name "*) : ;; *)
                echo "    $d/$name"
                run rm -f -- "$f"
                ;;
            esac
        done
    done

    for d in usr/share/wayland-sessions System/Index/share/wayland-sessions; do
        [ -d "$tree/$d" ] || continue
        for f in "$tree/$d"/*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            name="$(basename "$f")"
            case " $wl_keep " in *" $name "*) : ;; *)
                echo "    $d/$name"
                run rm -f -- "$f"
                ;;
            esac
        done
    done
}

run() {
    # array-safe command runner (no shell eval: glob patterns in args stay
    # literal and reach the tool unchanged), or a readable printout under
    # --dry-run.
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] $*"
    else
        "$@"
    fi
}

# ---- interactive selection ------------------------------------------------

DESKTOPS=(pantheon gnome sway awesome plasma)
DESKTOP_LABEL[pantheon]="Pantheon (elementary) desktop"
DESKTOP_LABEL[gnome]="GNOME session/settings stack"
DESKTOP_LABEL[sway]="Sway tiling WM family"
DESKTOP_LABEL[awesome]="Awesome WM"
DESKTOP_LABEL[plasma]="Plasma 6.7 desktop"

declare -A REMOVE
declare -A KEPT

echo "==> Interactive desktop cleanup for the LiveCD"
printf '    Trees: %s\n' "${TREES[@]}"
[ "$DRY_RUN" = 1 ] && echo "    (DRY RUN — nothing will be deleted)"
echo
echo "The login screen hard-keeps: plasma + awesome (X11), plasma + weston (Wayland)."
echo

for d in "${DESKTOPS[@]}"; do
    if ! desktop_installed "$d"; then
        echo "-- ${DESKTOP_LABEL[$d]}: not installed, skipping (n)"
        continue
    fi
    echo "-- ${DESKTOP_LABEL[$d]} is installed."
    if ask_yn "Remove ${DESKTOP_LABEL[$d]} (packages + sessions)?" n; then

        # 1) per-package KEEP exceptions for this desktop
        for p in ${D_PROGS[$d]}; do
            [ "${KEEP_OF[$p]:-}" = "$d" ] || continue
            if ask_yn "  KEEP ${KEEP_LABEL[$p]}?" n; then
                KEPT[$p]=1
                echo "    (will keep $p)"
            fi
        done

        echo
        echo "  Removing ${DESKTOP_LABEL[$d]}:"
        for p in ${D_PROGS[$d]}; do
            [ "${KEPT[$p]:-0}" = 1 ] && continue
            echo "    - $p"
        done

        # 2) "really sure?" with the recompile warning
        echo
        if ask_yn "Really remove ${DESKTOP_LABEL[$d]} from the ISO and build chroot? Recompiling will be needed to add it back. Proceed?" n; then
            REMOVE[$d]=1
            echo "    (queued for removal)"
        else
            echo "    (skipped)"
        fi
    else
        echo "    (kept)"
    fi
    echo
done

# ---- final confirmation, then execute -------------------------------------

if [ "${REMOVE[*]+set}" != set ]; then
    echo "No desktops selected for removal."
else
    echo "==> Queued removals: ${!REMOVE[*]}"
    echo "==> The login-session prune (plasma+awesome / plasma+weston keep rules)"
    echo "    will be applied to both trees."
fi
echo
ask_yn "Apply the removal and login-session prune now?" y || {
    echo "Aborted — no changes made."
    exit 0
}

for tree in "${TREES[@]}"; do
    [ -d "$tree" ] || { echo "[skip] $tree (not present)"; continue; }
    echo
    echo "[$tree]"

    for d in "${!REMOVE[@]}"; do
        echo "  Desktop: ${DESKTOP_LABEL[$d]}"
        for p in ${D_PROGS[$d]}; do
            [ "${KEPT[$p]:-0}" = 1 ] && continue
            remove_program "$tree" "$p"
        done
        # compile sources for the desktop (upstream-name globs)
        if [ -d "$tree/Data/Compile/Sources" ]; then
            # word-split the upstream-name globs WITHOUT shell pathname expansion
            set -o noglob
            for g in ${D_SOURCES[$d]}; do
                run find "$tree/Data/Compile/Sources" -maxdepth 1 -iname "$g" -exec rm -rf -- {} + || true
            done
            set +o noglob
        fi
    done

    echo "  Login-session prune:"
    prune_login_sessions "$tree"
    echo "[ok] $tree"
done

echo
echo "==> Done."
if [ "$DRY_RUN" = 1 ]; then
    echo "Review the plan above, then run without --dry-run to apply."
else
    echo "Selected desktops + stale login sessions are gone from both trees."
fi
echo
echo "> Order: this script must run AFTER 'merge' and BEFORE finalize-iso.sh."
echo "> Do NOT re-run 'run-build.sh merge' afterwards: merge re-extracts the"
echo "> base ISO and would resurrect the pruned desktop sessions."
echo "Next steps:"
echo "    ./finalize-iso.sh"
echo "    sudo $GB/run-build.sh detach   # (if the chroot is mounted)"