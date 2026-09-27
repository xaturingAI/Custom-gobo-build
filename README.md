# gobo-build — Custom GoboLinux LiveCD builder

Builds a custom **GoboLinux 017.01** live ISO on an Arch/CachyOS host, adding a
gaming/desktop stack (Steam, Wine/Proton/DXVK, Lutris, XIVLauncher, LMMS),
Pantheon + Plasma Wayland desktops, PipeWire audio, OpenZFS + XFS + LUKS root
install support, and a long list of live-boot runtime fixes.

Everything is idempotent — every build/fix script can be run again safely.

---

## 1. Layout

| Path | What it is |
|---|---|
| `GoboLinux-017.01-x86_64.iso` | Reference base ISO (input to every merge). |
| `rootfs/` | The **build chroot**: a full GoboLinux tree bind-mounted into `/` by `run-build.sh`. Compiled programs land in `rootfs/Programs/…`. |
| `work/rootfs/` | The **staged ISO tree**: refreshed from the base ISO + `Packages/` on every `merge`, then packed by `finalize-iso.sh`. |
| `work/isolinux/` | Kernel/initramfs/bootloader for the ISO (come from the base ISO merge). |
| `Packages/` | Compiled `Program--Version--x86_64.tar.bz2` packages that get merged into the ISO. |
| `logs/` | Per-program compile logs + `refresh.log` (merge) + `zfs*.log`. |
| `Recipes/` | **Mirror** of the canonical recipe repo (see §7 — edit the repo, not this). |
| `zfs45.sh`, `zfs46.sh` | Idempotent tree patchers: ZFS-on-root and LUKS+XFS+ZFS install support (§5). |
| `apply-live-fixes.sh` | Idempotent post-merge runtime fixer, the "livefix" (§4). |
| `build.sh` | The build engine, run **inside** the chroot. |
| `run-build.sh` | Host wrapper: bind-mounts the chroot and calls `build.sh` (§3). |
| `refresh-merge.py` | Lucas Villa Real's upstream RefreshLiveCD engine that `merge` calls. |
| `finalize-iso.sh` | Packs `work/rootfs` → `work/gobolinux.iso` (§6). |
| `Gobo_Linux_Recipes-AI/` | Local clone of your recipes mirror (see §8). |

---

## 2. Host prerequisites (Arch/CachyOS)

The build is **chroot-based, not virtualization** — no qemu is needed to build.
- Build tools used by `finalize-iso.sh`: `squashfs-tools` (mksquashfs), `xorriso`, `syslinux` (isohybrid), `dd`, `rsync`.
- `sudo` access (all `run-build.sh` steps and `finalize-iso.sh` run as root inside/mounted trees).
- A recipe repo at `../Projects/BuildLiveCD` (canonical `Recipes/`, `bin/AddProton`, `bin/Alien-*`). Override with `REPO=/path` for `run-build.sh`.
- ~10 GB free in `gobo-build` (the merge + squashfs step), plus room for the ISO.
- Only build scripts are run on the host; every compile happens inside the chroot.

Verify the chroot is healthy before a big build:

```
sudo ./run-build.sh test
```

---

## 3. The build wrapper: `run-build.sh`

`run-build.sh` is the **only** host entry point. It:
1. Bind-mounts `/proc`, `/sys`, `/dev`, `/dev/pts` into `rootfs/` (private mounts — never leak back to the host),
2. Binds `gobo-build` → `rootfs/mnt/gobo-build` and the recipe repo → `rootfs/mnt/repo`,
3. Copies the host resolv.conf in, then
4. `exec`s `build.sh` inside the chroot with your arguments.

```
sudo ./run-build.sh [step]            # build one step
sudo ./run-build.sh pkg Name Version  # single custom package
sudo ./run-build.sh all               # the full ISO (long)
sudo ./run-build.sh detach            # unmount the chroot binds (safe anytime)
```

`detach` is handled by `run-build.sh` itself (unmounts `rootfs/` binds). Everything else is passed through to `build.sh`.

### Full step reference (build.sh dispatch)

All steps are idempotent; most compile+package, skipping anything whose tarball already exists in `Packages/`.

| Step | What it does |
|---|---|
| `menu` / *(no args)* | Interactive component selector (saved in `.build-select`). |
| `--flag …` | Non-interactive component build (see §3.1). |
| `test` | Chroot env diagnostic (paths, compilers, gcc/make/cmake, network/DNS check, kernel modules). |
| `proton` | Fetch GE-Proton11-3 into the Steam compat-tools dir via `/mnt/repo/bin/AddProton`. |
| `sync` | Copy recipes from `/mnt/repo` → `/Data/Compile/Recipes`. Run automatically by most steps. |
| `linux` | Build the CachyOS 7.2.5 kernel recipe (`Recipes/Linux/7.2.5`), resumes with `--lazy` if a tree exists. |
| `nvidia` | Build NVIDIA 580.159.04 driver + modules for the exact kernel; verifies 5 modules, rebuilds if tarball lacks them. Ships modprobe.conf blacklist + `nvidia-drm.modeset=1`, the 0x10de udev auto-load rule and Xorg OutputClass. |
| `nvdiag` | Print kernel module presence / nvidia diagnostics. |
| `glibc32` | 32-bit base: Glibc-32 2.43-2 (libgcc/libstdc++). |
| `lib32` | All 32-bit gaming libs (X11/GL/audio/SDL2/…). **Run after `glibc32`.** |
| `cmake` | CMake 3.30.4. |
| `seatd` | SeatD 0.6.4 (recipe pre_build patches the /dev/dri + /dev/input realpath checks for Gobo symlinks). |
| `tools` | Misc tooling step. |
| `wayland` | Wayland core + Sway compositor (Wayland, Wayland-Protocols, EGLExternalPlatform, EGL-Wayland, SeatD, XorgProto, Wlroots, XWayland, Wlr-Protocols, Wlr-Randr, Wayland-Utils). |
| `swayextras` | SwayBg/SwayIdle/SwayLock/LibDecor. Pulls `wayland`. |
| `vulkan` | Vulkan headers/loader/tools. Pulls `wayland`. |
| `steam` | Steam client recipe. |
| `winetools` | Wine-associated prebuilt tooling. |
| `mingw` | Mingw-w64 cross toolchain. |
| `winedev` | Wine dev stack (Wine, DXVK, Vkd3d-Proton, Winetricks, Wine-Lutris-GE builds/recipes). |
| `protonplus` | ProtonPlus 0.6.8 (from its AppImage, with baked AppDir fallback). |
| `lutris` | Lutris 0.5.22 + only its runtime deps (WebKitGTK, Xrandr, Mesa-Utils, P7zip). Skips if all tarballs exist. |
| `ffxiv` | FFXIVQuickLauncher (XIVLauncher) 7.0.20 nupkg for Wine. Depends on `winedev`. |
| `music` | LMMS 1.3.0-alpha.2 DAW (optional, off by default in the menu). |
| `nodejs` | Node.js 24.21.0 (Krypton LTS) + npm/npx/corepack. |
| `go` | Go 1.27.1 (linux-amd64 toolchain). |
| `odin` | Odin dev compiler. |
| `v` | V compiler 0.5.2. |
| `fastfetch` | FastFetch system-info tool (prebuilt). |
| `pycompat` | Repackages Python so the Gobo Scripts modules are visible under python3.11 (`.pth`). |
| `pyxml` | Rebuilds libxml2 python bindings into Python 3.11 (itstool/AppStream). |
| `core` | Shared desktop foundation: GLib/GI two-pass, gdk-pixbuf/json-glib, elogind, flatpak chain (duktape/seccomp/polkit/appstream/vala/bubblewrap/gpgme/libostree/dbus-proxy/flatpak). |
| `elogind_base` | Just the elogind foundation (Linux-PAM headers + Linux-Headers 7.1.5 + Elogind 257.16 + BootUp wiring). |
| `flatpak` | Only `core` → a working `flatpak` CLI, no GUI, no index pollution. |
| `sddm` | SDDM 0.20.0 Wayland greeter (elogind base + ECM + SDDM; needs `wayland` + weston at runtime). |
| `extras` | Discord + VLC 3.0.21 (Qt 5.15.2). |
| `webkit` | WebKitGTK 2.46.5 (GTK3 4.1 + introspection) for Lutris web-login dialogs; pulls `core` + webkit tier. |
| `appimage` | AppImageKit 13 (appimagetool) + libappimage 1.0.0 — *writing* AppImages (running already works via FUSE). |
| `fs` | XFS + OpenZFS: LibInih, LibURCU (build-only deps), XFSProgs 7.1.1 (mkfs.xfs/xfs_repair), OpenZFS 2.4.4 (userspace + kernel modules for the installed `linux`). **Run after `linux`.** |
| `network` | iw, ethtool, usb_modeswitch, Libmbim, Libqmi, ModemManager **rebuilt** with `-Dqmi=true -Dmbim=true`, BIND dig/host/nslookup. |
| `devices` | Phone/MTP tooling: Libusb, Libmtp, Simple-Mtpfs, GnuPG chain (LibGCrypt/Libksba/GnuPG), Nvidia-Settings. |
| `pipewire` | ALSA-Lib 1.2.13 + PipeWire 1.4.0 + WirePlumber 0.5.17 (system-wide audio). |
| `pantheon` | elementary OS Pantheon desktop (from `Recipes/Pantheon/`). |
| `plasma` | KDE Plasma 6.7 desktop (Qt6/KF6/Plasma/Gear) from `Recipes/Plasma6-core/`. Needs `wayland` + `sddm`. |
| `merge` | **ISO assembly:** rebuilds the runtime fixes (`ensure_livefix_builds`), wipes `work/`, runs `refresh-merge.py` (base ISO + all `Packages/*.tar.bz2` → `work/rootfs`), reruns `chown` to the repo owner, then **auto-runs `livefix`**. |
| `livefix` | Single-step repair: rebuilds the GnuPG chain + glibc 2.44-2 + ProtonPlus, then re-merges and re-applies `apply-live-fixes.sh`. Equivalent to `merge` in one command. |
| `gamekcm` | Build only the Plasma-Desktop Game Controller KCM (SDL 2.30.2 + in-place `--keep` Plasma-Desktop rebuild). |
| `pkg <Name> <Version>` | Compile + package ONE custom program (`Compile Name Version --batch`). |
| `pkgkeep <Name> <Version>` | Same-version in-place rebuild (`--keep`, skips Pre_Installation_Preparation — for recompiling an already-installed indexed tree). |
| `all` | The whole wine-gaming + desktops + ISO sequence (§3.2). |
| `detach` | (run-build.sh) unmount the chroot binds. |

### 3.1 Component flags (non-interactive)

```
sudo ./run-build.sh --plan --gaming --plasma        # just print the resolved run list
sudo ./run-build.sh --gaming --plasma --iso         # build gaming + plasma + final ISO
sudo ./run-build.sh --list                          # list available components
sudo ./run-build.sh --all                           # every component + ISO
```

Available components: `lib32 wayland swayextras vulkan gaming ffxiv lutris fastfetch fs extras flatpak sddm appimage pantheon webkit plasma modem network music programming pipewire iso`. `--plan` prints the canonical run list instead of building. Defaults are stored in `.build-select` and reused by the menu.

### 3.2 `all` sequence (kernel → ISO)

```
sudo ./run-build.sh all
```

Resolves to: `proton sync linux nvidia nvdiag glibc32 fs lib32 wayland swayextras vulkan steam winetools mingw winedev protonplus pycompat pyxml sddm extras fastfetch appimage webkit pantheon plasma pipewire network merge aliens`.

---

## 4. The livefix — `apply-live-fixes.sh`

Idempotent post-merge runtime fixer, applied to a tree:

```
bash apply-live-fixes.sh <rootfs-tree>     # historically: sudo bash apply-live-fixes.sh work/rootfs
```

It is invoked automatically by `merge` and `livefix`, but you can also run it by
hand on `work/rootfs` after making tree edits without a full rebuild. `build.sh
step_livefix` additionally calls `ensure_gpg_chain` (builds LibGCrypt/Libksba/GnuPG
packages if missing) and `ensure_livefix_builds` (glibc 2.44-2 + ProtonPlus repack).

Sections it applies (numbered in the file). Highlights:

| § | Fix |
|---|---|
| 1–2 | SDDM greeter Qt: `qt.conf` beside `sddm-greeter` + `SddmComponents` QML onto the Qt import path. |
| 3–5 | `sddm`/`live` users + `video`/`input` groups, `/etc/shells` (pam_shells), PAM system-login/system-local-login stacks. |
| 6/6b | Real `sddm.conf` (autologin `live`, seatd env) + greeter/compositor log wrapper + udev input rule + weston cursor theme + inittab tty1 gated to sddm (console getty removed from tty1). |
| 8–9 | GdkPixbuf loader curation + librsvg LD_PRELOAD in Xsession. |
| 10 | `python → python3` symlink. |
| 11–12/12b | Elogind + SeatD + OpenSSH + dhcpcd + sddm boot tasks; resolv.conf nameservers (10.0.2.3 + 1.1.1.1); boot debug readback. |
| 13–13f | dbus-daemon-launch-helper at FHS paths; Mutter/Gala/Pantheon lib + session fixes; elogind/polkit bus-name policies. |
| 14–14e | lib32 symlink farm + ld.so.conf; .desktop/icons (Discord/Ren'Py/XIVLauncher/Heroic/NVIDIA); 'Install GoboLinux' live user entry; **NVIDIA runtime enablement**; Vulkan ICD + portal/libinput fixes. |
| 15–15c | sshd setup, passwordless sudo + polkit for `live`, setuid sweep. |
| 16–19 | Wingpanel + Polkit agent autostart; Wayland session target; GLVND EGL vendor files. |
| 30–31.6 | Plasma6/KF6 Qt6 runtime search paths, session glue, Qt6 modular plugin mirror, python3.11 merged site-packages. |
| 32 | OpenSSH live bootstrap: ed25519 host keys pre-baked (root-owned). |
| 33 | Non-interactive live boot (login prompt always appears). |
| 34 | Core GLib-family typelibs restored (Gio/GLib/GObject/GModule) for `gi.repository.Gio` (Lutris). |
| 35 | XIVLauncher: pre-create WINEPREFIX before wineboot. |
| 36 | Lutris data path → `lib/lutris/share` → program share. |
| 37 | VLC `qt.conf` (Qt xcb platform plugin). |
| 40 | PipeWire → BootUp/StartLiveCD task wiring, `PIPEWIRE_RUNTIME_DIR`/`PULSE_SERVER` env, disables old PulseAudio paths. |
| 41 | GoboNet autoconnect + rfkill + ModemManager/Bluetooth Start wiring. |
| 42 (≈) | ZFS: `zfs` module into `UserDefinedModules` (BootOptions) + boot-order/swap tweaks. |
| 43 | Phone/MTP: `/Mount/phone` mountpoint + FUSE setuid/fuse.conf + MtpPhone automount task. |

After the fixer's own chown hand-back, `step_livefix` **re-applies** root ownership
+ setuid (sudo/pkexec/unix_chkpwd/dbus helper/polkit-agent-helper-1), sudo plug-ins,
`sudoers` (root:root 0440), `/var/empty` (root:root 0755) and OpenSSH host keys
(600/644).

---

## 5. ZFS / XFS / LUKS install support — `zfs45.sh` and `zfs46.sh`

Two idempotent tree patchers (the "livefix" for the *installer*):

```
bash zfs45.sh <rootfs-tree>     # e.g. sudo bash zfs45.sh rootfs   (or work/rootfs)
bash zfs46.sh <rootfs-tree>     # run on top of zfs45
```

- **`zfs45.sh`** — ZFS-on-root for the custom SysVinit runtime: guards the OpenZFS
  90zfs dracut module against missing systemd units, anchors zpool/zfs/mount.zfs/
  zgenhostid into the initramfs `/sbin`, teaches `GenGrubConf` to emit
  `root=zfs:<dataset> boot=zfs` and to point every entry at the shipped
  `initramfs-<release>.img`, and patches the installer + `WriteBoot64`
  (`--add zfs`) for a ZFS root with a working swap zvol.
- **`zfs46.sh`** — LUKS + XFS + ZFS on top: the installer dropdown gains
  `Ext4, XFS, ZFS, LUKS+Ext4, LUKS+XFS, LUKS+ZFS`. Uses a **LUKS1** container named
  `gobo_crypt` (GRUB 2.12 has no argon2 module; LUKS1 keeps the bootloader able to
  unlock the root). Threads `fileSystem` through the installer's mount/unmount,
  adds swap zvols for ZFS roots, swap files otherwise, writes `crypttab` +
  `rd.luks.uuid` + `/dev/mapper/gobo_crypt` fstab root, bakes a fixed hostid
  (`6dfa7e42`) for deterministic `zpool create`, and adds the GRUB cryptodisk/crypto
  modules to the BIOS + EFI standalone images.

Both are idempotent (MARK comment `gobo livefix 45/46`). `zfs46.sh` handles every
file gracefully (reads, verifies, patches, marks) and simply warns on files it
cannot write (e.g. root-owned `WriteBoot64` in `rootfs`).

**After patching**, the ISO build flow is the normal one:

```
sudo ./run-build.sh merge        # (or: patch first, then merge+livefix)
./finalize-iso.sh
```

Folders of note: `openzfs_dracut/` — the 90zfs overlay payload for the initramfs.

---

## 6. Finalize the ISO — `finalize-iso.sh`

Runs on the **host** (no chroot). Re-creates the ISO from the merged tree:

```
./finalize-iso.sh
# or if work/ is root-owned after a merge:
sudo ./finalize-iso.sh
```

What it does:
1. Validates preconditions (`work/rootfs`, `work/isolinux/*`, isolinux.cfg references the squashfs).
2. Adds `console=ttyS0,115200n8 console=tty0` to every isolinux APPEND line (serial console mirror for VM diagnostics; idempotent).
3. `mksquashfs` the live tree → `work/gobolinux-live.squashfs` (**zstd -15**, slow for an ~11 GB tree; set `KEEP_SQUASH=1` to reuse an existing squashfs).
4. Takes the hybrid MBR from the reference ISO (`GoboLinux-017.01-x86_64.iso`, else the host's `isohdpfx.bin`).
5. `xorriso -as mkisofs` → `work/gobolinux.iso` (BIOS + El Torito + UEFI/efiboot.img hybrid).
6. Validates: hybrid signature `55aa`, `EFI PART` GPT, El Torito catalog, squashfs + isolinux.bin present.
7. Hands the artifacts back to the invoking user (no lingering root-owned files).

Outputs:
```
work/gobolinux.iso
work/gobolinux-live.squashfs
```

Testing:
```
qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm -cdrom work/gobolinux.iso
sudo dd if=work/gobolinux.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## 7. Building custom packages

The canonical recipes live in the **project repo**, **not** in `rootfs/`:

```
EDIT HERE ONLY:  ../Projects/BuildLiveCD/Recipes/<Name>/<Version>/Recipe
```

`step_sync` copies from `/mnt/repo` (bound to that repo) into
`rootfs/Data/Compile/Recipes/` on every build — edits in the chroot copy are
**silently overwritten**. (This bit us once: a Mesa virtio-gallium flag was added
to the wrong tree and never made it into the ISO.)

### Add a new package to the ISO

1. Write the recipe at `Recipes/<Name>/<Ver>/Recipe` (Gobo recipe format: `url`,
   `file_size`, `file_md5`, `recipe_type=manifest|configure|pkg`, `pre_install`,
   `post_install`, `manifest()`). Download the source tarball into `gobo-build/`
   if you want it staged for the build host.
2. `sudo ./run-build.sh pkg <Name> <Version>` — compile + package into `Packages/`
   (logs in `logs/<Name>.log`). Rerun `pkg` to retry after a failure.
3. Rebuilding an already-installed indexed package in place: `sudo ./run-build.sh pkgkeep <Name> <Version>`.
4. To force a rebuild, `rm -f Packages/<Name>--<Ver>--x86_64.tar.bz2` (compile skips
   when the tarball exists).
5. `sudo ./run-build.sh merge` — merge `Packages/` into `work/rootfs` (runs every
   fixer + livefix). Any package in `Packages/` is picked up by the auto-merge.
6. `./finalize-iso.sh` — produce the ISO.

### Custom package step shorthand (mirrors old /tmp helpers)

```
sudo ./run-build.sh pkg LibCanberra 0.30        # compile + package one program
sudo ./run-build.sh pkgkeep Plasma-Desktop 6.7.4 # in-place same-version rebuild
sudo ./run-build.sh devices                       # e.g. the phone/MTP package set
```

### Recipe + build gotchas baked into build.sh

- `MAKEFLAGS="-j$(nproc)"` is exported so WebKit/recursive-make builds parallelize.
- `compile <Name> <Ver> --lazy` resumes an existing broken source tree instead of
  wiping it (that's how the kernel survives a failed `strncpy` build).
- Python: the chroot keeps both the Gobo 3.8 site-packages (Scripts modules) and
  the new 3.11 interpreter on `PYTHONPATH`; the booted ISO gets the same via the
  `pycompat` `.pth`.
- Qt: `/usr/mkspecs`, `/usr/qml`, `/usr/translations` and `/usr/plugins/*` are
  symlinked into the active Qt tree so `find_package(Qt5)` doesn't FATAL_ERROR.

---

## 8. Aliens (language/package managers on the LiveCD)

`run-build.sh aliens` (also part of `all`, and spelled `iso` in the component
menu) writes the **Alien plugins + /System/Aliens scaffolds into the merged tree**
(`work/rootfs`). It needs the merge first:

```
sudo ./run-build.sh merge
# step_merge auto-runs apply-live-fixes, then:
# (aliens is NOT part of step_merge; run it explicitly, or use `all`/`--iso`)
sudo ./run-build.sh aliens
```

Performs, on `$B/work/rootfs`:
1. Creates the scaffold trees `/System/Aliens/{NPM,Cargo/bin,Go/bin,Odin}`.
2. Installs the plugin scripts `Alien-NPM`, `Alien-Cargo`, `Alien-Go`, `Alien-Odin`
   from `/mnt/repo/bin/` into `Programs/Scripts/017-GIT/bin/`.
3. Symlinks each into `/System/Index/bin/` (same style as the base ISO's
   Alien-CPAN/PIP/LuaRocks entries).

The base ISO already ships the Alien dispatcher + cabal/cpan/ctan/luarocks/pip
plugins; these add **npm, cargo, go, odin**. The managers/toolchains they wrap are
the NodeJS/Go/Odin packages from §3, and the tools depend on nothing further at
runtime (plain shell).

---

## 9. Full rebuild checklist (from scratch)

```
# 0. (one-time) requirements + recipe repo
# 1. Health check
sudo ./run-build.sh test

# 2. Everything
sudo ./run-build.sh all          # kernel → nvidia → glibc32 → fs → lib32 → wayland
                                 # → ... → wine → desktops → pipewire → network → merge
                                 # (merge auto-ends with livefix) → aliens

# 3. ISO on the host
./finalize-iso.sh                # sudo re-execs itself if work/ is root-owned

# 4. Boot tests
qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm -cdrom work/gobolinux.iso
# or the project's helpers: RunGoboLinuxVM-Plain.sh / RunGoboLinuxVM.sh
```

### Minimal rebuild loop (edit a recipe → new ISO)

```
# edit ../Projects/BuildLiveCD/Recipes/.../Recipe
sudo ./run-build.sh pkg <Name> <Ver>     # or step that compiles it
sudo ./run-build.sh merge                # re-extract + merge + livefix
./finalize-iso.sh
```

### Just re-apply runtime fixes without remerging

```
sudo ./run-build.sh livefix              # repairs gpg chain + glibc + ProtonPlus + re-applies fixes
# or, tree-level without any compile:
sudo bash apply-live-fixes.sh work/rootfs
```

### Cleanup / hygiene

```
sudo ./run-build.sh detach               # unmount chroot binds when done
./clean-desktop.sh [--dry-run]           # remove a whole desktop env from both trees (run AFTER merge)
./clean-weston.sh                        # purge all stale Weston build/install state
bash livefix-netprobe.sh                 # live-ISO DNS debug (fixes empty resolv.conf in the ISO)
./vfio-handoff.sh                        # NVIDIA GPU handoff helper for the passthrough VM
```

---

## 10. Supporting scripts on the host

- `refresh-merge.py` — RefreshLiveCD engine wrapped by `step_merge`; merges the
  base ISO + every tarball in `Packages/` into `work/rootfs`. Its output log:
  `logs/refresh.log`.
- `finalize-iso.sh` — see §6.
- `zfs45.sh` / `zfs46.sh` — see §5. Patches are also mirrored as
  `goboLinuxInstaller-xfs-zfs.patch`, `gobo-installer-swap-zfs.patch`,
  `gobo-zfs-sysvinit-support.patch`.
- `livefix-netprobe.sh` — one-shot live-ISO DNS fixer/verifier (only needed when
  debugging resolv.conf on a booted ISO).
- `refresh-merge.py` — see above.
- VM/launcher helpers live in the project repo (`RunGoboLinuxVM-Plain.sh`,
  `RunGoboLinuxVM.sh`); `vfio-handoff.sh` handles the GPU-passthrough variant.

---

## 11. Reference docs

- `NOTES.md` — detailed build history / troubleshooting log (DNS, sshd, tty1/sddm,
  XDG_RUNTIME_DIR, DRM udev gid 103, Mesa virtio, Steam ia32 libs, PipeWire, …).
- `PLASMA-NOTES.md` — the Plasma Wayland bring-up story (kwin env, plasmashell
  autostart, llvmpipe software GL).
- The canonical recipe repo (see §8 for upload guidance) and `Gobo_Linux_Recipes-AI`
- folder in this directory mirrors the recipe upload; **add recipes via the recipe
  repo**, then mirror/push.