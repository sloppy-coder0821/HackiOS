#!/bin/bash
# check-host.sh: verify this machine can fetch, build and run HackiOS in QEMU.
# Run it first; it fails fast with install instructions instead of a cryptic
# error halfway through. Usage: tools/check-host.sh
# Checks: python3, cc, 7z >= 23 (reads APFS), lz4, qemu-system-aarch64,
# an edk2-aarch64 firmware, >= 12 GB free disk, >= 4 GB available memory.
fail=0
need() { # need NAME HINT...: command must exist
	if ! command -v "$1" >/dev/null; then
		echo "missing: $1 -- $2"
		fail=1
		return 1
	fi
	return 0
}
echo "--- required tools ---"
need python3 "python3 (apt: python3 / brew: python3)"
need cc "a C compiler (apt: build-essential / dnf: gcc / pacman: base-devel / brew: Xcode CLT)"
command -v lz4 >/dev/null && echo "ok: lz4" || echo "note: no lz4 -- harmless (no script calls it; the kernel builds its own)"
if need 7z "7-Zip 23+ (apt: p7zip-full is TOO OLD, use the 7zip package / dnf: 7zip / pacman: 7zip / brew: sevenzip)"; then
	ver=$(7z i 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
	major=${ver%%.*}
	if [ -n "$major" ] && [ "$major" -ge 23 ] 2>/dev/null; then
		echo "ok: 7z version $ver"
	else
		echo "too old: 7z version ${ver:-unknown} -- APFS needs 7-Zip 23 or newer (p7zip 16/17 cannot read it)"
		fail=1
	fi
fi
echo "--- QEMU ---"
QEMU_BIN=$(command -v qemu-system-aarch64 2>/dev/null)
for d in /data/qemu-root/usr/bin /tmp/qemu-root/usr/bin /usr/bin /usr/local/bin; do
	[ -n "$QEMU_BIN" ] && break
	[ -x "$d/qemu-system-aarch64" ] && QEMU_BIN=$d/qemu-system-aarch64
done
if [ -z "$QEMU_BIN" ]; then
	echo "missing: qemu-system-aarch64 -- apt: qemu-system-arm / dnf: qemu-system-aarch / pacman: qemu-system-aarch64 / brew: qemu"
	fail=1
else
	echo "ok: $QEMU_BIN ($("$QEMU_BIN" --version 2>/dev/null | head -n 1))"
fi
FW_OK=0
for f in /usr/share/edk2/aarch64/QEMU_EFI.fd \
	 /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
	 /usr/share/AAVMF/AAVMF_CODE.fd \
	 /data/qemu-root/usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
	 /tmp/qemu-root/usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
	[ -f "$f" ] && { echo "ok: UEFI firmware $f"; FW_OK=1; break; }
done
if [ "$FW_OK" != 1 ]; then
	echo "missing: edk2-aarch64 firmware -- apt: qemu-efi-aarch64 / dnf: edk2-aarch64 / pacman: edk2-aarch64"
	fail=1
fi
echo "--- resources ---"
FREE_KB=$(df -k . 2>/dev/null | awk 'NR==2 { print $4 }')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt $((12 * 1024 * 1024)) ]; then
	echo "low disk: $((FREE_KB / 1024 / 1024)) GB free here -- 12 GB or more is needed"
	fail=1
else
	echo "ok: disk $((FREE_KB / 1024 / 1024)) GB free"
fi
AVAIL_MB=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 9999)
if [ "$AVAIL_MB" -lt 4000 ]; then
	echo "note: only $AVAIL_MB MB available -- close other programs before starting QEMU (needs ~3 GB)"
else
	echo "ok: memory $AVAIL_MB MB available"
fi
if [ "$fail" != 0 ]; then
	echo "check-host.sh: FAILED -- fix the lines above, then re-run me"
	exit 1
fi
if grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
	echo "--- WSL2 notes ---"
	echo "ok: running under WSL ($(uname -r | cut -c1-60))"
	echo "info: give WSL enough RAM for the 7 GB guest: %USERPROFILE%\\.wslconfig with"
	echo "info:   [wsl2]"
	echo "info:   memory=12GB"
	echo "info: display: -display gtk works with WSLg (Windows 11); otherwise"
	echo "info:   QEMU_DISPLAY=vnc=:0 qemu/run-fast.sh ... and a Windows VNC viewer,"
	echo "info:   or -display none with qemu/screendump.sh for screenshots."
fi
echo "check-host.sh: OK -- run: sysimage/fetch.sh && REST=1 userland/build.sh"
