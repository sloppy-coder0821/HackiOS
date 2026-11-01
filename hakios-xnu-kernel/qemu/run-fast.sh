#!/bin/bash
# QEMU-fast preset for HackiOS: the same iOS boot as qemu/run-ios.sh with the
# settings that make interactive use on TCG (x86_64 host, no KVM for aarch64)
# noticeably smoother. No rebuild needed; images are reused as-is.
# usage: qemu/run-fast.sh [seconds] [extra qemu args...]
#   e.g. qemu/run-fast.sh 1200 -display gtk
#   qemu/run-fast.sh 0 -display gtk   no time limit (end with qemu/stop.sh)
# env passthrough: every QEMU_*/CMDLINE/ROOT/IMG/AUDIO/QEMU_INSTANCE var of
# run-ios.sh works; unset values below are filled with fast defaults.
# fast defaults (override by exporting before calling):
#   QEMU_SMP=8            TCG scales to ~8 vCPU on a 16-thread host; run-ios.sh
#                         already caps host CPUs at 8 and sets cpus=/fb_threads=
#   QEMU_TB_MB=1024       translation cache; run.sh only auto-picks 1024 when
#                         the host has >12 GB available, we want it anyway
#   QEMU_RAM_GB=7         KEEP at 7: the guest layout (RAM_BASE 0x40000000,
#                         resident image at 0xFC000000 + ~2.4 GB system.apfs)
#                         needs one contiguous window; 5 GB fails in the loader
#                         with "not enough contiguous RAM" (verified). Host
#                         pressure is handled by running one instance only.
#   CMDLINE additions: fb_filter=0 (nearest-neighbour scale, cheaper than the
#     default bilinear), fb_queue=1 (at most one frame waiting: less latency,
#     less memory traffic), fb_beat=0 (present at once, no beat wait).
#     fb_threads= is left to run-ios.sh (= QEMU_SMP).
#     NOTE: QEMU has no GPU path (GL lib loads only with gpu=1 on the phone),
#     so CoreAnimation uses its software rasterizer: fewer pixels/cheaper
#     scaling is where the frames come from.
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
export QEMU_SMP=${QEMU_SMP:-8}
export QEMU_TB_MB=${QEMU_TB_MB:-1024}
export QEMU_RAM_GB=${QEMU_RAM_GB:-7}
case " $CMDLINE " in
*fb_filter=*) ;;
*) CMDLINE="fb_filter=0 $CMDLINE" ;;
esac
case " $CMDLINE " in
*fb_queue=*) ;;
*) CMDLINE="fb_queue=1 $CMDLINE" ;;
esac
case " $CMDLINE " in
*fb_beat=*) ;;
*) CMDLINE="fb_beat=0 $CMDLINE" ;;
esac
export CMDLINE
echo "run-fast.sh: smp=$QEMU_SMP tb=${QEMU_TB_MB}MB ram=${QEMU_RAM_GB}G cmdline_add='fb_filter=0 fb_queue=1 fb_beat=0'" >&2
exec qemu/run-ios.sh "$@"
