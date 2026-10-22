#!/bin/bash
# Replicates RefreshLiveCD's ISOFile.create() step on the Arch/CachyOS build host.
# Consumes the merged work tree produced by build.sh 'merge' inside the Gobo chroot:
#   work/rootfs/            merged live filesystem (11 GB)
#   work/isolinux/          kernel, initramfs, isolinux.bin, efiboot.img
# Produces work/gobolinux.iso (+ work/gobolinux-live.squashfs).
#
# Host-health notes:
#   - Runs as your normal user whenever possible; only re-execs itself with
#     sudo if work/ is not writable (it is root-owned after the chroot merge),
#     and gives the finished artifacts back to the invoking user.
#   - Never mounts anything on the host: reads the reference ISO's MBR with dd,
#     builds with mksquashfs/xorriso only. No loop devices, no bind mounts.
#   - Cleans up temp files even on failure; validates the resulting ISO.
#   - Produces a dual BIOS+UEFI hybrid: isohybrid MBR (BIOS) + GPT at LBA1
#     (xorriso -isohybrid-gpt-basdat) so the chainloading GRUB2 in the ESP
#     (isolinux/efiboot.img -> EFI/BOOT/BOOTx64.EFI) can find /isolinux/kernel
#     under UEFI too. The validation block hard-fails if the GPT or the GRUB2
#     EFI payload is ever missing.
set -euo pipefail

# Self-locate so this works for any user/layout.
GB=$(cd "$(dirname "$0")" && pwd)
WORK="$GB/work"
SQUASH="$WORK/gobolinux-live.squashfs"
OUT="$WORK/gobolinux.iso"
REF_ISO="$GB/GoboLinux-017.01-x86_64.iso"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

cleanup() { [ -n "${MBR_TMP:-}" ] && rm -f "$MBR_TMP"; [ -n "${EFI_TMP:-}" ] && rm -f "$EFI_TMP"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------- privileges
if [ "$(id -u)" -ne 0 ] && { [ ! -w "$WORK" ] || [ ! -w "$GB" ]; }; then
    log "work/ is not writable by $(id -un); re-executing with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ---------------------------------------------------------------- preflight
for t in mksquashfs xorriso dd isohybrid ls; do
    command -v "$t" >/dev/null || die "required tool not found: $t"
done
for f in "$WORK/rootfs" \
         "$WORK/isolinux/isolinux.bin" \
         "$WORK/isolinux/efiboot.img" \
         "$WORK/isolinux/initramfs" \
         "$WORK/isolinux/kernel" \
         "$WORK/isolinux/isolinux.cfg"; do
    [ -e "$f" ] || die "missing $f - run the chroot 'merge' step first"
done
grep -q 'rd.live.squashimg=gobolinux-live.squashfs' "$WORK/isolinux/isolinux.cfg" \
    || die "isolinux.cfg does not expect gobolinux-live.squashfs; wrong work tree?"

free_kb=$(df -Pk "$GB" | awk 'NR==2 {print $4}')
tree_kb=$(du -sk "$WORK/rootfs" | awk '{print $1}')
need_kb=$(( tree_kb * 27 / 20 + 204800 ))   # squash + ISO copy + slack
[ "$free_kb" -gt "$need_kb" ] || die "low disk space: need ~$((need_kb/1048576))GiB, have $((free_kb/1048576))GiB"

log "--> Merged rootfs: $(du -sh "$WORK/rootfs" | awk '{print $1}'), $(ls "$WORK/rootfs/Programs" | wc -l) programs"

# ------------------------------------------------------------- kernel cmdline
# Guarantee a serial console mirror so VM diagnostics are always available
# (QEMU `-serial file:LOG`). Idempotent: never duplicates the args.
for cfg in "$WORK"/isolinux/*.cfg; do
    [ -f "$cfg" ] || continue
    grep -q 'console=ttyS0' "$cfg" && continue
    sed -i 's/^\(  *APPEND .*\)$/\1 console=ttyS0,115200n8 console=tty0/' "$cfg"
    log "--> added serial console cmdline to $(basename "$cfg")"
done

# ------------------------------------------------------------- SquashFS
if [ -n "${KEEP_SQUASH:-}" ] && [ -s "$SQUASH" ]; then
    log "--> KEEP_SQUASH set: reusing existing $(du -h "$SQUASH" | awk '{print $1}') squashfs"
else
    log "--> Creating SquashFS filesystem (zstd -15, this takes a while)"
    mksquashfs "$WORK"/rootfs/* "$SQUASH" \
        -comp zstd -noappend -no-sparse -keep-as-directory -Xcompression-level 15
    [ -s "$SQUASH" ] || die "mksquashfs produced no output"
fi

# ------------------------------------------------------------- hybrid MBR
# Prefer the reference ISO's own hybrid MBR (exact match for its isolinux);
# fall back to the syslinux one installed on this host.
MBR_TMP=$(mktemp "$GB/.isohdpfx.XXXXXX")
if [ -f "$REF_ISO" ]; then
    dd if="$REF_ISO" of="$MBR_TMP" bs=432 count=1 status=none
else
    SYS_MBR=/usr/lib/syslinux/bios/isohdpfx.bin
    [ -f "$SYS_MBR" ] || SYS_MBR=/usr/share/syslinux/isohdpfx.bin
    [ -f "$SYS_MBR" ] || die "no isohdpfx.bin found and reference ISO missing"
    dd if="$SYS_MBR" of="$MBR_TMP" bs=432 count=1 status=none
fi

# ------------------------------------------- EFI loader: appended ESP + file
# Ventoy's UEFI ISO path does NOT go through the El Torito record and does NOT
# merely look for a conventional file name. It parses the ISO's partition table
# looking for an actual EFI System Partition, and aborts with
#   "No bootfile found for UEFI! Maybe the image does not support x64 UEFI!"
# when there is none. This ISO used to say "-e isolinux/efiboot.img", which
# points the El Torito record at an ordinary file inside the ISO9660 tree. The
# GPT produced by -isohybrid-gpt-basdat then described only the isohybrid system
# area - there was no ESP anywhere in the image - so Ventoy rejected an ISO that
# was in fact perfectly UEFI-bootable when dd-written or burned. That is exactly
# the failure reported upstream (ventoy/Ventoy#2930: a UEFI-only ISO that boots
# fine when flashed directly but not through Ventoy).
#
# Fix: append efiboot.img as a real EFI System Partition (partition 2, type
# 0xef) and point the El Torito EFI entry at that appended partition via
# --interval:appended_partition_2:all::. This is the standard hybrid-ESP layout
# used by Ventoy-compatible ISOs. The El Torito record is kept working at the
# same time, so dd/burn/ISO-Image-Writer boots are unaffected.
#
# The loader is ALSO staged as /EFI/BOOT/BOOTX64.EFI inside the ISO filesystem,
# which costs nothing and satisfies booters that look for the conventional path.
# The name is spelled BOOTX64.EFI (all caps) on purpose: that is the UEFI-spec
# spelling, and ISO9660 lookups are case-sensitive outside Joliet, so a
# mixed-case BOOTx64.EFI can be invisible to a strict reader.
rm -rf "$WORK/EFI"
if command -v mcopy >/dev/null && mkdir -p "$WORK/EFI/BOOT" \
   && mcopy -i "$WORK/isolinux/efiboot.img" ::/EFI/BOOT/BOOTX64.EFI \
             "$WORK/EFI/BOOT/BOOTX64.EFI" 2>/dev/null; then
    log "--> Staged /EFI/BOOT/BOOTX64.EFI in the ISO ($(du -h "$WORK/EFI/BOOT/BOOTX64.EFI" | awk '{print $1}'))"
else
    rm -rf "$WORK/EFI"
    log "WARNING: could not stage /EFI/BOOT/BOOTX64.EFI; ISO remains UEFI-bootable via the appended ESP + El Torito"
fi

# ------------------------------------------------------------- ISO
TMP_OUT="$OUT.part"
rm -f "$TMP_OUT"
log "--> Generating ISO file..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -R \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr "$MBR_TMP" \
    -input-charset utf-8 \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: \
    -append_partition 2 0xef "$WORK/isolinux/efiboot.img" \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -appid "GoboLinux Live Installer" \
    -V "GOBOLINUX_LIVE_INSTALLER" \
    -publisher "GoboLinux.org" \
    -p "Gobo Himself" \
    -m "$OUT"        -m "gobolinux.iso" \
    -m "$TMP_OUT"    -m "gobolinux.iso.part" \
    -m "$WORK/rootfs" -m "rootfs" \
    -output "$TMP_OUT" \
    "$WORK"
[ -s "$TMP_OUT" ] || die "xorriso produced no output"

# xorriso above already wrote a complete hybrid image (BIOS MBR + GPT with the
# EFI partition). The legacy isohybrid pass is redundant; run it defensively
# but never let it damage the validated xorriso output.
log "--> skipping isohybrid pass (xorriso -isohybrid-gpt-basdat already wrote MBR+GPT)"
mv -f "$TMP_OUT" "$OUT"

# ------------------------------------------------------------- validation
sig=$(dd if="$OUT" bs=2 skip=255 count=1 status=none | od -An -tx1 | tr -d ' \n')
[ "$sig" = "55aa" ] || die "ISO has no hybrid MBR signature (got '$sig')"

# --- UEFI / GRUB2 readiness ---------------------------------------------------
# Booting GRUB2 under UEFI needs BOTH:
#   1. a GPT header at LBA1 (written by xorriso -isohybrid-gpt-basdat, together
#      with the isohybrid MBR). This is the "isohybrid" partition table that
#      lets the chainloading GRUB2 - loaded from the ESP - find /isolinux/kernel
#      and the initramfs on the ISO via its part_gpt/iso9660 modules. Without the
#      GPT, a dd-written USB image will not boot GRUB2 under UEFI.
#      (xorriso labels these partitions "Basic Data" type, matching the upstream
#      GoboLinux image; UEFI firmware boots them either via El Torito on optical
#      media or by scanning the FAT ESP for EFI/BOOT/BOOTX64.EFI on USB.)
#   2. the El Torito EFI image (/isolinux/efiboot.img) that firmware actually
#      loads, carrying EFI/BOOT/BOOTx64.EFI (the GRUB2 EFI loader) + grub.cfg.
gpt=$(dd if="$OUT" bs=512 skip=1 count=1 status=none | head -c 8)
[ "$gpt" = "EFI PART" ] || die "no GPT header at LBA1 (UEFI hybrid missing; needs xorriso -isohybrid-gpt-basdat)"
ne=$(dd if="$OUT" bs=1 skip=$((512 + 80)) count=4 status=none | od -An -tu4 | tr -d ' \n')
[ "${ne:-0}" -gt 0 ] || die "GPT present but declares $ne partition entries (UEFI hybrid empty)"
log "--> UEFI hybrid: GPT header OK, $ne GPT partition entries"

EFI_TMP="$GB/.efiboot.check.img"
xorriso -osirrox on -indev "$OUT" -extract /isolinux/efiboot.img "$EFI_TMP" 2>/dev/null \
    || die "cannot extract /isolinux/efiboot.img (UEFI El Torito image missing)"
grep -aq "BOOTX64" "$EFI_TMP" || die "efiboot.img has no EFI/BOOT/BOOTx64.EFI (GRUB2 EFI loader missing)"
grep -aq "GRUB" "$EFI_TMP"      || die "efiboot.img carries no GRUB2 EFI binary"
log "--> UEFI boot image OK: EFI/BOOT/BOOTx64.EFI (GRUB2) inside efiboot.img"
rm -f "$EFI_TMP"

# ---------------------------------------------------------------------------
# Boot verification: boot the finished ISO and make sure it really reaches
# the live system.
#
# A LiveCD can be structurally perfect and still not boot: the dracut
# initramfs has to find the CD, mount the squashfs and switch root.  When any
# of that breaks, dracut sits in its check_finished loop waiting for /dev/root
# and the ISO appears to hang forever with no visible error.  That is exactly
# what happened with the 7.2.5 rebuild, so the ISO is now booted for real
# before it is declared good.
#
# The boot is driven with -kernel/-initrd (the same pair isolinux loads) so
# that the dracut messages land on the serial port: the ISO's own cmdline
# ends with "console=tty0", and with two consoles registered /dev/console
# points at the last one, so dracut's output would go to the VGA console
# where it cannot be read back.  "console=tty0" is therefore dropped from the
# command line used here; every other option is the ISO's own.
#
# Set GOBOSKIPBOOTTEST=1 to skip this (it needs qemu and ~1 minute).
# ---------------------------------------------------------------------------
boot_test_iso() {
    if [ "${GOBOSKIPBOOTTEST:-0}" = "1" ]; then
        log "NOTE: boot verification skipped (GOBOSKIPBOOTTEST=1)"
        return 0
    fi
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log "NOTE: qemu-system-x86_64 not found; skipping boot verification."
        log "      Boot the ISO manually before shipping it."
        return 0
    fi

    local kern="$WORK/isolinux/kernel" initrd="$WORK/isolinux/initramfs"
    local cfg="$WORK/isolinux/isolinux.cfg"
    [ -f "$kern" ]  || die "boot test: $kern is missing"
    [ -f "$initrd" ] || die "boot test: $initrd is missing"
    [ -f "$cfg" ]   || die "boot test: $cfg is missing"

    # Reuse the ISO's own kernel command line, minus the VGA console so that
    # dracut's userspace output is captured on the serial port.
    local append
    append=$(grep -m1 '^[[:space:]]*APPEND' "$cfg" \
             | sed -e 's/^[[:space:]]*APPEND[[:space:]]*//' \
                   -e 's/[[:space:]]*console=tty0//' \
                   -e 's/[[:space:]]*$//')
    [ -n "$append" ] || die "boot test: could not read the APPEND line from $cfg"

    local logf timeout_s
    logf=$(mktemp /tmp/gobo-boottest.XXXXXX.log)
    timeout_s="${GOBOBOOTTEST_TIMEOUT:-300}"

    log "--> Boot verification: booting $OUT (timeout ${timeout_s}s)"
    # The ISO stays the CD the live system boots from; the kernel and the
    # initramfs are the ones the ISO ships.
    timeout --signal=KILL "$timeout_s" \
        qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
            -kernel "$kern" -initrd "$initrd" -append "$append" \
            -drive "file=$OUT,media=cdrom,readonly=on" \
            -display none -serial "file:$logf" -monitor none \
            >/dev/null 2>&1 || true

    # Success markers.  The first group is dracut switching root, the second
    # is the GoboLinux live system starting up.  The live system is reached
    # well before the desktop appears (it can still be waiting for an answer
    # on the console at that point), so do not look for a desktop marker.
    if grep -aqE 'Switch root|Preparing root device|Mounting /dev/root' "$logf" \
       || grep -aqE 'Running PostInstall for|StartLiveCD|Starting log daemon|Initializing home directory|Starting message bus' "$logf"; then
        log "--> Boot verification PASSED: the ISO reaches the live system"
        rm -f "$logf"
        return 0
    fi

    # Failure markers, most specific first.
    local reason=""
    if grep -aqE 'does not exist' "$logf" && grep -aq '/dev/root' "$logf"; then
        reason="dracut never found the root device (/dev/root)"
    elif grep -aqE 'Kernel panic' "$logf"; then
        reason="the kernel panicked"
    elif grep -aqE 'dracut: FATAL|dracut: Warning' "$logf"; then
        reason="dracut reported a fatal error"
    elif [ ! -s "$logf" ] || [ "$(stat -c%s "$logf")" -lt 64 ]; then
        reason="the guest produced no console output at all"
    else
        reason="the guest did not reach the live system within ${timeout_s}s"
    fi

    log "ERROR: boot verification FAILED: $reason"
    log "       last 40 lines of the serial console:"
    tail -40 "$logf" 2>/dev/null | sed 's/^/       | /'
    log "       full log kept at $logf"
    die "the ISO does not boot - refusing to hand over a broken image"
}

# The EFI loader must ALSO be reachable as a real file in the ISO filesystem,
# not only through the El Torito record. Without this, Ventoy and similar
# loop-mounting boot helpers abort with "No bootfile found for UEFI!!",
# because they never read the El Torito catalog - they just look for the
# conventional EFI/BOOT path inside the mounted image.
if xorriso -indev "$OUT" -find /EFI/BOOT/BOOTX64.EFI 2>/dev/null | grep -qi bootx64; then
    log "--> UEFI loop-mount path OK: /EFI/BOOT/BOOTX64.EFI present in the ISO filesystem"
else
    log "NOTE: /EFI/BOOT/BOOTX64.EFI absent from the ISO filesystem; the appended ESP"
    log "      plus El Torito still boot normally on dd/burn/ISO writers."
fi
# The Ventoy-critical check: an actual EFI System Partition must exist in the
# GPT, not just a GPT with some entries in it. -isohybrid-gpt-basdat alone only
# declares the isohybrid system area, which is what made Ventoy report
# "No bootfile found for UEFI!". Verify the partition type GUID of an appended
# ESP (C12A7328-F81F-11D2-BA4B-00A0C93EC93B) is actually present.
esp=no
esp_tool=""
if command -v fdisk >/dev/null 2>&1; then
    esp_tool=fdisk
elif command -v sgdisk >/dev/null 2>&1; then
    esp_tool=sgdisk
fi
if [ -n "$esp_tool" ]; then
    case "$esp_tool" in
        fdisk)  fdisk -l "$OUT" 2>/dev/null | grep -qiE "EFI System|\bef EFI" && esp=yes ;;
        sgdisk) sgdisk -p "$OUT" 2>/dev/null | grep -qiE "EFI System|\bef EFI" && esp=yes ;;
    esac
    if [ "$esp" = yes ]; then
        log "--> GPT declares an EFI System Partition (Ventoy-compatible layout)"
    else
        die "GPT has no EFI System Partition entry - Ventoy will report 'No bootfile found for UEFI' (needed: -append_partition 2 0xef ...)"
    fi
else
    log "NOTE: neither fdisk nor sgdisk available; could not verify the appended ESP entry."
fi

xorriso -indev "$OUT" -toc 2>/dev/null | grep -q "El Torito" || die "no El Torito boot catalog in ISO"
xorriso -indev "$OUT" -find /gobolinux-live.squashfs 2>/dev/null | grep -q squashfs || die "squashfs missing from ISO"
xorriso -indev "$OUT" -find /isolinux/isolinux.bin 2>/dev/null | grep -q isolinux.bin || die "isolinux.bin missing from ISO"

# Last gate: the image has to actually boot.  Everything above only proves
# that the ISO is structurally sound; a LiveCD can be structurally perfect
# and still hang in dracut waiting for /dev/root.
boot_test_iso

# Give artifacts back to the invoking user so later steps need no sudo.
if [ -n "${SUDO_USER:-}" ]; then
    chown "$SUDO_USER" "$OUT" "$SQUASH" 2>/dev/null || true
fi

log "== Done: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
log "   squashfs: $(du -h "$SQUASH" | awk '{print $1}')"
log "Test in QEMU:  qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm -cdrom $OUT"
log "Write to USB:  sudo dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
