#!/bin/bash
# nvidia-580-cleanup-v2.sh
#
# Remove the stale 580.159.04 NVIDIA stack remnants now that the whole stack is
# 615.71.09 (Nvidia driver + Nvidia-Utils) with Nvidia-Settings moving to
# 610.57.04.  Keeps the RECIPE dirs (rollback reference) - only removes build
# artifacts and the installed 580 Nvidia-Settings tree.
#
# Root-only and idempotent.  The agent cannot run sudo, so run it yourself:
#     sudo bash /home/nohearth/gobo-build/nvidia-580-cleanup-v2.sh
set -u

GB=/home/nohearth/gobo-build
R="$GB/rootfs"
[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo)"; exit 1; }
[ -d "$R" ] || { echo "no rootfs at $R"; exit 1; }

rm_safe() {
    # rm -rf but refuse anything that is not under the build tree.
    local p="$1"
    case "$p" in
        "$GB"/*) : ;;
        *) echo "REFUSE (outside $GB): $p"; return 0 ;;
    esac
    if [ -e "$p" ] || [ -L "$p" ]; then
        echo "removing $p"
        rm -rf "$p"
    else
        echo "absent  $p"
    fi
}

echo "== Packages/ tarballs (580)"
rm_safe "$GB/Packages/Nvidia--580.159.04--x86_64.tar.bz2"
rm_safe "$GB/Packages/Nvidia-Settings--580.159.04--x86_64.tar.bz2"

echo "== Data/Compile/Archives (580)"
rm_safe "$R/Data/Compile/Archives/NVIDIA-Linux-x86_64-580.159.04.run"
rm_safe "$R/Data/Compile/Archives/nvidia-settings-580.159.04.tar.bz2"

echo "== Data/Compile/Sources (extracted 580 trees)"
rm_safe "$R/Data/Compile/Sources/NVIDIA-Linux-x86_64-580.159.04.run"
rm_safe "$R/Data/Compile/Sources/nvidia-settings-580.159.04"

echo "== Data/Compile/Recipes (staged 580 recipes)"
rm_safe "$R/Data/Compile/Recipes/Nvidia/580.159.04"
rm_safe "$R/Data/Compile/Recipes/Nvidia-Settings/580.159.04"

echo "== installed Programs/Nvidia-Settings/580.159.04"
if [ -L "$R/Programs/Nvidia-Settings/Current" ] && \
   [ "$(readlink "$R/Programs/Nvidia-Settings/Current")" = "580.159.04" ]; then
    echo "removing dangling Current -> 580.159.04 symlink"
    rm -f "$R/Programs/Nvidia-Settings/Current"
fi
rm_safe "$R/Programs/Nvidia-Settings/580.159.04"

# The index still carries a launcher entry pointing into the removed 580
# tree:
#   /usr/share/applications/nvidia-settings.desktop
#     -> /Programs/Nvidia/580.159.04/Shared/applications/nvidia-settings.desktop
# It is a DANGLING symlink now, and every SymlinkProgram run that rebuilds
# the desktop database trips over it:
#   Could not parse file
#   "/Data/Variable/lib/xdg/applications/nvidia-settings.desktop":
#   No such file or directory
# (update-desktop-database, via Rebuild_Desktop_Database). Drop it; the
# current launcher is re-created by the Nvidia-Settings recipe (share/ ->
# /System/Index/share) and by apply-live-fixes.sh 14b1.
echo "== stale index entry for the removed 580 launcher =="
for idx in "$R/usr/share/applications/nvidia-settings.desktop" \
           "$R/System/Index/share/applications/nvidia-settings.desktop"
do
    if [ -L "$idx" ] && [ ! -e "$idx" ]; then
        echo "removing dangling $idx -> $(readlink "$idx")"
        rm -f "$idx"
    elif [ -e "$idx" ]; then
        echo "present (kept): $idx"
    else
        echo "absent: $idx"
    fi
done

echo
echo "== remaining Nvidia* in Packages/ =="
ls -la "$GB/Packages/" 2>/dev/null | grep -i nvidia || echo "  (none)"
echo "== remaining Nvidia* archives =="
ls -la "$R/Data/Compile/Archives/" 2>/dev/null | grep -i nvidia || echo "  (none)"
echo "== Programs/Nvidia-Settings =="
ls -la "$R/Programs/Nvidia-Settings/" 2>/dev/null || echo "  (absent)"
echo
echo "Done.  Build the 610 settings package next:"
echo "    sudo ./run-build.sh nvidia-settings"
