#!/bin/bash
# zfs46.sh - GoboLinux LUKS + XFS + ZFS install support (on top of zfs45.sh).
#
# Patches a tree (repo rootfs/ or work/rootfs) so the Installer can present,
# and actually boot, these root layouts:
#
#   Ext4, XFS, ZFS, LUKS+Ext4, LUKS+XFS, LUKS+ZFS
#
# What it does:
#   1. Installer diskutil: LUKS1 container 'gobo_crypt' (LUKS2's argon2 has no
#      GRUB module in this release, so LUKS1 keeps the bootloader able to read
#      the kernel from an encrypted root). Threads fileSystem into the
#      mount()/unmount() calls (the ZFS branch was previously dead code).
#   2. Installer swap: dedicated ZFS swap zvol for ZFS *and* LUKS+ZFS roots; a
#      swap file elsewhere (ZFS cannot back a swap file).
#   3. Installer fstab/crypttab: write /System/Settings/crypttab for the root
#      container and point the fstab root line at the mapper device; give a ZFS
#      installation the same hostid as the live env (pool import across boots).
#   4. Installer UI: filesystem dropdown + a LUKS passphrase field enabled only
#      when a LUKS filesystem is selected, validated before proceeding.
#   5. GenGrubConf: for LUKS roots emit rd.luks.uuid=... root=/dev/mapper/...,
#      insmod cryptodisk/luks/gcry, composed with the existing ZFS fix.
#   6. WriteBoot64: --add crypt to dracut, dracut-native rd.luks.uuid=, and the
#      crypt/zfs GRUB module set for the UEFI standalone app.
#   7. Installer profiles (Base/Typical): make OpenZFS/CryptSetup/XFSProgs/Dracut
#      always available on installed systems.
#   8. Live-boot ZFS readiness: zfs in UserDefinedModules and a baked hostid
#      (System/Settings/hostid) so zpool create works straight from the ISO.
#
# Idempotent. Usage:
#   zfs46.sh <tree>            e.g. zfs46.sh work/rootfs
set -u
TREE="${1:?usage: zfs46.sh <rootfs-tree>}"
SELF="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MARK="gobo livefix 46"

say() { echo "[zfs46] $*"; }
warn() { echo "[zfs46] WARN: $*"; }

[ -d "$TREE/Programs" ] || { warn "no Programs dir in $TREE"; exit 1; }

INST="$TREE/Programs/Installer/017.01/bin/GoboLinuxInstaller"
CT="$(readlink -f "$TREE/Programs/ConfigTools/Current" 2>/dev/null || echo "$TREE/Programs/ConfigTools/017.01")"
LX="$(readlink -f "$TREE/Programs/Linux/Current" 2>/dev/null || echo "$TREE/Programs/Linux/7.2.5")"

# ------------------------------------------------------------------ python ---
python3 - "$INST" "$CT/bin/GenGrubConf" "$LX/bin/WriteBoot64" <<'ZFS46_PY'
import os
import re
import sys

MARK = "gobo livefix 46"
INST, GENGRUBCONF, WRITEBOOT64 = sys.argv[1:4]


def apply(path, tag, fn):
    if not path or not os.path.isfile(path):
        print("[zfs46] skip %s: %s not found" % (tag, path))
        return
    try:
        data = open(path, encoding="utf-8").read()
    except Exception as e:
        print("[zfs46] skip %s: %s" % (tag, e))
        return
    try:
        new, changed = fn(data)
    except AssertionError as e:
        print("[zfs46] ERROR %s: %s" % (tag, e))
        sys.exit(1)
    if not changed:
        print("[zfs46] ok (already) %s" % path)
        return
    try:
        open(path, "w", encoding="utf-8").write(new)
    except OSError as e:
        print("[zfs46] WARN %s: cannot write %s (%s)" % (tag, path, e))
        return
    print("[zfs46] patched %s" % path)


def patch_installer(py):
    if MARK in py:
        return py, False

    # -- helpers (module level, used by DiskUtility and swap/fstab blocks) -----
    a = "platform = Platform()"
    b = (
        "def underlyingFs(fileSystem) :\n"
        "\treturn fileSystem[fileSystem.find('+')+1:] if fileSystem.startswith('LUKS+') else fileSystem\n"
        "\n"
        "def isLuks(fileSystem) :\n"
        "\treturn fileSystem.startswith('LUKS+') and fileSystem.find('+') > 0\n"
        "\n"
        + a
    )
    assert a in py, "helpers anchor not found"
    py = py.replace(a, b, 1)

    # -- DiskUtility: LUKS helpers + LUKS-aware format/mount/unmount ----------
    a = "\tdef formatPartition(self, partition, fileSystem) :"
    b = (
        "\tdef __luksOpen(self, partition, passphrase) :\n"
        "\t\t# LUKS1: GRUB in the boot images has no argon2 module, so a LUKS2\n"
        "\t\t# container could not be unlocked by the bootloader. Container name\n"
        "\t\t# is fixed so GenGrubConf and GenFstab can find it again.\n"
        "\t\tif os.path.exists('/dev/mapper/gobo_crypt') :\n"
        "\t\t\treturn\n"
        "\t\tpassfile = '/tmp/gobo-luks-passphrase'\n"
        "\t\tf = open(passfile, 'w')\n"
        "\t\tf.write(passphrase or '')\n"
        "\t\tf.close()\n"
        "\t\tos.chmod(passfile, 0o600)\n"
        "\t\tsafeRun('cryptsetup luksFormat --batch-mode --type luks1 --key-file %s /dev/%s' %(passfile,partition), 'cryptsetup luksFormat', 1, self.logger)\n"
        "\t\tsafeRun('cryptsetup open --key-file %s /dev/%s gobo_crypt' %(passfile,partition), 'cryptsetup open', 1, self.logger)\n"
        "\n"
        "\tdef luksClose(self) :\n"
        "\t\tif os.path.exists('/dev/mapper/gobo_crypt') :\n"
        "\t\t\tsafeRun('cryptsetup close gobo_crypt', 'cryptsetup close', 0, self.logger)\n"
        "\n"
        "\tdef formatPartition(self, partition, fileSystem, passphrase = '') :\n"
        "\t\ths_luks = isLuks(fileSystem)\n"
        "\t\tif hs_luks :\n"
        "\t\t\tself.__luksOpen(partition, passphrase)\n"
        "\t\t\tfileSystem = underlyingFs(fileSystem)\n"
        "\t\t\tpartition = 'mapper/gobo_crypt'\n"
    )
    assert a in py, "formatPartition anchor not found"
    py = py.replace(a, b, 1)

    a = (
        "\tdef mount(self, partition, destMountPoint, fileSystem = '') :\n"
        "\t\tif not os.path.exists(destMountPoint) :\n"
        "\t\t\tos.makedirs(destMountPoint)\n"
    )
    b = a + "\t\tif isLuks(fileSystem) :\n\t\t\tfileSystem = underlyingFs(fileSystem)\n\t\t\tpartition = 'mapper/gobo_crypt'\n"
    assert a in py, "mount anchor not found"
    py = py.replace(a, b, 1)

    a = (
        "\tdef unmount(self, partition, destMountPoint, fileSystem = '') :\n"
        "\t\t#log(tr('Unmounting selected root partition %s...' %partition))\n"
        "\t\tif fileSystem == 'ZFS' :\n"
    )
    b = (
        "\tdef unmount(self, partition, destMountPoint, fileSystem = '') :\n"
        "\t\t#log(tr('Unmounting selected root partition %s...' %partition))\n"
        "\t\ths_luks = isLuks(fileSystem)\n"
        "\t\tif hs_luks :\n"
        "\t\t\tfileSystem = underlyingFs(fileSystem)\n"
        "\t\tif fileSystem == 'ZFS' :\n"
    )
    assert a in py, "unmount anchor not found"
    py = py.replace(a, b, 1)
    a = (
        "\t\telse :\n"
        "\t\t\tcmd = 'umount ' + destMountPoint\n"
        "\t\tsafeRun(cmd)\n"
        "\n"
        "\n"
        "class BootLoader :"
    )
    b = (
        "\t\telse :\n"
        "\t\t\tcmd = 'umount ' + destMountPoint\n"
        "\t\tsafeRun(cmd)\n"
        "\t\tif hs_luks :\n"
        "\t\t\tself.luksClose()\n"
        "\n"
        "\n"
        "class BootLoader :"
    )
    assert a in py, "unmount close anchor not found"
    py = py.replace(a, b, 1)

    # -- thread fileSystem through the install flow ----------------------------
    a = "\trootPartition = rootPartitionName()"
    b = "\trootPartition = rootPartitionName()\n\tfileSystem = installer.getValue('PartitionType')[1]"
    assert a in py, "rootPartition anchor not found"
    py = py.replace(a, b, 1)

    a = "\t\tdiskutil.formatPartition(rootPartition, installer.getValue('PartitionType')[1])"
    b = "\t\tdiskutil.formatPartition(rootPartition, fileSystem, installer.getValue('EncryptionPassphrase'))"
    assert a in py, "format call anchor not found"
    py = py.replace(a, b, 1)

    a = "\tdiskutil.mount(rootPartition, destMountPoint)"
    assert a in py, "mount call anchor not found"
    py = py.replace(a, "\tdiskutil.mount(rootPartition, destMountPoint, fileSystem)", 1)

    a = "\tdiskutil.unmount(rootPartition, destMountPoint)"
    assert a in py, "unmount call anchor not found"
    py = py.replace(a, "\tdiskutil.unmount(rootPartition, destMountPoint, fileSystem)", 1)

    # -- GRUB core modules: cryptodisk must be embedded so the bootloader can
    #    unlock an encrypted root before it can even read the kernel/initramfs.
    a = "grub_modules = 'normal part_gpt part_msdos multiboot biosdisk nativedisk fat zfs'"
    b = "grub_modules = 'normal part_gpt part_msdos multiboot biosdisk nativedisk fat zfs cryptodisk crypto luks gcry_rijndael gcry_sha256'"
    assert a in py, "grub_modules anchor not found"
    py = py.replace(a, b, 1)

    a = "--modules=\"part_gpt part_msdos iso9660 all_video efi_gop efi_uga video_cirrus gfxterm gettext font zfs\""
    b = "--modules=\"part_gpt part_msdos iso9660 all_video efi_gop efi_uga video_cirrus gfxterm gettext font zfs cryptodisk crypto luks gcry_rijndael gcry_sha256\""
    assert a in py, "efi standalone modules anchor not found"
    py = py.replace(a, b, 1)

    # -- swap: zvol for ZFS roots, file otherwise ------------------------------
    pat = re.compile(
        r"\tgenFstabParams = ''\n(.*?)\n\t############################################################################\n\t# Create fstab",
        re.S,
    )
    new_swap = (
        "\tgenFstabParams = ''\n"
        "\tswapZvol = False\n"
        "\tif installer.getValue('SwapFile') == 1 :\n"
        "\t\tsize = int(installer.getValue('SwapSize'))\n"
        "\t\tif underlyingFs(fileSystem) == 'ZFS' :\n"
        "\t\t\t# ZFS cannot back a swap file (swapon fails on ZFS files). Create a\n"
        "\t\t\t# dedicated swap zvol; Gobo's custom SysVinit activates it via swapon -a.\n"
        "\t\t\tsafeRun('zfs create -V %dM -b 4096 rpool/SWAP' %size)\n"
        "\t\t\tsafeRun('udevadm settle')\n"
        "\t\t\tsafeRun('mkswap /dev/zvol/rpool/SWAP')\n"
        "\t\t\tswapZvol = True\n"
        "\t\telse :\n"
        "\t\t\tswapFileName = '/Data/Variable/swap'\n"
        "\t\t\tgenFstabParams += ' --swap-file '+swapFileName\n"
        "\t\t\tsafeRun('dd if=/dev/zero of=%s%s bs=1M count=%d' %(destMountPoint,swapFileName,size))\n"
        "\t\t\tsafeRun('mkswap %s%s' %(destMountPoint,swapFileName))"
    )
    py, n = pat.subn(new_swap + "\n\t############################################################################\n\t# Create fstab", py, count=1)
    assert n == 1, "swap block not rewritten"

    # -- fstab/crypttab/hostid for LUKS and ZFS roots --------------------------
    a = "\tlines = safeFileReadLines(destMountPoint+'/System/Settings/fstab', logger)"
    b = (
        "\tif isLuks(fileSystem) :\n"
        "\t\t# Tell dracut (and hostonly initramfs rebuilds) about the root\n"
        "\t\t# container and point the fstab root line at the mapper device so\n"
        "\t\t# the installed system mounts the unlocked volume, not the raw one.\n"
        "\t\tuuid_lines = safeRun('cryptsetup luksUUID /dev/%s' %rootPartition, 'cryptsetup luksUUID', 0, logger)\n"
        "\t\tluks_uuid = uuid_lines[-1].strip() if uuid_lines else ''\n"
        "\t\tif luks_uuid :\n"
        "\t\t\tcrypttab = 'gobo_crypt UUID=%s none luks\\n' %luks_uuid\n"
        "\t\t\tsafeWriteToFile(destMountPoint+'/System/Settings/crypttab', crypttab, logger)\n"
        "\t\tif underlyingFs(fileSystem) != 'ZFS' :\n"
        "\t\t\tfstab_lines = safeFileReadLines(destMountPoint+'/System/Settings/fstab', logger)\n"
        "\t\t\troot_idx = next((i for i, l in enumerate(fstab_lines) if l and not l[0] in '# \\t' and len(l.split()) > 1 and l.split()[1] == '/'), None)\n"
        "\t\t\tmapper_root = '/dev/mapper/gobo_crypt / %s defaults 0 1' %underlyingFs(fileSystem).lower()\n"
        "\t\t\tif root_idx is not None :\n"
        "\t\t\t\tfstab_lines[root_idx] = mapper_root\n"
        "\t\t\telse :\n"
        "\t\t\t\tfstab_lines.append(mapper_root)\n"
        "\t\t\tsafeWriteToFile(destMountPoint+'/System/Settings/fstab', \"\\n\".join(fstab_lines)+\"\\n\", logger)\n"
        "\tif underlyingFs(fileSystem) == 'ZFS' :\n"
        "\t\t# zpool create fails without a hostid. Give the installed system the\n"
        "\t\t# same hostid as the live env so the pool stays importable across boots.\n"
        "\t\tif not os.path.exists(destMountPoint+'/System/Settings/hostid') and os.path.exists('/System/Settings/hostid') :\n"
        "\t\t\tsafeRun('cp /System/Settings/hostid %s/System/Settings/hostid' %destMountPoint, 'hostid', 0, logger)\n"
        "\n"
        "\tif swapZvol :\n"
        "\t\tfstab_path = destMountPoint+'/System/Settings/fstab'\n"
        "\t\tlines = safeFileReadLines(fstab_path, logger)\n"
        "\t\tif not any('/dev/zvol/rpool/SWAP' in line for line in lines) :\n"
        "\t\t\tlines.append('/dev/zvol/rpool/SWAP none swap defaults 0 0')\n"
        "\t\t\tsafeWriteToFile(fstab_path, \"\\n\".join(lines)+\"\\n\", logger)\n"
    )
    assert a in py, "fstab response anchor not found"
    py = py.replace(a, b + "\n" + a, 1)

    # -- UI: filesystem dropdown + LUKS passphrase field -----------------------
    a = "deviceSelection.addList('PartitionType', tr('File system'), (['Ext4'], 'Ext4'), tr('Which kind of file system should be used to format the root partition.') )"
    b = (
        "def doFileSystemChanged() :\n"
        "\tinstaller.setEnabled('EncryptionPassphrase', 1 if isLuks(installer.getValue('PartitionType')[1]) else 0)\n"
        "\n"
        "FSTYPES = ['Ext4', 'XFS', 'ZFS', 'LUKS+Ext4', 'LUKS+XFS', 'LUKS+ZFS']\n"
        "deviceSelection.addList('PartitionType', tr('File system'), (FSTYPES, 'Ext4'), tr('Which kind of file system should be used to format the root partition.'), doFileSystemChanged)\n"
        "deviceSelection.addPassword('EncryptionPassphrase', tr('LUKS passphrase'), '', tr('Passphrase used to encrypt the root partition (only for LUKS file systems).'))\n"
        "deviceSelection.setEnabled('EncryptionPassphrase', 0)"
    )
    assert a in py, "dropdown anchor not found"
    py = py.replace(a, b, 1)

    a = (
        "def deviceSelectionComplete() :\n"
        "\tupdateBootloaderTargets()\n"
        "\treturn showSelectedSetSize()"
    )
    b = (
        "def deviceSelectionComplete() :\n"
        "\tupdateBootloaderTargets()\n"
        "\tif installer.getValue('DoFormat') and isLuks(installer.getValue('PartitionType')[1]) and not installer.getValue('EncryptionPassphrase') :\n"
        "\t\tinstaller.showMessageBox(tr('Please type the passphrase for the encrypted root partition.'), ['Ok'])\n"
        "\t\treturn False\n"
        "\treturn showSelectedSetSize()"
    )
    assert a in py, "deviceSelectionComplete anchor not found"
    py = py.replace(a, b, 1)

    py = py.replace(
        "#!/usr/bin/python3\n",
        "#!/usr/bin/python3\n# " + MARK + ": LUKS + XFS + ZFS install support\n",
        1,
    )
    return py, True


def patch_gen_grub_conf(py):
    if MARK in py:
        return py, False
    a = "\t\tself.__uuid2partuuid()\n\t\tself.__fixZfsRoot()"
    b = "\t\tself.__uuid2partuuid()\n\t\tself.__fixLuksRoot()\n\t\tself.__fixZfsRoot()"
    assert a in py, "makeConfig chain anchor not found"
    py = py.replace(a, b, 1)

    a = "def main():"
    methods = (
        "\tdef luksRoot(self) :\n"
        "\t\t# Returns (mapper_name, luks_uuid) of the root LUKS container, or\n"
        "\t\t# None. The installer writes crypttab with the fixed container name\n"
        "\t\t# 'gobo_crypt' whenever the root filesystem is LUKS-encrypted.\n"
        "\t\ttry :\n"
        "\t\t\tlines = open('/System/Settings/crypttab').read().splitlines()\n"
        "\t\texcept Exception :\n"
        "\t\t\treturn None\n"
        "\t\tfor line in lines :\n"
        "\t\t\tentry = [t for t in line.split() if t and not t.startswith('#')]\n"
        "\t\t\tif len(entry) >= 2 and entry[0] == 'gobo_crypt' and entry[1].startswith('UUID=') :\n"
        "\t\t\t\treturn entry[0], entry[1].split('=', 1)[1]\n"
        "\t\treturn None\n"
        "\n"
        "\tdef __fixLuksRoot(self) :\n"
        "\t\t# For a LUKS root: drop whatever grub-mkconfig emitted and pin the\n"
        "\t\t# kernel command line to the mapper device + dracut rd.luks.uuid=,\n"
        "\t\t# and make GRUB able to unlock it (cryptodisk) so it can read the\n"
        "\t\t# kernel and initramfs from the encrypted root.\n"
        "\t\tluks = self.luksRoot()\n"
        "\t\tif luks is None :\n"
        "\t\t\treturn\n"
        "\t\tmapper, luks_uuid = luks\n"
        "\t\tboot_param = 'root=/dev/mapper/{} rd.luks.uuid={}'.format(mapper, luks_uuid)\n"
        "\t\tout = []\n"
        "\t\tinsmod_done = False\n"
        "\t\tfor raw in self.data.split('\\n') :\n"
        "\t\t\tline = raw\n"
        "\t\t\tfirst = line.strip().split(' ', 1)[0] if line.strip() else ''\n"
        "\t\t\tif first == 'linux' :\n"
        "\t\t\t\trow = [tok for tok in line.split() if not tok.startswith('root=') and not tok.startswith('rd.luks.')]\n"
        "\t\t\t\tline = ' '.join(row) + ' ' + boot_param\n"
        "\t\t\tout.append(line)\n"
        "\t\t\tif first == 'menuentry' and not insmod_done :\n"
        "\t\t\t\tout.append('\\tinsmod cryptodisk')\n"
        "\t\t\t\tout.append('\\tinsmod luks')\n"
        "\t\t\t\tout.append('\\tinsmod gcry_rijndael')\n"
        "\t\t\t\tout.append('\\tinsmod gcry_sha256')\n"
        "\t\t\t\tinsmod_done = True\n"
        "\t\tself.data = '\\n'.join(out) + '\\n'\n"
        "\n"
    )
    assert a in py, "def main anchor not found"
    py = py.replace(a, methods + a, 1)
    py = py.replace(
        "#!/usr/bin/env python3\n",
        "#!/usr/bin/env python3\n# " + MARK + ": LUKS root support\n",
        1,
    )
    return py, True


def patch_write_boot64(sh):
    if MARK in sh:
        return sh, False
    # The livefix-45 marker may or may not be present on the --add zfs line.
    # The two GRUB/dracut insertions below must NOT carry an inline comment:
    # these lines end with a backslash continuation, and a `# comment` before
    # the backslash would swallow the following argument line.
    m = re.search(r"(\n\s+--add zfs[^\n]*\\)\n", sh)
    assert m, "dracut --add zfs anchor not found"
    sh = sh[: m.end(1)] + "\n      --add crypt \\\n" + sh[m.end(1) + 1:]
    a = "export GRUB_CMDLINE_LINUX=\"root=$partname cryptdevice=UUID=$(boot_partition_uuid):$(basename $partname)\""
    b = "export GRUB_CMDLINE_LINUX=\"root=$partname rd.luks.uuid=$(boot_partition_uuid)\" # " + MARK
    assert a in sh, "cryptdevice anchor not found"
    sh = sh.replace(a, b, 1)
    a = "--modules=\"part_gpt part_msdos iso9660 all_video efi_gop efi_uga video_bochs video_cirrus gfxterm gettext font\""
    b = "--modules=\"part_gpt part_msdos iso9660 all_video efi_gop efi_uga video_bochs video_cirrus gfxterm gettext font zfs cryptodisk luks gcry_rijndael gcry_sha256\""
    assert a in sh, "efi modules anchor not found"
    sh = sh.replace(a, b, 1)
    return sh, True


apply(INST, "GoboLinuxInstaller", patch_installer)
apply(GENGRUBCONF, "GenGrubConf", patch_gen_grub_conf)
apply(WRITEBOOT64, "WriteBoot64", patch_write_boot64)
ZFS46_PY

# ------------------------------------------------------------ install script --
# Make sure the applied Python still parses.
if [ -f "$INST" ]; then
    if python3 -m py_compile "$INST"; then
        say "installer syntax OK"
    else
        warn "installer FAILED to compile"
    fi
fi
if [ -f "$CT/bin/GenGrubConf" ]; then
    if python3 -m py_compile "$CT/bin/GenGrubConf"; then
        say "GenGrubConf syntax OK"
    else
        warn "GenGrubConf FAILED to compile"
    fi
fi

# ------------------------------------------------------------ profiles -------
PROFILES="$TREE/Programs/Installer/017.01/share/Installer/Profiles"
for pf in Base Typical; do
    file="$PROFILES/$pf"
    if [ -f "$file" ]; then
        for pkg in OpenZFS CryptSetup XFSProgs Dracut; do
            if ! grep -qx "$pkg" "$file"; then
                printf '%s\n' "$pkg" >> "$file"
                say "profile $pf: added $pkg"
            fi
        done
    else
        warn "profile $pf not found"
    fi
done

# --------------------------------------------------------- live-boot ZFS -----
# zfs in UserDefinedModules so the module is loaded (and pool importable) right
# at ISO boot; and a baked hostid so `zpool create` works during install.
for bootopt in \
    "$TREE/Programs/BootScripts/017.01/Resources/Defaults/Settings/BootOptions" \
    "$TREE/Programs/BootScripts/Settings/BootOptions"
do
    if [ -f "$bootopt" ] && ! grep -q "^    zfs$" "$bootopt"; then
        sed -i 's/^    fuse$/    fuse\n    zfs/' "$bootopt"
        say "BootOptions: added zfs to UserDefinedModules ($bootopt)"
    fi
done

HOSTID="$TREE/System/Settings/hostid"
# Fixed, deterministic 4-byte hostid shared by the live env and every installed
# system (the installer copies it over on ZFS installs). A constant value keeps
# rebuilds reproducible and lets pools stay importable across the same ISO.
HOSTID_VALUE="6dfa7e42"
python3 -c "import sys; open(sys.argv[1],'wb').write(bytes.fromhex(sys.argv[2]))" "$HOSTID" "$HOSTID_VALUE"
say "System/Settings/hostid baked (0x$HOSTID_VALUE)"

say "done: $TREE"