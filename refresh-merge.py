#!/usr/bin/env python3

# Create a new ISO based on a reference ISO + a set of tarballs.
# Written by Lucas C. Villa Real <lucasvr@gobolinux.org>
# Released under the GNU GPL version 2.

import os
import sys
import time
import shutil
import tarfile
import tempfile
import signal
import subprocess
from glob import glob
from datetime import datetime

# Static verifier for the generated initramfs.  It lives next to this script
# and is imported, not shelled out, so the merge can abort before an ISO with
# a broken initramfs is ever assembled.
try:
    import importlib.util
    _spec = importlib.util.spec_from_file_location(
        "verify_initramfs",
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "verify-initramfs.py"))
    verify_initramfs_module = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(verify_initramfs_module)
except Exception as _error:  # pragma: no cover - the merge must not break
    verify_initramfs_module = None
    print("--> WARNING: could not load verify-initramfs.py (%s)" % _error)


def check_initramfs(initramfs_path):
    """Abort the merge when the generated initramfs cannot boot the live CD.

    The check is static: it parses the initramfs cpio and verifies that the
    kernel module chain the live CD needs is present and that udev is going to
    scan /etc/udev/rules.d.  dracut drops its live-root rule there at boot
    time; when udev's compiled in configuration directory does not point at
    /etc/udev that rule is never applied, dmsquash-live-root never runs and
    the ISO hangs with '"/dev/root" does not exist'.
    """
    if verify_initramfs_module is None:
        print("--> WARNING: initramfs verification skipped "
              "(verify-initramfs.py unavailable)")
        return
    problems = verify_initramfs_module.verify(initramfs_path)
    if problems:
        print("--> Initramfs verification FAILED for %s" % initramfs_path)
        for problem in problems:
            print("    * %s" % problem)
        print("--> Refusing to build an ISO with a broken initramfs")
        sys.exit(1)
    print("--> Initramfs verification passed for %s" % initramfs_path)

class MountError(Exception):
    def __init__(self, expression, message):
        self.expression = expression
        self.message = message

class BaseImageFile:
    def mount(self, image_file, mountpoint):
        info = subprocess.run(["mount", "-o", "loop", image_file, mountpoint])
        if info.returncode != 0:
            raise MountError(" ".join(info.args), f"Error mounting {image_file}")

    def unmount(self, mountpoint):
        info = subprocess.run(["umount", mountpoint])
        if info.returncode != 0:
            raise MountError(" ".join(info.args), f"Error unmounting {mountpoint}")

class ISOFile(BaseImageFile):
    def __init__(self, iso_file):
        self.iso_file = iso_file
        self.mountpoint = ""
        self.squashfs_dirs = []

    def mount(self, mountpoint):
        self.mountpoint = mountpoint
        return super().mount(self.iso_file, self.mountpoint)

    def unmount(self):
        return super().unmount(self.mountpoint)

    def extractFiles(self, dest_dir):
        if not os.path.exists(f"{dest_dir}/isolinux"):
            subprocess.run(["cp", "-a", f"{self.mountpoint}/isolinux", f"{dest_dir}/isolinux"])

        # Skip extraction only if rootfs is populated (has Programs/).
        # A stale empty rootfs from a prior failed merge must be re-extracted.
        if os.path.exists(f"{dest_dir}/rootfs/Programs"):
            return

        # Remove incomplete rootfs before re-extracting
        if os.path.exists(f"{dest_dir}/rootfs"):
            shutil.rmtree(f"{dest_dir}/rootfs")

        for squash_file in glob(f"{self.mountpoint}/*.squashfs"):
            print("--> Extracting {}".format(os.path.basename(squash_file)))
            squash = SquashFile(squash_file)
            squash_dest_dir = f"{dest_dir}/rootfs"
            try:
                squash.extractFiles(squash_dest_dir)
            except FileExistsError:
                raise

    def create(self, out_dir):
        # Main SquashFS file
        squash = SquashFile(f"{out_dir}/gobolinux-live.squashfs")
        squash.create(glob(f"{out_dir}/rootfs/*"))

        efiboot_file = "isolinux/efiboot.img"
        print("--> Generating ISO file...")
        cmd = [
            "xorriso",
            "-as", "mkisofs",
            "-iso-level", "3",
            "-full-iso9660-filenames",
            "-R",
            "-eltorito-boot", "isolinux/isolinux.bin",
            "-eltorito-catalog", "isolinux/boot.cat",
            "-no-emul-boot",
            "-boot-load-size", "4",
            "-boot-info-table",
            "-isohybrid-mbr", "/usr/share/syslinux/isohdpfx.bin",
            "-input-charset", "utf-8",
            # Add boot support via EFI:
            "-eltorito-alt-boot",
            "-e", efiboot_file,
            "-no-emul-boot",
            "-isohybrid-gpt-basdat",
            # Volume information
            "-appid", "GoboLinux Live Installer",
            "-V", "GOBOLINUX_LIVE_INSTALLER",
            "-publisher", "GoboLinux.org",
            "-p", "Gobo Himself",
            "-m", f"{out_dir}/{os.path.basename(self.iso_file)}",
            "-m", f"{out_dir}/rootfs",
            "-output", self.iso_file,
            out_dir
        ]
        subprocess.run(cmd)
        subprocess.run(["isohybrid", "--uefi", self.iso_file])


class SquashFile(BaseImageFile):
    def __init__(self, squash_file):
        self.squash_file = squash_file

    def mount(self, mountpoint):
        self.mountpoint = mountpoint
        return super().mount(self.squash_file, self.mountpoint)

    def unmount(self):
        return super().unmount(self.mountpoint)

    def extractFiles(self, dest_dir):
        cmd = ["unsquashfs", "-f", "-d", dest_dir, self.squash_file]
        subprocess.run(cmd)

    def create(self, src_dirs):
        cmd = ["mksquashfs"] + src_dirs + [self.squash_file]
        cmd += ["-comp", "zstd", "-noappend", "-no-sparse", "-keep-as-directory", "-Xcompression-level", "15"]
        subprocess.run(cmd)

class BinaryPackage:
    def __init__(self, package_file):
        self.package_file = package_file

    def programName(self):
        return os.path.basename(self.package_file).split("--")[0]

    def programVersion(self, squashfs_dir=None, from_tarball=True):
        if from_tarball:
            full_version = os.path.basename(self.package_file).split("--")[1]
            revision = full_version.rfind("-r")
            version = full_version if revision == -1 else full_version[:revision]
            return version
        return self.priorVersion(squashfs_dir)

    def priorVersion(self, squashfs_dir):
        path = f"{squashfs_dir}/Programs/{self.programName()}"
        versions = [x.replace(f"{path}/", "") for x in glob(f"{path}/*")]
        for ignore_version in ["Current", "Variable", "Settings"]:
            try:
                versions.remove(ignore_version)
            except ValueError:
                pass
        if len(versions) == 0:
            return None
        elif len(versions) > 1:
            print(f"Warning: more than one version exists at {path}: {versions}")
        return sorted(versions)[0]

    def getPaths(self, squashfs_dir, from_tarball=True):
        version = self.programVersion(squashfs_dir, from_tarball)
        if version is None:
            return None
        p = {}
        p["name"] = self.programName()
        p["version"] = version
        p["programs"] = f"{squashfs_dir}/Programs"
        p["path"] = "{}/{}/{}".format(p["programs"], p["name"], p["version"])
        p["settings"] = "{}/{}/Settings".format(p["programs"], p["name"])
        p["current"] = "{}/{}/Current".format(p["programs"], p["name"])
        return p

    def removePrior(self, squashfs_dir, from_tarball=False):
        p = self.getPaths(squashfs_dir, from_tarball)
        if p is not None:
            removed = self.__removeProgram(p["path"], p["settings"])
            if os.path.lexists(p["current"]):
                os.unlink(p["current"])
            self.__removeBrokenLinks(squashfs_dir, removed)

    def merge(self, squashfs_dir):
        new_p = self.getPaths(squashfs_dir, True)
        old_p = self.getPaths(squashfs_dir, False)
        name = new_p["name"]

        if os.path.exists(new_p["path"]):
            path_timestamp = os.stat(new_p["path"]).st_ctime
            package_timestamp = os.stat(self.package_file).st_ctime
            if path_timestamp < package_timestamp:
                print(f"--> Replacing outdated program {name} at {new_p['path']}")
                removed = self.__removeProgram(new_p["path"], new_p["settings"])
                print(f"    Removed {len(removed)} files")
                self.__uncompressAndLink(new_p["programs"], new_p["path"], new_p["current"])
                self.__removeBrokenLinks(squashfs_dir, removed)
            else:
                print(f"--> Keeping existing program {name}")
        if old_p is not None and old_p["path"] != new_p["path"]:
            print(f"--> Replacing previous version of {name} at {old_p['path']}")
            removed = self.__removeProgram(old_p["path"], old_p["settings"])
            print(f"    Removed {len(removed)} files")
            self.__uncompressAndLink(new_p["programs"], new_p["path"], new_p["current"])
            self.__removeBrokenLinks(squashfs_dir, removed)
        elif old_p is None and not os.path.exists(new_p["path"]):
            print(f"--> Adding program {name}")
            self.__uncompressAndLink(new_p["programs"], new_p["path"], new_p["current"])

    def __removeProgram(self, path, settings_dir):
        removed_files = []
        if os.path.exists(path):
            # Remove directory tree
            removed_files += [
                x.replace(path, "/")[1:]
                for x in glob(f"{path}/**", recursive=True)]
            shutil.rmtree(path)

            # Remove program settings. Note the "no [1:]" here: the replace()
            # leaves '/etc/...' intact, and without that slice the earlier
            # "/etc{}".format(...[1:]) produced a doubled '/etcetc/...' path
            # that broken-list matching could never clean.
            if os.path.exists(settings_dir):
                removed_settings = [
                    x.replace(settings_dir, "")
                    for x in glob(f"{settings_dir}/**", recursive=True)]
                removed_files += removed_settings
                shutil.rmtree(settings_dir)

            # Attempt to remove the parent directory (i.e., /Programs/Foo)
            try:
                os.unlink(os.path.dirname(path))
            except:
                pass
        return removed_files

    def __removeBrokenLinks(self, squashfs_dir, removed_files):
        broken_list = []
        for path in removed_files:
            # Was this file linked to /System/Settings?
            if path.startswith("/etc"):
                broken_list.append(path)
                continue
            # Was this file linked to /System/Index?
            for system_index_dir in ["/bin", "/include", "/lib", "/libexec", "/share"]:
                if path.startswith(system_index_dir):
                    broken_list.append(f"/System/Index{path}")
                    break
        # Prevent the argument list from growing too long. We should, ideally, check
        # the output of `getconf ARG_MAX` and split the list according to the number
        # of bytes needed to represent its members, but using a predefined chunk size
        # of 10k file names should work for the most common use cases.
        chroot = InChroot(squashfs_dir)
        for chunk in self.__splitList(broken_list, 10000):
            chroot.exec(["/bin/RemoveBroken"] + chunk, quiet=False)

    def __splitList(self, the_list, n):
        for i in range(0, len(the_list), n):
            yield the_list[i:i+n]

    def __uncompressAndLink(self, programs_dir, new_path, current_symlink):
        os.makedirs(programs_dir, exist_ok=True)
        try:
            with tarfile.open(self.package_file, "r:bz2") as tar:
                tar.extractall(programs_dir)
        except tarfile.CompressionError:
            # The chroot python was built without the _bz2 module (no
            # libbz2.so dev symlink at build time); system tar handles bz2
            # fine and produces an equivalent extraction.
            subprocess.run(
                ["tar", "-xjf", self.package_file, "-C", programs_dir],
                check=True)

        # Symlink program
        squashfs_dir = os.path.dirname(programs_dir)
        program_dir = new_path.replace(squashfs_dir, "")
        chroot = InChroot(squashfs_dir)
        chroot.symlink(program_dir)

        # Update "Current" symlink
        if os.path.lexists(current_symlink):
            os.unlink(current_symlink)
        new_version = os.path.basename(new_path)
        os.symlink(new_version, current_symlink)

        # Update new_path's last access and modification times
        now = time.mktime(datetime.now().timetuple())
        os.utime(new_path, (now, now))

class ISOLinux:
    def __init__(self, path):
        self.path = path
        self.old_kernel_path = f"{self.path}/kernel"
        self.old_initramfs = f"{self.path}/initramfs"
        self.needs_initramfs_refresh = False

    def updateKernel(self, new_kernel_path):
        old_timestamp = os.stat(self.old_kernel_path).st_mtime
        new_timestamp = os.stat(os.path.realpath(new_kernel_path)).st_mtime
        if old_timestamp < new_timestamp:
            print("--> Updating ISOLINUX kernel file")
            os.unlink(self.old_kernel_path)
            shutil.copy2(new_kernel_path, self.old_kernel_path)
            self.needs_initramfs_refresh = True

    def updateInitramfs(self, force=False):
        if not self.needs_initramfs_refresh and not force:
            return
        print("--> Updating Initramfs for the Live image")
        if Initramfs().create(self.old_kernel_path, self.old_initramfs) == False:
            sys.exit(1)
        # A syntactically valid initramfs is not enough: the live CD only
        # boots when the kernel module chain is complete AND udev scans
        # /etc/udev/rules.d (dracut's live-root rule lives there).  Abort
        # here rather than shipping an ISO that hangs at boot.
        check_initramfs(self.old_initramfs)
        # Set the needs_initramfs_refresh flag so that the initramfs
        # for the Installed system can be rebuilt as well
        self.needs_initramfs_refresh = True

# dracut (Dracut 103) spawns dracut-install which can spin at 100% CPU while
# resolving modules and ignores SIGTERM; without a hard bound a bad module
# index silently hangs the whole merge for hours (observed: 11 h). Run dracut
# in its own session so the entire process group can be taken down with
# SIGKILL, which no process can ignore.
def run_dracut(cmd, budget=1500):
    proc = subprocess.Popen(cmd, start_new_session=True)
    try:
        proc.communicate(timeout=budget)
    except subprocess.TimeoutExpired:
        print(f"--> dracut exceeded {budget}s; SIGKILLing its process group")
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        return None
    except KeyboardInterrupt:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        raise
    return proc.returncode

# Dracut 103's bundled dracut-install infinite-loops at 100% CPU while
# resolving kernel modules on GoboLinux (fw_devlink "suppliers" scan,
# upstream regression commit 3de4c731; see dracut-ng/dracut#2155). The
# reporter proved a pre-v060 dracut-install works with the stock 103
# scripts. We vendor a v059 build here and keep the stock binary aside as
# dracut-install.103.bak. Re-apply it after every run so a rebuild or
# extraction that restores the stock binary cannot reintroduce the hang.
# squashfs_dir="" targets this build chroot's /Programs tree (where dracut
# runs below); squashfs_dir=<work>/rootfs targets the assembled Live rootfs
# so the final ISO carries the fixed binary too.
def ensure_safe_dracut_install(squashfs_dir=""):
    safe_path = "/Programs/Dracut/Current/lib/dracut/dracut-install.v059"
    dracut_dir = f"{squashfs_dir}/Programs/Dracut/Current/lib/dracut"
    install_path = f"{dracut_dir}/dracut-install"
    if not os.path.exists(safe_path):
        print("--> WARNING: dracut-install.v059 not found; leaving stock binary")
        return
    if not os.path.exists(install_path):
        return
    viewed_as = squashfs_dir or "/"
    if not os.path.exists(f"{dracut_dir}/dracut-install.v059"):
        shutil.copy2(safe_path, f"{dracut_dir}/dracut-install.v059")
        os.chmod(f"{dracut_dir}/dracut-install.v059", 0o755)
    if os.path.getsize(install_path) != os.path.getsize(safe_path):
        shutil.copy2(safe_path, install_path)
        os.chmod(install_path, 0o755)
        print(f"--> Replaced stock dracut-install with pre-v060 (v059) build in {viewed_as}")

class Initramfs:
    def create(self, kernel_path, initramfs_path, live=True):
        kernel_version = self.kernelVersion(kernel_path)
        cmd = self.liveString(kernel_version) if live else self.installedString(kernel_version)
        if run_dracut(cmd) is None:
            print(f"Failed to generate initramfs for {kernel_version} (dracut timed out)")
            return False
        new_initramfs_path = f"/System/Kernel/Boot/initramfs-{kernel_version}.img"
        if not os.path.exists(new_initramfs_path):
            print("Failed to generate initramfs file")
            return False
        if os.path.exists(initramfs_path):
            os.unlink(initramfs_path)
        shutil.move(new_initramfs_path, initramfs_path)
        return True

    def installedString(self, kernel_version):
        return [
            "dracut",
            "--kver", kernel_version,
            "--show-modules",
            "--force",
            "-L", "4"
        ]

    def liveString(self, kernel_version):
        # The invocation MUST stay in sync with BUILD.md §"Initramfs":
        #
        #   dracut --kver <release> -m "bash kernel-modules kernel-modules-extra
        #   udev-rules base fs-lib shutdown img-lib dmsquash-live"
        #   --filesystems "squashfs iso9660" --show-modules --force
        #
        # That is the EXACT command line that produced the stock
        # GoboLinux-017.01 ISO's initramfs, and that initramfs boots. This
        # script had drifted to an extra "--no-hostonly --add-drivers
        # 'usb-storage uas'", and the initramfs that produced HANGS the kernel
        # before dracut's init even runs (verified: the stock 017.01 kernel
        # boots the stock initramfs but hangs on the new one; the new kernel
        # boots fine with no initramfs at all). Symptoms on the booted ISO:
        # the console stops right after the early kernel messages and dracut
        # never appears; a stale build reports
        #   dracut warning: "/dev/root" does not exist
        # because no root device is ever found.
        #
        # Do NOT re-add --no-hostonly here without re-testing the boot: the
        # non-hostonly module set is what came with the broken initramfs.
        # The USB mass-storage drivers (usb-storage/uas) that a USB-stick
        # boot needs are already covered by "kernel-modules-extra" in the
        # stock configuration, and the iso9660 driver by --filesystems.
        return [
            "dracut",
            "--kver", kernel_version,
            "-m", "bash kernel-modules kernel-modules-extra udev-rules base fs-lib shutdown img-lib dmsquash-live",
            "--filesystems", "squashfs iso9660",
            "--show-modules",
            "--force",
            "-L", "4"
        ]

    def kernelVersion(self, kernel_path):
        # Expected output from the `file` command:
        # kernel: Linux kernel x86 boot executable bzImage, version 5.4.15-Gobo (root@Soundgarden) [...]
        parts = subprocess.check_output(["file", kernel_path], stderr=subprocess.STDOUT).split()
        version_index = parts.index(b"version")
        if version_index < 0:
            print(f"Failed to identify kernel version from {kernel_path}")
            sys.exit(1)
        return parts[version_index+1].decode("utf-8")

class InChroot:
    def __init__(self, squashfs_dir):
        self.directory_stack = []
        self.squashfs_dir = squashfs_dir
        self.overwrite = "--overwrite"
        self.relative  = "" # "--relative"
        self.no_follow = "" # "--no-follow"

    def symlink(self, program_version_path):
        goboPrefix = self.squashfs_dir
        goboIndex = f"{goboPrefix}/System/Index"
        goboExecutables = f"{goboIndex}/bin"
        goboLibraries = f"{goboIndex}/lib"
        goboHeaders = f"{goboIndex}/include"

        # Symlink essential directories, then chroot into target and
        # perform the complete linking process through SymlinkProgram.
        symlink_map = {
            f"{program_version_path}/lib": goboLibraries,
            f"{program_version_path}/bin": goboExecutables,
            f"{program_version_path}/sbin": goboExecutables,
            f"{program_version_path}/include": goboHeaders,
        }
        for source, target in symlink_map.items():
            self.__linkDirectory(source, target)

        # Chroot and SymlinkProgram
        program = program_version_path[1:].split("/")[1]
        version = program_version_path[1:].split("/")[2]
        self.exec(["/bin/UpdateSettings", "-a", program, version])
        self.exec(["/bin/SymlinkProgram", "-c", "overwrite", "-u", "install", program, version])

    def exec(self, cmd, quiet=False):
        env = {"SUDO_USER": ""}
        with open("/dev/null", "w") as devnull:
            fout = devnull if quiet == True else None
            ferr = devnull if quiet == True else None
            try:
                subprocess.run(["mount", "-o", "bind", "/dev", f"{self.squashfs_dir}/dev"])
                subprocess.run(["mount", "-o", "bind", "/proc", f"{self.squashfs_dir}/proc"])
                subprocess.run(["chroot", self.squashfs_dir] + cmd, stdout=fout, stderr=ferr, env=env)
            finally:
                subprocess.run(["umount", f"{self.squashfs_dir}/dev"])
                subprocess.run(["umount", f"{self.squashfs_dir}/proc"])

    def __linkDirectory(self, from_path, to_path):
        inner_rfrom = os.path.realpath(from_path)
        outer_rfrom = "{}{}".format(self.squashfs_dir, inner_rfrom)
        if not self.__isEmptyDirectory(outer_rfrom):
            symlink_target_dir = os.path.realpath(to_path)
            with open("/dev/null", "w") as devnull:
                env = {}
                for name in ["debugFD", "verboseFD", "terseFD", "errorFD", "normalFD"]:
                    env[name] = "2"
                env["scriptName"] = "RefreshLiveCD"
                env["goboPrograms"] = "/Programs"
                env["goboPrefix"] = self.squashfs_dir

                self.__pushd(symlink_target_dir)
                cmd = ["/bin/LinkOrExpandAll", inner_rfrom, self.overwrite, self.relative, self.no_follow]
                subprocess.run(cmd, env=env, stderr=devnull)
                self.__popd()

    def __pushd(self, path):
        self.directory_stack.append(os.getcwd())
        os.chdir(path)

    def __popd(self):
        old_path = self.directory_stack.pop(-1)
        os.chdir(old_path)

    def __isEmptyDirectory(self, path):
        return len(glob(f"{path}/*")) == 0

def main():
    if len(sys.argv) < 3:
        print(f"Syntax: {sys.argv[0]} <iso_file> <work_directory> [packages_directory]")
        sys.exit(1)

    iso_file = os.path.realpath(sys.argv[1])
    work_dir = os.path.realpath(sys.argv[2])
    packages_dir = os.path.realpath(sys.argv[3]) if len(sys.argv) == 4 else None
    os.makedirs(work_dir, exist_ok=True)

    if packages_dir is not None and not os.path.exists(packages_dir):
        print(f"Error: packages directory '{packages_dir}' does not exist")
        sys.exit(1)

    # Extract isolinux and squashfs files from the original ISO.
    # Loop mounts need kernel loop support that some hosts lack, so prefer a
    # host-side xorriso extraction placed next to the ISO:
    #   xorriso -osirrox on -indev <iso> -extract / <isodir>/refiso-extract
    # Falls back to the classic loop mount when that directory is absent.
    pre_extract = os.path.join(os.path.dirname(iso_file), "refiso-extract")
    if os.path.isdir(f"{pre_extract}/isolinux"):
        print(f"--> Using pre-extracted reference ISO at {pre_extract}")
        iso = ISOFile(iso_file)
        iso.mountpoint = pre_extract
        iso.extractFiles(work_dir)
    else:
        with tempfile.TemporaryDirectory() as iso_mountpoint:
            iso = ISOFile(iso_file)
            iso.mount(iso_mountpoint)
            try:
                iso.extractFiles(work_dir)
            finally:
                iso.unmount()

    # Extract tarballs
    if packages_dir is not None:
        if len(glob(f"{packages_dir}/-*")):
            print("--> Removing unwanted packages")
            for path in glob(f"{packages_dir}/-*"):
                try:
                    from_tarball = True
                    version = os.path.basename(path).split("--")[1]
                    dummy = "{}--{}--x86_64.tar.bz2".format(path.replace("/-", "/"), version)
                except IndexError:
                    from_tarball = False
                    dummy = "{}--0--x86_64.tar.bz2".format(path.replace("/-", "/"))
                p = BinaryPackage(dummy)
                p.removePrior(f"{work_dir}/rootfs", from_tarball)

        print("--> Processing tarballs")
        for path in glob(f"{packages_dir}/*.bz2"):
            p = BinaryPackage(path)
            p.merge(f"{work_dir}/rootfs")

    # Regenerate kernel module dependency info (modules.dep) so the merged
    # kernel modules (e.g. NVIDIA) are found by modprobe on the live system.
    linux_moddir = f"{work_dir}/rootfs/Programs/Linux/Current/lib/modules"
    kver = None
    for entry in sorted(os.listdir(linux_moddir)):
        path = os.path.join(linux_moddir, entry)
        if os.path.isdir(path) and not os.path.islink(path):
            kver = entry
            break
    if kver is not None:
        print(f"--> Regenerating module dependencies for kernel {kver}")
        InChroot(f"{work_dir}/rootfs").exec(["/sbin/depmod", kver])


    # Update GoboLinuxVersion
    gobolinux_version = "017.01"
    with open(f"{work_dir}/rootfs/System/Settings/GoboLinuxVersion", "r+") as f:
        v = f.readline().strip("\n")
        if v != gobolinux_version:
            f.truncate(0)
            f.seek(0)
            f.write(f"{gobolinux_version}\n")

    # The initramfs below is built by dracut running in THIS build chroot (not
    # the merged rootfs), and dracut resolves kernel modules through this
    # chroot's /lib/modules/<kver>. Installing the OpenZFS package re-links the
    # index's module metadata (modules.dep & friends) on top of the kernel's
    # complete copies with OpenZFS's own zfs-only dep file. Re-running depmod
    # rebuilds the full set but ALSO indexes the NVIDIA modules (uncompressed
    # .ko files dropped into an otherwise zstd-compressed tree), and
    # dracut-install in Dracut 103 spins forever at 100% CPU over that state.
    # The kernel tree's own metadata is already the complete, self-consistent
    # set (full module list + the overlay zfs/spl, written by the same kmod
    # depmod dracut links against), so point the index at it instead of
    # running depmod: dracut then resolves exactly what the kernel build
    # produced, with no NVIDIA entries.
    #
    # This MUST replace the index entries, not just overwrite regular files.
    # Gobo's SymlinkProgram links a program's whole lib/ dir into
    # /System/Index/lib, so whichever program was linked LAST owns the index:
    # after OpenZFS is linked, /lib/modules/<kver>/modules.dep is a symlink to
    # OpenZFS's 2-line zfs-only dep file and the kernel's 6000-line one is
    # shadowed. modprobe then cannot resolve 'overlay', dracut skips
    # 90overlayfs, dmsquash-live (which depends on it) is skipped too, NO
    # initramfs is produced and the merge dies with "Failed to generate
    # initramfs file". The old code below only copied over *regular* files
    # ("not os.path.islink(dst)"), so it silently mirrored 0 files and the
    # merge kept failing.
    build_moddir = "/Programs/Linux/Current/lib/modules"
    if os.path.isdir(build_moddir):
        real_modroot = os.path.realpath(build_moddir)
        real_kver = None
        for entry in sorted(os.listdir(real_modroot)):
            path = os.path.join(real_modroot, entry)
            if os.path.isdir(path) and not os.path.islink(path):
                real_kver = entry
                break
        if real_kver is not None:
            real_moddir = os.path.join(real_modroot, real_kver)
            idx_moddir = f"/lib/modules/{real_kver}"

            def repoint_metadata(src_dir, dst_dir):
                # Make every regular file of src_dir be the one reached from
                # dst_dir. Existing symlinks pointing elsewhere (OpenZFS's
                # zfs-only metadata) are replaced; regular files (depmod's
                # own output) are left alone; missing entries are created.
                changed = 0
                if not os.path.isdir(src_dir) or not os.path.isdir(dst_dir):
                    return 0
                for name in sorted(os.listdir(src_dir)):
                    src = os.path.join(src_dir, name)
                    dst = os.path.join(dst_dir, name)
                    if not os.path.isfile(src) or os.path.islink(src):
                        continue
                    if os.path.islink(dst):
                        if os.path.realpath(dst) == os.path.realpath(src):
                            continue
                        os.unlink(dst)
                    elif os.path.exists(dst):
                        continue
                    os.symlink(src, dst)
                    changed += 1
                return changed

            repointed = repoint_metadata(real_moddir, idx_moddir)
            # The ZFS modules live in the kernel tree's extra/ dir; keep the
            # index pointing at the kernel's copies so the index stays valid
            # even if the OpenZFS program is removed or rebuilt.
            repointed += repoint_metadata(
                os.path.join(real_moddir, "extra"),
                os.path.join(idx_moddir, "extra"))
            print(f"--> Module metadata index for {real_kver}: {repointed} entr(ies) repointed at the kernel tree")

            # Sanity check the modules dracut needs for the live initramfs.
            # Without this the only symptom is dracut's cryptic
            # "Module 'overlayfs' will not be installed" three lines before
            # the merge gives up.
            unresolved = []
            for mod in ("overlay", "squashfs", "loop"):
                probe = subprocess.run(
                    ["modprobe", "-d", "/", "-S", real_kver, "--dry-run", mod],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                if probe.returncode == 0:
                    print(f"--> modprobe resolves '{mod}' for kernel {real_kver}")
                else:
                    detail = probe.stderr.decode(errors="replace").strip()
                    unresolved.append(mod)
                    print(f"WARNING: modprobe cannot resolve '{mod}' for kernel {real_kver}: {detail}")
            if unresolved:
                print(f"WARNING: dracut will skip the modules depending on {', '.join(unresolved)}; "
                      f"the live initramfs (dmsquash-live) cannot be built.")

    # Guard the initramfs build against the Dracut 103 dracut-install hang
    # (see ensure_safe_dracut_install): both dracut runs below resolve
    # modules through this chroot's /Programs/Dracut tree. Fix the build
    # chroot (used by dracut) and the assembled rootfs (shipped in the ISO).
    ensure_safe_dracut_install()
    ensure_safe_dracut_install(f"{work_dir}/rootfs")

    # Update kernel image used by the Live environment
    boot_path = "/Programs/Linux/Current/Resources/Unmanaged/System/Kernel/Boot"
    kernel_path = f"{boot_path}/kernel"
    bootloader = ISOLinux(f"{work_dir}/isolinux")
    bootloader.updateKernel(f"{work_dir}/rootfs/{kernel_path}")
    bootloader.updateInitramfs(force=True)

    # Create initramfs to be used by the installed system
    if bootloader.needs_initramfs_refresh:
        print("--> Updating Initramfs for the installed system")
        kernel_path = f"{work_dir}/isolinux/kernel"
        kernel_version = Initramfs().kernelVersion(kernel_path)
        initramfs_path = f"{work_dir}/rootfs/{boot_path}/initramfs-{kernel_version}.img"
        Initramfs().create(kernel_path, initramfs_path, live=False)

    # NOTE: the ISO assembly step (SquashFile.create + xorriso + isohybrid) is
    # intentionally left out of this script: it is run on the build host, which
    # has xorriso/isohybrid installed. See finalize-iso.sh.

if __name__ == "__main__":
    main()
