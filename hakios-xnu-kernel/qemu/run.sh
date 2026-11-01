#!/bin/bash
# Boot the XNU loader + kernel payload under QEMU (virt, GICv3, UEFI at EL1).
# usage: run.sh [seconds] [extra qemu args...]
# seconds 0, inf or unlimited: run QEMU with no timeout (Ctrl-C or the monitor ends it).
# env: QEMU_BIN            qemu-system-aarch64 binary (default: PATH, then a rootless
#                          install at /data/qemu-root/usr/bin or /tmp/qemu-root/usr/bin)
#      QEMU_TB_MB          megabytes for QEMU's cache of translated code (default 384,
#                          1024 when the host has more than 12 GB available)
#      QEMU_SMP            vCPUs of the machine (default: host CPUs, capped at 8); the kernel
#                          uses as many of them as its boot-arg cpus=N says (run-ios.sh adds
#                          it automatically), one without it
#      QEMU_MTTCG          1 (default when SMP > 1): multi-threaded TCG; 0 to disable
#      QEMU_CPU            guest CPU (default cortex-a76)
#      QEMU_DISPLAY        QEMU display (default none; "gtk" for a window)
#      QEMU_EFI, QEMU_VARS the UEFI firmware for aarch64 guests (auto-detected: Arch's
#                          edk2-aarch64, Debian/Ubuntu's qemu-efi-aarch64 or AAVMF)
cd "$(dirname "$0")"
T=${1:-20}; shift
# --- the emulator ---
if [ -z "${QEMU_BIN:-}" ]; then
	QEMU_BIN=$(command -v qemu-system-aarch64 2>/dev/null)
	for d in /data/qemu-root/usr/bin /tmp/qemu-root/usr/bin /usr/bin /usr/local/bin; do
		[ -n "$QEMU_BIN" ] && break
		[ -x "$d/qemu-system-aarch64" ] && QEMU_BIN=$d/qemu-system-aarch64
	done
fi
[ -n "$QEMU_BIN" ] && [ -x "$QEMU_BIN" ] || { echo "run.sh: qemu-system-aarch64 not found (set QEMU_BIN)"; exit 1; }
# --- the firmware ---
if [ -z "${QEMU_EFI:-}" ]; then
	for f in /usr/share/edk2/aarch64/QEMU_EFI.fd \
		 /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
		 /usr/share/AAVMF/AAVMF_CODE.fd \
		 /data/qemu-root/usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
		 /tmp/qemu-root/usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
		[ -f "$f" ] && { QEMU_EFI=$f; break; }
	done
fi
EFI=$QEMU_EFI
[ -f "$EFI" ] || { echo "run.sh: no UEFI firmware found (set QEMU_EFI and QEMU_VARS)"; exit 1; }
FW=()
EFI_SIZE=$(stat -c %s "$EFI" 2>/dev/null || echo 0)
if [ "$EFI_SIZE" -ge 67108864 ]; then
	# a full 64 MB flash image (Arch's edk2-aarch64 layout): code + var store
	if [ ! -f vars.fd ]; then
		VARS_TMPL=$QEMU_VARS
		if [ -z "$VARS_TMPL" ]; then
			for f in /usr/share/edk2/aarch64/QEMU_VARS.fd /usr/share/AAVMF/AAVMF_VARS.fd; do
				[ -f "$f" ] && { VARS_TMPL=$f; break; }
			done
		fi
		if [ -n "$VARS_TMPL" ]; then
			cp "$VARS_TMPL" vars.fd
		else
			# no var-store template: a blank store; EDK2 initializes it on first boot
			dd if=/dev/zero of=vars.fd bs=1M count=64 status=none
		fi
	fi
	FW=(-drive if=pflash,format=raw,readonly=on,file="$EFI" \
	    -drive if=pflash,format=raw,file=vars.fd)
else
	# a small firmware image (Debian's qemu-efi-aarch64 QEMU_EFI.fd): boot it as BIOS;
	# pflash would refuse it ("device requires 67108864 bytes")
	FW=(-bios "$EFI")
fi
# --- speed: SMP + translation cache + MTTCG ---
HOST_CPUS=$(nproc 2>/dev/null || echo 4)
[ "$HOST_CPUS" -gt 8 ] && HOST_CPUS=8
SMP=${QEMU_SMP:-$HOST_CPUS}
[ "$SMP" -ge 1 ] 2>/dev/null || SMP=1
if [ -z "${QEMU_TB_MB:-}" ]; then
	QEMU_TB_MB=384
	AVAIL_MB=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
	[ "${AVAIL_MB:-0}" -gt 12288 ] && QEMU_TB_MB=1024
fi
ACCEL="tcg,tb-size=${QEMU_TB_MB}"
if [ "$SMP" -gt 1 ] && [ "${QEMU_MTTCG:-1}" != 0 ]; then
	ACCEL="$ACCEL,thread=multi"
fi
# the loader is the boot application of the little FAT volume QEMU makes of esp/:
# the one built here, or else the one that comes with the repository
L=../xnuloader/loader.efi; [ -f $L ] || L=../prebuilt/loader.efi
mkdir -p esp/EFI/BOOT && cp -u $L esp/EFI/BOOT/BOOTAA64.EFI
case "$T" in
0|inf|unlimited|forever)
	exec "$QEMU_BIN" -M virt,gic-version=3 -cpu ${QEMU_CPU:-cortex-a76} -smp "$SMP" -m ${QEMU_MEM:-6G} \
	  -accel "$ACCEL" \
	  "${FW[@]}" \
	  -drive file=fat:rw:esp,format=raw,if=virtio \
	  -device loader,file=payload.bin,addr=0xF0000000,force-raw=on \
	  -display ${QEMU_DISPLAY:-none} -serial stdio -monitor none -no-reboot "$@" 2>&1
	;;
*)
	exec timeout "$T" "$QEMU_BIN" -M virt,gic-version=3 -cpu ${QEMU_CPU:-cortex-a76} -smp "$SMP" -m ${QEMU_MEM:-6G} \
	  -accel "$ACCEL" \
	  "${FW[@]}" \
	  -drive file=fat:rw:esp,format=raw,if=virtio \
	  -device loader,file=payload.bin,addr=0xF0000000,force-raw=on \
	  -display ${QEMU_DISPLAY:-none} -serial stdio -monitor none -no-reboot "$@" 2>&1
	;;
esac
