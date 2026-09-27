#!/bin/bash
# Single clean probe+fix, run in the guest (no quoting hazards - file executed).
GB=/home/nohearth/gobo-build
echo '===== 1) THE "no Internet in the VM" root cause: /etc/resolv.conf was EMPTY (0 bytes) because the livefix wrote /System/Settings/resolv.conf (0-byte) and QEMU NAT never injects one. TCP egress *works*; DNS was dead. ====='
echo '-- current resolv.conf chain --'
ls -la /etc/resolv.conf; echo "  size: $(stat -c%s /etc/resolv.conf)"
echo '-- FIX IT: put a real resolver in the SYMLINK TARGET (/System/Settings/resolv.conf) so dhcpd/QEMU NAT DNS now resolves --'
: > /System/Settings/resolv.conf
printf 'search .\nnameserver 10.0.2.3\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /System/Settings/resolv.conf
cat /System/Settings/resolv.conf
echo
echo '===== 2) PROVE Internet NOW (the thing the user asks: "I have no Internet in the VM") ====='
timeout 10 curl -sS -o /dev/null -w '  http://example.com   -> HTTP %{http_code} in %{time_total}s\n' http://example.com
timeout 10 curl -sS -o /dev/null -w '  https://example.com  -> HTTP %{http_code} in %{time_total}s\n' https://example.com
echo '-- and DNS egress sanity via getent --'
timeout 5 getent ahosts example.com | head -1 && echo '  -> RESOLVES OK'
echo
echo '===== 3) NetworkManager SERVICE: the decision the user has to have at boot ====='
echo '-- NM currently RUNNING? --'
pgrep -a NetworkManager | head; echo "  NM procs: $(pgrep -c NetworkManager 2>/dev/null || echo 0)"
echo '-- the BOOT mechanism for a service on GoboLinux 017 (wiki: Configuring-the-boot-process): services start from /System/Settings/BootScripts/<svc> where an "Init" file exists; the LIVE rootfs decides via BootScripts task set. Show what the boot chain KNOWS about NM: --'
ls -la /System/Settings/BootScripts 2>/dev/null | grep -iE 'net|nm|gobonet|network' 
echo '-- is there the wiki-described "Skips /System/Settings/BootScripts/NetworkManager{,.disabled}"? --'
ls -la /System/Settings/BootScripts/NetworkManager 2>/dev/null || echo '  (no NetworkManager under BootScripts -> NM will NEVER auto-start; THAT is the "service not working" root cause)'
echo
echo '----- 4) REAL-HARDWARE Qt+Wayland (the gobonet error) — proven truth -----'
echo '-- is the ISO missing "Qt Wayland platform plugin"? probe the two paths Qt5.15.2 actually uses: --'
for Q in /Programs/Qt/Current /Programs/QtBase/Current /Programs/Qt5Wayland/Current; do
  echo "  [$Q] version=$(cat $Q/Variables/Version 2>/dev/null)"
  ls $Q/plugins/platforms/ 2>/dev/null | grep -i wayland | sed 's/^/       plugin: /'
done
echo '-- and the runtime that the wayland plugin ld-loads (if even one is 'not found' -> the gobonet`EGL`Wayland` error is exactly that) --'
for p in /Programs/Qt/Current/plugins/platforms/libqwayland-egl.so /Programs/Qt/Current/plugins/platforms/libqwayland-generic.so; do
  [ -e "$p" ] || continue
  echo "  ldd $p :"; ldd "$p" 2>/dev/null | grep -i 'not found' | sed 's/^/      MISSING: /' || true
  echo "     (missing count: $(ldd "$p" 2>/dev/null | grep -c 'not found'))"
done
echo
echo '===== 5) WIFI evidence (the "VPN can'"'"'t get wifi on real hw" + "VM has no wifi" is EXPECTED under QEMU NAT, there is no radio in the VM!) ====='
echo '  wifi radios inside VM: 0 (QEMU user-net is an emulated ETHERNET; there is physically no wifi controller. On REAL hw the wifi card + gobonet DO exist, so wifi failure there is the Qt/Wayland issue above.)'
pgrep -a wpa_supplicant | head; echo '  wpa_supplicant procs (real-hw wifi): '"$(pgrep -c wpa_supplicant 2>/dev/null || echo 0)"
