#!/bin/bash
# nvidia-sysroot-vulkan-fix.sh -- DEPRECATED, folded into apply-live-fixes.sh
#
# This script used to do ONE thing: turn the target tree's
#   System/Index/share/vulkan/{icd.d,implicit_layer.d,explicit_layer.d}
# into REAL aggregation directories instead of absolute symlinks into a dead
# program dir (/Programs/Mesa/19.3.3/...), and drop the stale nvidia_*
# leftovers that earlier builds had written through those symlinks.
#
# It was run by build.sh's step_livefix right before apply-live-fixes.sh,
# because apply-live-fixes' Vulkan section used to `ln -sf` the NVIDIA ICDs
# into those dirs -- and with the symlink still in place the links landed in
# the dead program dir, where the loader never looks.
#
# That whole job now lives in apply-live-fixes.sh:
#   * section 14e  -> gpu_manifest_dir() turns the manifest dirs into real
#                      aggregation dirs, removes the stale nvidia_* leftovers
#                      and links EVERY driver manifest (NVIDIA, Intel, Mesa,
#                      Vulkan layers, EGL external platforms) from the program
#                      that owns it.
#   * section 19   -> the GLVND EGL vendor dir, now data-driven so no NVIDIA
#                      EGL vendor JSON can be silently dropped again.
#   * the end of the script prints a summary of every manifest dir.
#
# So there is ONE place that owns GPU driver manifests.
#
# This stub stays only so that an old command line (or an old note) does not
# fail confusingly.  It performs no work.
#
# To fix a tree's GPU manifests now, run the real thing on it:
#     sudo bash /home/nohearth/gobo-build/apply-live-fixes.sh <tree>
# or, for the ISO staging tree, just:
#     sudo /home/nohearth/gobo-build/run-build.sh livefix
set -u

cat <<'EOF'
nvidia-sysroot-vulkan-fix.sh: DEPRECATED -- folded into apply-live-fixes.sh.

The Vulkan/EGL manifest fix now runs as part of apply-live-fixes.sh
(sections 14e and 19), which build.sh's step_livefix invokes on the ISO
staging tree.  Nothing was changed by this stub.

Use instead:
    sudo /home/nohearth/gobo-build/run-build.sh livefix
or, for an arbitrary tree:
    sudo bash /home/nohearth/gobo-build/apply-live-fixes.sh <tree>
EOF
exit 0
