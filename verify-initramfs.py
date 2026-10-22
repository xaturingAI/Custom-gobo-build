#!/usr/bin/env python3
"""
Static verifier for the GoboLinux live CD initramfs.

The 017.01 LiveCD initramfs is a two part cpio:

    [ uncompressed early cpio: CPU microcode ]
    [ zstd compressed main cpio: the real initramfs ]

dracut writes a runtime rule into /etc/udev/rules.d/99-live-squash.rules and
relies on udev picking it up to run /sbin/dmsquash-live-root, which is what
creates the live root and /dev/root.  If udev is built with a compiled in
configuration directory that is NOT the one the ISO exposes as /etc/udev, that
rule is never applied, dmsquash-live-root never runs and the boot hangs in
dracut's check_finished loop with:

    dracut warning: "/dev/root" does not exist

The stock 017.01 ISO's udevd has /System/Settings/udev/rules.d compiled in
(/etc is a symlink to System/Settings on the ISO).  A locally rebuilt udev
that was configured with --sysconfdir=$settings_target instead compiles
/Programs/Eudev/<ver>/Resources/Defaults/Settings/udev/rules.d in, silently
drops /etc/udev/rules.d from the scanned directories, and the live CD stops
booting.  This checker reproduces that check offline, without booting.

Usage:
    verify-initramfs.py <initramfs> [--json]

Exit status is 0 when the initramfs is good, 1 otherwise.
"""

import os
import re
import stat
import subprocess
import sys
import tempfile

# The kernel module chain the live CD needs to read the ISO and mount the
# squashfs on it.  Every one of them must be present in modules.dep AND
# resolvable on disk, otherwise the CD is never detected or never mounted.
REQUIRED_MODULES = [
    "ata_piix",   # IDE/ATA controller (PIIX3 on QEMU, most desktop IDE)
    "sr_mod",     # SCSI CD-ROM class driver
    "cdrom",      # CD-ROM character device
    "isofs",      # iso9660 filesystem (the ISO itself)
    "loop",       # loop device (the squashfs image inside the ISO)
    "squashfs",   # the squashfs holding the live system
    "overlay",    # writable overlay on top of the squashfs
    "dm_mod",     # device mapper, used by the dmsquash-live path
]

# Compression magics the kernel understands for an initramfs payload.
COMPRESSION_MAGICS = {
    b"\x28\xb5\x2f\xfd": "zstd",
    b"\x1f\x8b\x08": "gzip",
    b"\xfd7zXZ\x00": "xz",
    b"\x04\x22\x4d\x18": "lz4",
    b"\x89LZO": "lzo",
    b"\x42\x5a\x68": "bzip2",
}


class InitramfsError(Exception):
    pass


def _decompress(data, kind):
    """Decompress a raw compressed stream, returning the decompressed bytes."""
    if kind == "zstd":
        try:
            import zstandard
            return zstandard.ZstdDecompressor().decompress(data, max_output_size=1 << 31)
        except ImportError:
            pass
        with tempfile.NamedTemporaryFile(suffix=".zst") as tmp:
            tmp.write(data)
            tmp.flush()
            out = subprocess.run(["zstd", "-d", "-c", tmp.name],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if out.returncode != 0:
                raise InitramfsError("zstd decompression failed: %s" %
                                     out.stderr.decode("utf-8", "replace").strip())
            return out.stdout
    if kind == "gzip":
        import gzip
        return gzip.decompress(data)
    if kind == "xz":
        import lzma
        return lzma.decompress(data)
    raise InitramfsError("unsupported compression: %s" % kind)


def read_cpio(data):
    """Parse a (possibly concatenated) SVR4 newc archive.

    Returns a dict: name -> (mode, payload).  For symlinks the payload is the
    link target, for regular files it is the content.

    cpio stores the content of a HARDLINKED file only once, in the last
    member of the link group; every other member of that group is stored as a
    zero-length regular file with the same (dev, ino).  dracut hardlinks a lot
    (the same binary ends up under sbin/, usr/lib/... and Programs/.../), so
    a lookup by path can easily land on one of those empty stubs.  The inode
    of every entry is therefore returned as well, so the stubs can be filled
    in from the member that carries the data (see resolve_hardlinks).
    """
    entries = {}
    inodes = {}
    links = {}
    off = 0
    while off + 110 <= len(data):
        if data[off:off + 6] != b"070701":
            break
        fields = [int(data[off + 6 + i * 8: off + 14 + i * 8], 16) for i in range(13)]
        mode, fsize, namesize = fields[1], fields[6], fields[11]
        ino = fields[0]
        dev = (fields[7], fields[8])
        name_start = off + 110
        name = data[name_start:name_start + namesize - 1].decode("utf-8", "replace")
        # The name field is NUL terminated and padded to a 4 byte boundary;
        # the file data follows the padding, not the NUL.
        data_start = (name_start + namesize + 3) & ~3
        if name == "TRAILER!!!":
            off = (data_start + 3) & ~3
            break
        payload = data[data_start:data_start + fsize]
        entries[name] = (mode, payload)
        inodes[name] = (dev, ino)
        if stat.S_ISREG(mode) and fsize > 0:
            links.setdefault((dev, ino), payload)
        off = (data_start + fsize + 3) & ~3
    return entries, off, inodes, links


def resolve_hardlinks(entries, inodes, links):
    """Give every member of a hardlink group the group's real payload.

    Without this a path lookup can return an empty string for a file that is
    perfectly present in the archive, and any check that looks at the file's
    content (e.g. scanning udevd for its compiled in rules directory) would
    silently see nothing and report a false failure.
    """
    for name, key in inodes.items():
        mode, payload = entries[name]
        if not stat.S_ISREG(mode) or payload:
            continue
        real = links.get(key)
        if real:
            entries[name] = (mode, real)
    return entries


def load_initramfs(path):
    """Return the name -> (mode, payload) map of an initramfs file."""
    with open(path, "rb") as handle:
        blob = handle.read()

    entries, off, inodes, links = read_cpio(blob)
    # Anything after the first archive may be a compressed payload.  The
    # kernel allows NUL padding between the two, so skip it before looking
    # for the next magic.
    while off < len(blob):
        probe = off
        while probe < len(blob) and blob[probe] == 0:
            probe += 1
        kind = None
        for magic, name in COMPRESSION_MAGICS.items():
            if blob[probe:probe + len(magic)] == magic:
                kind = name
                break
        if kind is None:
            if blob[probe:probe + 6] == b"070701":
                more, off, more_inodes, more_links = read_cpio(blob[probe:])
                entries.update(more)
                inodes.update(more_inodes)
                links.update(more_links)
                continue
            break
        try:
            plain = _decompress(blob[probe:], kind)
        except InitramfsError:
            break
        more, _, more_inodes, more_links = read_cpio(plain)
        entries.update(more)
        inodes.update(more_inodes)
        links.update(more_links)
        break
    return resolve_hardlinks(entries, inodes, links)


def normalise(path):
    """Normalise a path the way the kernel does: collapse . and .. and slashes."""
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)


def resolve(entries, path, depth=0):
    """Resolve a path inside the archive, following symlinks.

    Returns the canonical archive path of the target, or None when it dangles.
    """
    if depth > 24:
        return None
    parts = [p for p in path.split("/") if p not in ("", ".")]
    stack = []
    for index, part in enumerate(parts):
        stack.append(part)
        current = "/".join(stack)
        item = entries.get(current)
        if item is None:
            return None
        mode, payload = item
        if stat.S_ISLNK(mode):
            target = payload.decode("utf-8", "replace")
            rest = parts[index + 1:]
            if target.startswith("/"):
                new_path = target
            else:
                new_path = "/".join(stack[:-1] + [target])
            if rest:
                new_path = new_path + "/" + "/".join(rest)
            return resolve(entries, normalise(new_path), depth + 1)
    return "/".join(stack)


def find_binary(entries, *candidates):
    """Return (archive path, bytes) of the first candidate that resolves."""
    for candidate in candidates:
        target = resolve(entries, candidate)
        if target is None:
            continue
        item = entries.get(target)
        if item and stat.S_ISREG(item[0]):
            return target, item[1]
    return None, None


def strings(blob, min_len=6):
    return re.findall(rb"[\x20-\x7e]{%d,}" % min_len, blob)


def check_modules(entries, problems):
    """The live CD needs a complete, resolvable module chain."""
    dep_name = None
    for name in entries:
        if name.endswith("/modules.dep"):
            dep_name = name
            break
    if dep_name is None:
        problems.append("no modules.dep found in the initramfs")
        return
    dep = entries[dep_name][1].decode("utf-8", "replace")
    moddir = dep_name[:dep_name.rindex("/")]

    # module name -> (path, [dependency paths])
    index = {}
    referenced = set()
    for line in dep.splitlines():
        if not line.strip():
            continue
        path, _, rest = line.partition(":")
        path = path.strip()
        if not path:
            continue
        name = os.path.basename(path)
        # Kernel module names use underscores, the files use hyphens
        # (dm-mod.ko.zst is the dm_mod module).
        name = name.split(".ko")[0].replace("-", "_")
        index[name] = (path, rest.split())
        referenced.add(name)
        for dependency in rest.split():
            dname = os.path.basename(dependency)
            referenced.add(dname.split(".ko")[0].replace("-", "_"))

    # A module that is compiled into the kernel has no entry of its own in
    # modules.dep; it only shows up as a dependency or in modules.builtin.
    builtin = set()
    for name in entries:
        if name.endswith("/modules.builtin"):
            for line in entries[name][1].decode("utf-8", "replace").splitlines():
                line = line.strip()
                if line:
                    builtin.add(os.path.basename(line).split(".ko")[0].replace("-", "_"))

    for module in REQUIRED_MODULES:
        if module in builtin:
            # Built into the kernel: nothing to load, nothing to check.
            continue
        if module not in index:
            if module in referenced:
                problems.append("module '%s' is only a dependency in "
                                "modules.dep, it has no entry of its own" % module)
            else:
                problems.append("modules.dep does not list '%s' (live CD cannot "
                                "read the ISO or mount the squashfs)" % module)
            continue
        path, deps = index[module]
        for dependency in [path] + deps:
            full = "%s/%s" % (moddir, dependency)
            if resolve(entries, full) is None:
                problems.append("module '%s' (%s) is listed in modules.dep but "
                                "missing from the initramfs" % (module, full))
                break


def check_udev_rules_scan(entries, problems):
    """udev must scan the directory the ISO exposes as /etc/udev/rules.d.

    udev compiles its configuration directory into the binary as
    $sysconfdir/udev.  The ISO exposes /etc as a symlink to System/Settings,
    so the compiled in directory has to resolve to the same place as
    /etc/udev/rules.d.  When it does not, udev silently ignores
    /etc/udev/rules.d: GoboLinux's own rules never load and dracut's
    runtime 99-live-squash.rules is never applied, so dmsquash-live-root
    never runs and the live CD hangs waiting for /dev/root.
    """
    target = resolve(entries, "/etc/udev/rules.d")
    if target is None:
        problems.append("/etc/udev/rules.d is missing from the initramfs")
        return

    found = False
    for name in ("/systemd-udevd", "/sbin/udevd", "/usr/lib/udev/udevd"):
        binary_path, blob = find_binary(entries, name)
        if blob is None:
            continue
        candidates = set()
        for raw in strings(blob):
            text = raw.decode("utf-8", "replace")
            for match in re.finditer(r"(/[\x21-\x7e]*/udev/rules\.d)\b", text):
                candidates.add(match.group(1))
        for candidate in candidates:
            resolved = resolve(entries, candidate)
            if resolved is not None and resolved == target:
                found = True
                break
        if found:
            break

    if not found:
        binary_path, _ = find_binary(entries, "/systemd-udevd", "/sbin/udevd")
        problems.append(
            "udev (%s) does not scan %s: its compiled in configuration "
            "directory does not point at /etc/udev. The live CD will hang in "
            "dracut waiting for /dev/root, because dracut's runtime rule "
            "/etc/udev/rules.d/99-live-squash.rules (which runs "
            "dmsquash-live-root) is never applied. Rebuild udev with "
            "--sysconfdir=$goboSettings so that it compiles in "
            "/System/Settings/udev." % (binary_path or "udevd", target))


def verify(path):
    problems = []
    if not os.path.exists(path):
        return ["initramfs '%s' does not exist" % path]
    entries = load_initramfs(path)
    if not entries:
        return ["initramfs '%s' could not be parsed" % path]
    check_modules(entries, problems)
    check_udev_rules_scan(entries, problems)
    return problems


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print("Usage: %s <initramfs>" % sys.argv[0])
        return 1
    problems = verify(args[0])
    if problems:
        print("--> Initramfs verification FAILED for %s" % args[0])
        for problem in problems:
            print("    * %s" % problem)
        return 1
    print("--> Initramfs verification passed for %s" % args[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
