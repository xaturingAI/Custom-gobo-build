#!/bin/bash
# zfs45.sh - GoboLinux ZFS-on-root support for the custom SysVinit runtime.
#
# Patches a tree (repo rootfs/ or work/rootfs) so that an ISO install on a ZFS
# root actually boots AND has working swap:
#
#   1. OpenZFS 90zfs dracut module: guard the systemd-units branch (Gobo does
#      not ship OpenZFS systemd units) and anchor zpool/zfs/mount.zfs/zgenhostid
#      into the initramfs /sbin (Gobo binaries live under /Programs behind the
#      /System/Index farm, unreachable from the initramfs PATH otherwise).
#   2. GenGrubConf: detect a ZFS root, emit root=zfs:<dataset> boot=zfs on every
#      kernel line, and point every entry at the ACTUAL shipped initramfs image
#      (grub-mkconfig 10_linux misses initramfs-<release>.img when the release
#      carries a -Gobo suffix - this also fixes initrd-less plain installs).
#   3. WriteBoot64: always pass --add zfs to dracut so hostonly initramfs builds
#      keep ZFS root working after kernel upgrades.
#   4. BootUp (custom SysVinit): settle udev before `swapon -a` so the swap zvol
#      node /dev/zvol/rpool/SWAP exists.
#   5. Installer: apply the goboLinuxInstaller-xfs-zfs.patch (pool creation) and
#      swap-file -> swap zvol support (ZFS cannot back a swap file).
#
# Idempotent. Usage:
#   zfs45.sh <tree>            e.g. zfs45.sh work/rootfs  (run as root)
#   zfs45.sh /path/to/rootfs
set -u
TREE="${1:?usage: zfs45.sh <rootfs-tree>}"
SELF="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MARK="gobo livefix 45"

say() { echo "[zfs45] $*"; }
warn() { echo "[zfs45] WARN: $*"; }

[ -d "$TREE/Programs" ] || { warn "no Programs dir in $TREE"; exit 1; }

OZ="$(readlink -f "$TREE/Programs/OpenZFS/Current" 2>/dev/null || echo "$TREE/Programs/OpenZFS/2.4.4")"
CT="$(readlink -f "$TREE/Programs/ConfigTools/Current" 2>/dev/null || echo "$TREE/Programs/ConfigTools/017.01")"
LX="$(readlink -f "$TREE/Programs/Linux/Current" 2>/dev/null || echo "$TREE/Programs/Linux/7.2.5")"
INST="$TREE/Programs/Installer/017.01/bin/GoboLinuxInstaller"
BU="$TREE/Programs/BootScripts/Settings/BootScripts/BootUp"

# ---------------------------------------------------------------- installer ---
# 5a) ZFS pool support (user's Installer fork patch), applied BEFORE the swap edit.
if [ -f "$INST" ] && ! grep -q "zpool create" "$INST"; then
    if command -v patch >/dev/null 2>&1 && [ -f "$SELF/goboLinuxInstaller-xfs-zfs.patch" ]; then
        if ( cd "$TREE/Programs/Installer/017.01" && patch -p1 --forward --batch < "$SELF/goboLinuxInstaller-xfs-zfs.patch" ); then
            say "installer: applied goboLinuxInstaller-xfs-zfs.patch (ZFS pool support)"
        else
            warn "installer: fork patch application failed"
        fi
    else
        warn "installer: patch binary or goboLinuxInstaller-xfs-zfs.patch missing; fork patch skipped"
    fi
elif [ -f "$INST" ]; then
    say "installer: ZFS pool support already present"
fi

# ------------------------------------------------------------------ python ---
python3 - "$OZ" "$CT" "$LX" "$INST" "$BU" <<'ZFS45_PY'
import os
import sys

MARK = "gobo livefix 45"
OZ, CT, LX, INST, BU = sys.argv[1:6]


def patch_module_setup(sh):
    if MARK in sh:
        return sh, False
    a = '\tif dracut_module_included "systemd"; then'
    b = '\tif dracut_module_included "systemd" && [ -f "${systemdsystemunitdir}/zfs-import.target" ]; then'
    assert a in sh, "guard anchor not found"
    sh = sh.replace(a, b, 1)
    a = '\tinst_hook cmdline 95 "${moddir}/parse-zfs.sh"'
    wire = """\t# GoboLinux boots with a custom SysVinit runtime: OpenZFS binaries live
\t# under /Programs/.../bin behind the /System/Index symlink farm, and dracut
\t# copies the resolved real file into the initramfs at its /Programs path - which
\t# is NOT on the initramfs PATH. Anchor the toolchain into /sbin so the classic
\t# import/mount hooks below can actually find it.
\tfor _tool in zpool zfs mount.zfs zgenhostid; do
\t\t_real="$(command -v "${_tool}" | xargs -r readlink -f)"
\t\tif [ -n "${_real}" ] && [ -x "${_real}" ]; then
\t\t\tinst "${_real}" "/sbin/${_tool}" || {
\t\t\t\tdfatal "Failed to install ${_tool} into initramfs /sbin"
\t\t\t\texit 1
\t\t\t}
\t\telse
\t\t\tdfatal "ZFS tool ${_tool} not found; cannot build a ZFS initramfs"
\t\t\texit 1
\t\tfi
\tdone

"""
    assert a in sh, "hook anchor not found"
    sh = sh.replace(a, wire + a, 1)
    sh = sh.replace('#!/usr/bin/env bash\n',
                    '#!/usr/bin/env bash\n# ' + MARK + ': make 90zfs work on the SysVinit hierarchy\n', 1)
    return sh, True


def patch_gen_grub_conf(py):
    if MARK in py:
        return py, False
    a = '\t\tself.data = None'
    b = '\t\tself.zfs_root = None\n\t\tself.data = None'
    assert a in py, "init anchor not found"
    py = py.replace(a, b, 1)
    a = '\t\tcmd_env["GRUB_CMDLINE_LINUX"] = "vt.default_utf8=1 brd.rd_nr=0 hid_apple.iso_layout=0 hid_apple.fnmode=2 video=LVDS-1:e video=HDMI-1:e video=VGA=1:e rootwait net.ifnames=0"\n\t\tsubprocess.Popen(["grub-mkconfig", "-o", self.grubconf], env=cmd_env).wait()'
    b = ('\t\tcmd_env["GRUB_CMDLINE_LINUX"] = "vt.default_utf8=1 brd.rd_nr=0 hid_apple.iso_layout=0 '
         'hid_apple.fnmode=2 video=LVDS-1:e video=HDMI-1:e video=VGA=1:e rootwait net.ifnames=0"\n'
         '\t\tself.zfs_root = self.zfsRootDataset()\n'
         '\t\tif self.zfs_root :\n'
         '\t\t\tcmd_env["GRUB_CMDLINE_LINUX"] += " root=zfs:{} boot=zfs".format(self.zfs_root)\n'
         '\t\tsubprocess.Popen(["grub-mkconfig", "-o", self.grubconf], env=cmd_env).wait()')
    assert a in py, "makeConfig anchor not found"
    py = py.replace(a, b, 1)
    a = '\t\tself.__uuid2partuuid()'
    b = '\t\tself.__uuid2partuuid()\n\t\tself.__fixZfsRoot()\n\t\tself.__ensureInitrd()'
    assert a in py, "chain anchor not found"
    py = py.replace(a, b, 1)
    a = 'def main():'
    methods = """\tdef zfsRootDataset(self) :
\t\ttry :
\t\t\tsource = subprocess.check_output(["findmnt", "-no", "SOURCE", "/"]).decode("utf-8").strip("\\n")
\t\texcept Exception :
\t\t\treturn None
\t\tif not source or source.startswith("/") :
\t\t\treturn None
\t\tpool = source.split("/")[0]
\t\ttry :
\t\t\tname = subprocess.check_output(["zpool", "list", "-H", "-o", "name", pool]).decode("utf-8").strip("\\n")
\t\texcept Exception :
\t\t\treturn None
\t\treturn source if name == pool else None

\tdef __fixZfsRoot(self) :
\t\tif self.zfs_root is None :
\t\t\treturn
\t\tout = []
\t\tinsmod_done = False
\t\tboot_param = "root=zfs:{} boot=zfs".format(self.zfs_root)
\t\tfor raw in self.data.split("\\n") :
\t\t\tline = raw
\t\t\tfirst = line.strip().split(" ", 1)[0] if line.strip() else ""
\t\t\tif first == "linux" :
\t\t\t\trow = [tok for tok in line.split() if not tok.startswith("root=")]
\t\t\t\tline = " ".join(row) + " " + boot_param
\t\t\tout.append(line)
\t\t\tif first == "menuentry" and not insmod_done :
\t\t\t\tout.append("\\tinsmod zfs")
\t\t\t\tinsmod_done = True
\t\tself.data = "\\n".join(out) + "\\n"

\tdef __ensureInitrd(self) :
\t\t# grub-mkconfig 10_linux only emits an initrd line for an image named
\t\t# exactly initramfs-${version}.img. Gobo bakes initramfs-<release>.img and
\t\t# releases often carry a "-Gobo" suffix, so 10_linux misses it and the entry
\t\t# would boot with no initramfs at all. Point every kernel entry at the
\t\t# actual image that shipped instead.
\t\tboot_dir = "/System/Kernel/Boot"
\t\ttry :
\t\t\timages = sorted(n for n in os.listdir(boot_dir) if n.startswith("initramfs-") and n.endswith(".img"))
\t\texcept Exception :
\t\t\timages = []
\t\tif not images :
\t\t\treturn
\t\tinitramfs = images[-1]
\t\tout = []
\t\tfor raw in self.data.split("\\n") :
\t\t\tline = raw
\t\t\tfirst = line.strip().split(" ", 1)[0] if line.strip() else ""
\t\t\tif first == "initrd" :
\t\t\t\tcontinue
\t\t\tout.append(line)
\t\t\tif first == "linux" :
\t\t\t\tindent = line[:len(line) - len(line.lstrip())]
\t\t\t\tout.append("{}initrd /{}/{}".format(indent, boot_dir.strip("/"), initramfs))
\t\tself.data = "\\n".join(out) + "\\n"

"""
    assert a in py, "def main anchor not found"
    py = py.replace(a, methods + a, 1)
    py = py.replace('#!/usr/bin/env python3\n',
                    '#!/usr/bin/env python3\n# ' + MARK + ': ZFS root + installed-initramfs fixes\n', 1)
    return py, True


def patch_write_boot64(sh):
    if MARK in sh:
        return sh, False
    a = '      --stdlog 2 \\\n      --install-optional /usr/libexec/elogind-uaccess-command'
    b = '      --stdlog 2 \\\n      --install-optional /usr/libexec/elogind-uaccess-command \\\n      --add zfs    # ' + MARK
    assert a in sh, "dracut args anchor not found"
    sh = sh.replace(a, b, 1)
    return sh, True


def patch_bootup(bu):
    if MARK in bu:
        return bu, False
    a = 'Exec "Activating all swap files/partitions..." swapon -a &'
    b = 'Exec "Waiting for udev to settle..."      udevadm settle\n' + a
    assert a in bu, "swapon anchor not found"
    bu = bu.replace(a, b, 1)
    head, _, rest = bu.partition('\n')
    bu = head + '\n# ' + MARK + ': settle before swapon so ZFS swap zvols exist\n' + rest
    return bu, True


def patch_installer(ins):
    if MARK in ins:
        return ins, False
    a = "\tgenFstabParams = ''"
    b = "\tgenFstabParams = ''\n\tswapZvol = False"
    assert a in ins, "genFstabParams anchor not found"
    ins = ins.replace(a, b, 1)
    a = ("\tif installer.getValue('SwapFile') == 1 :\n"
         "\t\tswapFileName = '/Data/Variable/swap'\n"
         "\t\tgenFstabParams += ' --swap-file '+swapFileName\n"
         "\t\tsize = int(installer.getValue('SwapSize'))\n"
         "\t\tsafeRun('dd if=/dev/zero of=%s%s bs=1M count=%d'%(destMountPoint,swapFileName,size))\n"
         "\t\tsafeRun('mkswap %s%s' %(destMountPoint,swapFileName))")
    b = ("\tif installer.getValue('SwapFile') == 1 :\n"
         "\t\tsize = int(installer.getValue('SwapSize'))\n"
         "\t\tif installer.getValue('PartitionType')[1] == 'ZFS' :\n"
         "\t\t\t# ZFS cannot back a swap file (swapon fails on ZFS files). Create a\n"
         "\t\t\t# dedicated swap zvol; Gobo's custom SysVinit activates it via swapon -a.\n"
         "\t\t\tsafeRun('zfs create -V %dM -b 4096 rpool/SWAP'%size)\n"
         "\t\t\tsafeRun('udevadm settle')\n"
         "\t\t\tsafeRun('mkswap /dev/zvol/rpool/SWAP')\n"
         "\t\t\tswapZvol = True\n"
         "\t\telse :\n"
         "\t\t\tswapFileName = '/Data/Variable/swap'\n"
         "\t\t\tgenFstabParams += ' --swap-file '+swapFileName\n"
         "\t\t\tsafeRun('dd if=/dev/zero of=%s%s bs=1M count=%d'%(destMountPoint,swapFileName,size))\n"
         "\t\t\tsafeRun('mkswap %s%s' %(destMountPoint,swapFileName))")
    assert a in ins, "swap block anchor not found"
    ins = ins.replace(a, b, 1)
    a = "\tlines = safeFileReadLines(destMountPoint+'/System/Settings/fstab', logger)"
    b = ("\tif swapZvol :\n"
         "\t\tfstab_path = destMountPoint+'/System/Settings/fstab'\n"
         "\t\tlines = safeFileReadLines(fstab_path, logger)\n"
         "\t\tif not any('/dev/zvol/rpool/SWAP' in line for line in lines) :\n"
         "\t\t\tlines.append('/dev/zvol/rpool/SWAP none swap defaults 0 0')\n"
         "\t\t\tsafeWriteToFile(fstab_path, \"\\n\".join(lines)+\"\\n\", logger)\n")
    assert a in ins, "fstab post anchor not found"
    ins = ins.replace(a, b + a, 1)
    ins = ins.replace('#!/usr/bin/python3\n',
                      '#!/usr/bin/python3\n# ' + MARK + ': ZFS swap zvol support\n', 1)
    return ins, True


def apply(path, tag, fn):
    if not path or not os.path.isfile(path):
        print("[zfs45] skip %s: %s not found" % (tag, path))
        return
    try:
        data = open(path, encoding='utf-8').read()
    except Exception as e:
        print("[zfs45] skip %s: %s" % (tag, e))
        return
    try:
        new, changed = fn(data)
    except AssertionError as e:
        print("[zfs45] ERROR %s: %s" % (tag, e))
        raise SystemExit(1)
    if changed:
        open(path, 'w', encoding='utf-8').write(new)
        print("[zfs45] patched %s" % path)
    else:
        print("[zfs45] ok (already) %s" % path)


apply(OZ + "/lib/dracut/modules.d/90zfs/module-setup.sh", "90zfs module-setup.sh", patch_module_setup)
apply(CT + "/bin/GenGrubConf", "GenGrubConf", patch_gen_grub_conf)
apply(LX + "/bin/WriteBoot64", "WriteBoot64", patch_write_boot64)
apply(BU, "BootUp", patch_bootup)
apply(INST, "GoboLinuxInstaller", patch_installer)
ZFS45_PY

# ----------------------------------------------------------- index symlink ---
OZVER="$(basename "$OZ")"
IDX="$TREE/System/Index/lib/dracut/modules.d/90zfs"
if [ -d "$OZ/lib/dracut/modules.d/90zfs" ]; then
    mkdir -p "$(dirname "$IDX")"
    ln -sfn "/Programs/OpenZFS/$OZVER/lib/dracut/modules.d/90zfs" "$IDX"
    [ "$(readlink "$IDX")" = "/Programs/OpenZFS/$OZVER/lib/dracut/modules.d/90zfs" ] \
        && say "index 90zfs module linked (OpenZFS/$OZVER)"
fi

# optional: mirror the same 90zfs knowledge module used by dracut (harmless)
KSYN="$TREE/System/Index/lib/dracut/modules.d/02zfsexpandknowledge"
if [ -d "$OZ/lib/dracut/modules.d/02zfsexpandknowledge" ]; then
    mkdir -p "$(dirname "$KSYN")"
    ln -sfn "/Programs/OpenZFS/$OZVER/lib/dracut/modules.d/02zfsexpandknowledge" "$KSYN"
fi

say "done: $TREE"