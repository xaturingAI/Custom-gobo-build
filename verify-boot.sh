#!/bin/bash
# Boot-test the LiveCD initramfs: the guest MUST be able to read the boot
# medium.
#
# A broken initramfs still boots the kernel and still runs dracut's init, but
# the CD-ROM never appears, so dracut waits 240 s for the root device and then
# gives up with
#
#     dracut warning: "/dev/root" does not exist
#
# The only reliable way to catch that is to actually boot the thing: the
# guest must enumerate the CD-ROM (/dev/sr0) and udev must create
# /dev/disk/by-label/<volume-label> for it.
#
# Usage: verify-boot.sh <work-dir> [iso-file]
#   work-dir   directory holding isolinux/kernel and isolinux/initramfs
#   iso-file   boot medium to attach (default: a throw-away probe ISO with
#              the right volume label is generated when xorriso is available)
#
# Exit codes: 0 = the guest sees the boot medium, 1 = it does not,
#              2 = the test could not be run (no qemu) -> not a failure.

set -u

WORK="${1:?usage: verify-boot.sh <work-dir> [iso-file]}"
ISO="${2:-}"

KERNEL="$WORK/isolinux/kernel"
INITRD="$WORK/isolinux/initramfs"
LABEL="GOBOLINUX_LIVE_INSTALLER"

[ -f "$KERNEL" ] || { echo "verify-boot: no kernel at $KERNEL"; exit 2; }
[ -f "$INITRD" ] || { echo "verify-boot: no initramfs at $INITRD"; exit 2; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "verify-boot: qemu-system-x86_64 not available - skipping the boot test"
    exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A probe medium: any ISO with the right volume label makes dracut's
# dmsquash-live look for the label.  The guest only has to ENUMERATE it.
if [ -z "$ISO" ]; then
    if ! command -v xorriso >/dev/null 2>&1; then
        echo "verify-boot: no iso given and no xorriso - skipping the boot test"
        exit 2
    fi
    mkdir -p "$TMP/probe"
    echo "probe" > "$TMP/probe/probe.txt"
    ISO="$TMP/probe.iso"
    xorriso -as mkisofs -V "$LABEL" -o "$ISO" "$TMP/probe" >/dev/null 2>&1 || {
        echo "verify-boot: could not build the probe ISO"
        exit 2
    }
fi

LOG="$TMP/serial.log"
CMDLINE="root=live:LABEL=$LABEL Boot=LiveCD rd.live.image rd.live.dir=/ \
rd.live.squashimg=gobolinux-live.squashfs rd.live.overlay.overlayfs \
rd.debug console=tty0 console=ttyS0,115200n8"

timeout 90 qemu-system-x86_64 \
    -m 2048 -smp 1 -enable-kvm \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "$CMDLINE" \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -display none -serial "file:$LOG" >/dev/null 2>&1

if [ ! -s "$LOG" ]; then
    echo "verify-boot: the guest produced no console output at all - the"
    echo "            kernel is not reaching the initramfs"
    exit 1
fi

if grep -qa "DEVNAME=/dev/sr0" "$LOG" || \
   grep -qa "by-label/$LABEL" "$LOG" || \
   grep -qa "/dev/sr0" "$LOG"; then
    echo "verify-boot: OK - the guest enumerated the boot medium (/dev/sr0)"
    exit 0
fi

echo "verify-boot: FAIL - the guest never saw the boot medium."
echo "             dracut will wait 240 s and then die with"
echo '             dracut warning: "/dev/root" does not exist'
echo "             (initramfs: $INITRD)"
cp "$LOG" "${TMP%/}/../verify-boot-serial.log" 2>/dev/null || true
for f in "$TMP"/../verify-boot-serial.log ./verify-boot-serial.log; do
    [ -f "$f" ] && { echo "             guest log: $f"; break; }
done
exit 1
