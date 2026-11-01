#!/bin/bash
# Boot the whole system under QEMU: the big system image preloaded at the loader's resident
# address (it becomes /dev/md0, the root) and the small image in the payload (/dev/md1), the
# same arrangement `xl ramdisk` + `xl run` make on the phone.
# usage: run-ios.sh [seconds] [extra qemu args...]
# seconds 0, inf or unlimited: run with no time limit (end with qemu/stop.sh).
#
# Counting anything in the log this writes: every console line comes out TWICE, the second copy in a
# block replayed some thousands of lines later (take any launchd line and grep -n it). So `grep -c` gives
# about double, and `sort -u` does not fix it either, because other processes' output interleaves and
# splits one of the two copies. Count distinct events instead -- by timestamp, or by program and pid for
# "Successfully spawned". The phone's logs do not do this; `xl log` fetches the buffer once.
#
# env: ROOT=<small image>, IMG=<system image>, CMDLINE=<extra boot-args>
#      QEMU_SMP=<n>         vCPUs (default: host CPUs, capped at 8); cpus=N and
#                          fb_threads=N are added to the kernel command line unless
#                          CMDLINE already sets them
#      QEMU_RAM_GB=<n>     the guest's RAM, default 7: memory then ends where the phone's does and the
#                          kernel gets the same 4.2 GB window (the system image included) as on the phone.
#                          The host needs about 2.5 GB per running instance.
#      QEMU_NET=1          with a network (default 1: a virtio network device, behind it QEMU's own "user" network
#                          (it hands out an address by DHCP, answers DNS and passes connections on to
#                          this machine's network; no privileges needed). The kernel makes en0 of it
#                          (boot-arg virtio_net=1, added here); see userland/src/net_test.m for the rest.
#      QEMU_GPU=1          with a virtio GPU beside ramfb (boot-arg virtio_gpu=1, added here);
#                          Phase 1: the kernel's driver probes it and reads its scanouts
#      AUDIO=<where>       what plays the sound of iOS: a QEMU audio back end (pipewire, pa, alsa, sdl: each
#                          needs its QEMU module, e.g. the package qemu-audio-pipewire) or FILE.wav to
#                          write it into a file instead. Default: nowhere (the guest plays all the same).
#      QEMU_INSTANCE=<n>   to run several at once: each number has its own monitor and QMP ports
#                          (4444 + 10n, 4445 + 10n); the file qemu/instance sets it for a working copy.
#                          touch.py, screendump.sh and stop.sh follow the same rule.
# The machine has a display (ramfb; without one SpringBoard does not start): the loader sets a mode of the
# size of the phone's screen. qemu/screendump.sh saves a picture of it (through the monitor on port 4444).
# Add "-display gtk" to see it in a window and use it with the mouse: the pointer with the left button
# held is a finger (the keys L, H, Up and Down are the lock, home and volume buttons).
# Touches can also be sent from a script: qemu/touch.py (through the QMP socket on port 4445).
#
# The system image is not read into QEMU: guest RAM is a private mapping of qemu/ram.img, a sparse
# file that holds the image at the right offset (reflinked, so it costs neither disk space nor
# host RAM).
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
# make the local/rootless QEMU visible to the capability checks below and to run.sh
if [ -z "${QEMU_BIN:-}" ]; then
	QEMU_BIN=$(command -v qemu-system-aarch64 2>/dev/null)
	for d in /data/qemu-root/usr/bin /tmp/qemu-root/usr/bin /usr/bin /usr/local/bin; do
		[ -n "$QEMU_BIN" ] && break
		[ -x "$d/qemu-system-aarch64" ] && QEMU_BIN=$d/qemu-system-aarch64
	done
fi
[ -n "$QEMU_BIN" ] && export PATH="$(dirname "$QEMU_BIN"):$PATH"
# SMP: guest vCPUs follow the host (capped at 8) unless QEMU_SMP says otherwise,
# and the kernel is told the same number through cpus=N unless CMDLINE has it
HOST_CPUS=$(nproc 2>/dev/null || echo 4)
[ "$HOST_CPUS" -gt 8 ] && HOST_CPUS=8
export QEMU_SMP=${QEMU_SMP:-$HOST_CPUS}
case " $CMDLINE " in
*cpus=*) ;;
*) CMDLINE="cpus=$QEMU_SMP $CMDLINE" ;;
esac
# the frame scaler (MiniIOMobileFramebuffer) threads over vCPUs: match them
# (default in the kernel is 3); frame rate/quality left for later tuning
case " $CMDLINE " in
*fb_threads=*) ;;
*) CMDLINE="fb_threads=$QEMU_SMP $CMDLINE" ;;
esac
K=xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
[ -f $K ] || { K=prebuilt/mach.development.bcm2837; echo "run-ios.sh: no kernel built here, using $K" >&2; }
IMG=${IMG:-userland/system.apfs}
ROOT=${ROOT:-userland/root.apfs}
[ -f "$IMG" ] && [ -f "$ROOT" ] || { echo "run-ios.sh: $IMG or $ROOT is missing (userland/build.sh makes them)"; exit 1; }
SECS=${1:-60}; shift
# SECS of 0, inf or unlimited: no time limit. The kernel sets no return timer
# (loader_return_after missing or 0: osfmk/arm64/loader_return.c), and QEMU
# runs without timeout: end it with qemu/stop.sh, the monitor, or Ctrl-C.
case "$SECS" in
0|inf|unlimited|forever) RETURN_AFTER=0 ;;
*) RETURN_AFTER=$SECS ;;
esac
RAM_BASE=0x40000000 RD_ADDR=0xFC000000
RAM_GB=${QEMU_RAM_GB:-7}
RAM_SIZE=$((RAM_GB << 30)) FILE_SIZE=$((12 << 30))
INSTANCE=${QEMU_INSTANCE:-$(cat qemu/instance 2>/dev/null || echo 0)}
# an instance takes 2.5-3 GB of host memory; starting one that does not fit gets something killed
AVAILABLE=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
if [ "${AVAILABLE:-9999}" -lt 3000 ] && [ -z "$QEMU_FORCE" ]; then
	echo "run-ios.sh: only $AVAILABLE MB of memory available on this machine: stop another QEMU first (QEMU_FORCE=1 to start anyway)"
	exit 1
fi

if [ ! -f qemu/ram.img ] || [ "$IMG" -nt qemu/ram.img ]; then
	python3 - "$IMG" qemu/ram.img $((RD_ADDR - RAM_BASE)) $FILE_SIZE <<'PY' || exit 1
import os, sys
src = os.open(sys.argv[1], os.O_RDONLY)
dst = os.open(sys.argv[2], os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
offset, size = int(sys.argv[3]), int(sys.argv[4])
os.ftruncate(dst, size)
total, done = os.fstat(src).st_size, 0
while done < total:
    done += os.copy_file_range(src, dst, total - done, done, offset + done)
PY
fi
NET=()
if [ "${QEMU_NET:-1}" != 0 ]; then
	NET=(-netdev user,id=net0 -device virtio-net-device,netdev=net0)
	CMDLINE="virtio_net=1 $CMDLINE"
fi
# the sound device (QEMU 8.2 or newer has one for this machine): the kernel's sink for /dev/hakios-audio
SOUND=()
if qemu-system-aarch64 -device help 2>/dev/null | grep -q '"virtio-sound-device"'; then
	case "${AUDIO:-none}" in
	*.wav) SOUND=(-audiodev "wav,id=snd,path=$(readlink -f "$AUDIO")") ;;
	*) SOUND=(-audiodev "${AUDIO:-none},id=snd") ;;
	esac
	SOUND+=(-device virtio-sound-device,audiodev=snd,streams=1)   # one stream: output, no microphone of the host
	CMDLINE="virtio_sound=1 $CMDLINE"
fi
# the GPU (QEMU 8.2 or newer has one for this machine): the kernel's
# virtio-gpu driver brings it up as a display beside ramfb ( Phase 1: probe
# and scanout info only; presenting through it comes next)
GPU=()
if [ "${QEMU_GPU:-0}" != 0 ]; then
	GPU=(-device virtio-gpu-device)
	CMDLINE="virtio_gpu=1 virtio_present=1 $CMDLINE"
fi
if [ "$RETURN_AFTER" != 0 ]; then
	RETURN_ARG="loader_return_after=$RETURN_AFTER "
	RUN_SECS=$((RETURN_AFTER + 40))
else
	RETURN_ARG=""
	RUN_SECS=0
fi
xnuloader/mkpayload.py -o qemu/payload.bin kernel=$K ramdisk=$ROOT --rdres "$(printf '%x' "$(stat -c %s "$IMG")")" \
	--cmdline "${RETURN_ARG}epoch=$(date +%s) virtio_input=1 $CMDLINE" >/dev/null || exit 1
QEMU_MEM=${RAM_GB}G exec qemu/run.sh $RUN_SECS \
	-object memory-backend-file,id=ram,size=$RAM_SIZE,mem-path="$PWD/qemu/ram.img",share=off \
	-machine memory-backend=ram \
	-global virtio-mmio.force-legacy=false -device virtio-tablet-device -device virtio-keyboard-device "${NET[@]}" "${SOUND[@]}" "${GPU[@]}" \
	-device ramfb -monitor tcp:127.0.0.1:$((4444 + 10 * INSTANCE)),server,nowait \
	-qmp tcp:127.0.0.1:$((4445 + 10 * INSTANCE)),server,nowait "$@"
