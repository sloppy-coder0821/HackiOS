#!/bin/bash
# Time open-kernel boots (no Apple software): the prebuilt kernel (or the one built
# here) plus the tiny raw-syscall `hello` user space, through qemu/run.sh.
# usage: bench.sh [reps]            (default 1 boot per SMP setting)
# env: QEMU_SMP_LIST="1 4 8"        SMP settings to compare (default: "1 <host>")
#      BENCH_SECS=90                per-boot timeout, passed to run.sh
# Prints a table: SMP setting, seconds to user space (first "Hello from user space"
# on the serial log), total wall seconds. Logs go to logs/bench-*.log.
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
mkdir -p logs
K=xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
[ -f $K ] || K=prebuilt/mach.development.bcm2837
[ -f $K ] || { echo "bench.sh: no kernel (build one or keep prebuilt/)"; exit 1; }
H=prebuilt/userland/hello
[ -f $H ] || { echo "bench.sh: no $H"; exit 1; }
REPS=${1:-1}
HOST_CPUS=$(nproc 2>/dev/null || echo 4)
[ "$HOST_CPUS" -gt 8 ] && HOST_CPUS=8
LIST=${QEMU_SMP_LIST:-"1 $HOST_CPUS"}
SECS=${BENCH_SECS:-90}
echo "bench.sh: kernel=$K smp_list='$LIST' reps=$REPS host_cpus=$(nproc 2>/dev/null || echo ?) mem_avail=$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo 2>/dev/null || echo ?)MB"
printf '%-6s %-12s %-12s %s\n' SMP to_userspace total log
for SMP in $LIST; do
	for r in $(seq 1 "$REPS"); do
		LOG=logs/bench-smp${SMP}-r${r}.log
		xnuloader/mkpayload.py -o qemu/payload.bin kernel=$K ramdisk=$H \
			--cmdline "cpus=$SMP loader_return_after=$SECS epoch=$(date +%s) virtio_input=1" >/dev/null || exit 1
		start=$(date +%s.%N)
		QEMU_SMP=$SMP qemu/run.sh "$SECS" >"$LOG" 2>&1 &
		qpid=$!
		marker=""
		while kill -0 $qpid 2>/dev/null; do
			if [ -z "$marker" ] && grep -a -q "Hello from user space" "$LOG" 2>/dev/null; then
				marker=$(date +%s.%N)
			fi
			sleep 0.2
		done
		wait $qpid
		# the boot can finish between the last poll and the exit: check once more
		if [ -z "$marker" ] && grep -a -q "Hello from user space" "$LOG" 2>/dev/null; then
			marker=$(date +%s.%N)
		fi
		end=$(date +%s.%N)
		t_user=$(awk -v s="$start" -v m="${marker:-$end}" 'BEGIN { printf "%.1f", m - s }')
		t_tot=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')
		[ -n "$marker" ] || t_user="MISS"
		printf '%-6s %-12s %-12s %s\n' "$SMP" "$t_user" "$t_tot" "$LOG"
	done
done
