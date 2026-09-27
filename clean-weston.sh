#!/bin/bash
#
# clean-weston.sh — purge ALL stale Weston 13.0.0 build/install state so that
# `pkg Weston 13.0.0` can start from a completely clean slate.
#
# Repeated failed installs leave residual state that meson-install trips over
# inside the UnionSandbox (broken /usr/include|/usr/lib|/usr/share symlinks
# pointing into the not-yet-created /Programs/Weston tree, a partial version
# directory, and stale build Sources/Packages).  This script removes ONLY
# Weston-related artifacts — it never touches anything else.
#
# It operates on BOTH trees (the chroot used by `pkg`, and the staged ISO
# rootfs used by `merge`) so no stale Weston state can leak into the final ISO.
#
# Usage (as root):
#   sudo ./clean-weston.sh
#
# After running, rebuild with:
#   sudo ./run-build.sh sync
#   sudo ./run-build.sh pkg Weston 13.0.0
#
set -euo pipefail

GB=$(cd "$(dirname "$0")" && pwd)
TREES=(
    "$GB/rootfs"
    "$GB/work/rootfs"
)

echo "==> Purging stale Weston state from:"
printf '    %s\n' "${TREES[@]}"
echo

for tree in "${TREES[@]}"; do
    [ -d "$tree" ] || { echo "[skip] $tree (not present)"; echo; continue; }

    # 1) Partial install tree + Current symlink (the root of most residual state).
    #    This removes the leftover .SandboxInstall_Root too.
    rm -rf "$tree/Programs/Weston"

    # 2) Stale entry ANYWHERE under the Gobo system dirs (/usr == System/Index)
    #    that references weston.  These are all broken symlinks (or stray
    #    dirs/files) left by pre-merge install/link failures pointing into the
    #    purged /Programs/Weston tree.  In the UnionSandbox they sit in the ro
    #    lower layer; meson's os.makedirs()/open(...,'wb') follows them to the
    #    missing target and dies with FileNotFoundError/ENOENT (the recurring
    #    "Unhandled python OSError" — once at /usr/include, later at
    #    /usr/lib/pkgconfig, etc.).  Removing every weston-named entry makes the
    #    sandbox see clean lower dirs so meson recreates the real ones.
    #
    #    Targets are matched by NAME ONLY ('weston' or 'libweston' in the
    #    basename) — never by following/altering any other program's data.
    find "$tree/usr" "$tree/System/Index" \
        \( -path "$tree/usr/*" -o -path "$tree/System/Index/*" \) \
        \( -iname '*weston*' -o -iname 'libweston*' \) \
        -mindepth 1 -depth \
        -exec rm -rf -- {} + 2>/dev/null || true

    # 3) The two manifest dirs meson creates fresh (lib/libweston-13 and
    #    include/libweston-13) in case a REAL dir (not a symlink) survives.
    rm -rf "$tree/usr/lib/libweston-13"     "$tree/System/Index/lib/libweston-13"
    rm -rf "$tree/usr/include/libweston-13" "$tree/System/Index/include/libweston-13"
    rm -rf "$tree/usr/share/libweston-13"   "$tree/System/Index/share/libweston-13"

    # 4) Build Sources + any built package tarball (so `pkg` rebuilds, not skips)
    rm -rf "$tree/Data/Compile/Sources"/*weston*
    rm -f  "$tree/Data/Compile/Packages"/Weston--*.tar.bz2

    echo "[ok] $tree"
    echo
done

echo "==> Done.  Rebuild with:"
echo "    sudo $GB/run-build.sh sync"
echo "    sudo $GB/run-build.sh pkg Weston 13.0.0"
