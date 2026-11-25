#!/usr/bin/env bash
# Boot the kernel in QEMU through Limine (UEFI).
#
# Usage:
#   tools/run.sh <kernel.elf>                interactive, serial on stdio
#   tools/run.sh <kernel.elf> --test         headless smoke test, exit code = verdict
#   tools/run.sh <kernel.elf> --test-fault   headless fault test, expects a handled #PF
#   tools/run.sh <kernel.elf> --test-boot    headless boot test, checks the fallback timer
#
# The ESP is exposed to QEMU as a synthesized FAT (vvfat) drive backed by a
# directory, so no root, loop devices, mtools or ISO tooling are required. M18
# adds a generated FAT16 disk on a second (legacy) virtio-blk device and a
# Limine-module initramfs tar; both are built with Python's standard library.

set -euo pipefail

KERNEL="${1:?usage: run.sh <kernel.elf> [--test|--test-fault|--test-boot]}"
MODE=run
case "${2:-}" in
  --test) MODE=smoke ;;
  --test-fault) MODE=fault ;;
  --test-boot) MODE=boot ;;
  "") ;;
  *) echo "run.sh: unknown mode: ${2:-}" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMP="${ZIG_KERNEL_SMP:-4}"
LIMINE_BIN="${LIMINE_BIN:-$ROOT/third_party/limine}"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

# The cross-CPU time probe needs an AP. A single-CPU run logs an explicit skip
# marker instead of the skew/sleep line.
has_m15_cross_cpu() {
  if [ "$SMP" -le 1 ]; then
    grep -q "m15: cross-cpu skipped cpus=1" "$WORK/serial.log"
  else
    grep -q "m15: cross-cpu skew_ns=.* sleep_ns=.* tolerance_ns=" "$WORK/serial.log"
  fi
}

missing=0
for f in "$KERNEL" "$LIMINE_BIN/BOOTX64.EFI" "$OVMF_CODE" "$OVMF_VARS_SRC" "$ROOT/src/user/proc.elf"; do
  if [ ! -e "$f" ]; then echo "run.sh: missing $f" >&2; missing=1; fi
done
[ $missing -eq 0 ] || exit 1

WORK="$(mktemp -d /tmp/zig-kernel.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ESP="$WORK/esp"
mkdir -p "$ESP/EFI/BOOT"
cp "$LIMINE_BIN/BOOTX64.EFI" "$ESP/EFI/BOOT/BOOTX64.EFI"
cp "$ROOT/boot/limine.conf" "$ESP/EFI/BOOT/limine.conf"
cp "$ROOT/boot/limine.conf" "$ESP/limine.conf"
cp "$KERNEL" "$ESP/zig-kernel"

# M18 fixtures: a FAT16 disk served by legacy virtio-blk and a Limine-module
# initramfs. Both are generated per run so no binary images live in the tree.
python3 "$ROOT/tools/mkdisk.py" "$WORK/disk.img" --init-elf "$ROOT/src/user/proc.elf"
python3 "$ROOT/tools/mkinitramfs.py" "$WORK/initramfs.tar"
cp "$WORK/initramfs.tar" "$ESP/initramfs.tar"

cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
chmod u+w "$WORK/OVMF_VARS.fd"

ACCEL=(-accel tcg -cpu max)
if [ -r /dev/kvm ] && [ -w /dev/kvm ] && [ "${ZIG_KERNEL_NO_KVM:-0}" != "1" ]; then
  # KVM hides the invariant-TSC CPUID bit by default for migration safety. On a
  # host that advertises nonstop_tsc, expose it so the TSC clocksource path is
  # actually tested instead of only the tick fallback.
  if grep -qw nonstop_tsc /proc/cpuinfo 2>/dev/null; then
    ACCEL=(-accel kvm -cpu host,+invtsc)
  else
    ACCEL=(-accel kvm -cpu host)
  fi
fi

QEMU=(
  qemu-system-x86_64
  -machine q35
  "${ACCEL[@]}"
  -smp "$SMP"
  -m 256M
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$WORK/OVMF_VARS.fd"
  -drive "format=raw,file=fat:rw:$ESP,if=none,id=esp"
  -device virtio-blk-pci,drive=esp,disable-legacy=on
  -drive "format=raw,file=$WORK/disk.img,if=none,id=blk0"
  -device virtio-blk-pci,drive=blk0,disable-modern=on
  -boot order=c
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
  -no-reboot
  -display none
  -net none
)

if [ "$MODE" != "run" ]; then
  TIMEOUT=90
  if [ "$MODE" = "boot" ]; then TIMEOUT=20; fi
  set +e
  timeout "$TIMEOUT" "${QEMU[@]}" -serial "file:$WORK/serial.log"
  status=$?
  set -e
  if [ -f "$WORK/serial.log" ]; then
    sed -e 's/\r$//' "$WORK/serial.log"
  fi

  if [ "$MODE" = "smoke" ]; then
    # isa-debug-exit reports (value << 1) | 1: 0x10 -> 33, 0x11 -> 35.
    case $status in
      33)
        if grep -q "returned from int3" "$WORK/serial.log" &&
           grep -q "M15 checks passed" "$WORK/serial.log" &&
           grep -q "m15: tsc supported=.* invariant=.* calibrated=.* hz=.* source=.*" "$WORK/serial.log" &&
           grep -q "m15: rate_ns=.* expected_ns=.* tolerance_ns=" "$WORK/serial.log" &&
           has_m15_cross_cpu &&
           grep -q "m15: deadlines pushes=.* pops=.*" "$WORK/serial.log" &&
           grep -q "m15: join joined=joined/42 already=already_finished/7 twice=invalid timeout=timeout retry=joined/9" "$WORK/serial.log" &&
           grep -q "m15: priority order=2,1,0" "$WORK/serial.log" &&
           grep -q "m15: fallback source=ticks monotonic=1" "$WORK/serial.log" &&
           grep -q "M16 checks passed" "$WORK/serial.log" &&
           grep -q "m16: user write ok" "$WORK/serial.log" &&
           grep -q "m16: user sleep ok" "$WORK/serial.log" &&
           grep -q "m16: user exit status=42" "$WORK/serial.log" &&
           grep -q "m16: user null fault status=-15" "$WORK/serial.log" &&
           grep -q "m16: isolation data a=161 b=178" "$WORK/serial.log" &&
           grep -q "m16: isolation extra holder=126 probe=-15" "$WORK/serial.log" &&
           grep -qE "m16: preemption counters=[0-9]+,[0-9]+ ticks=[0-9]+" "$WORK/serial.log" &&
           grep -q "m16: user badptr rejected" "$WORK/serial.log" &&
           grep -q "m16: user badptr status=0" "$WORK/serial.log" &&
           grep -q "m16: aspace created=9 destroyed=9" "$WORK/serial.log" &&
           grep -q "M17 checks passed" "$WORK/serial.log" &&
           grep -q "M18 checks passed" "$WORK/serial.log" &&
           grep -q "m18: pci devices=" "$WORK/serial.log" &&
           grep -q "m18: pci virtio-blk bus=.* io=0x.* irq=" "$WORK/serial.log" &&
           grep -qE "m18: virtio-blk sectors=[0-9]+ queue=[0-9]+ io=0x[0-9a-f]+ ring_pages=[0-9]+" "$WORK/serial.log" &&
           grep -q "m18: sector read lba=0 signature=ok oem=ZIGKERNL" "$WORK/serial.log" &&
           grep -q "m18: sector write/read lba=.* bytes=512 ok" "$WORK/serial.log" &&
           grep -q "m18: fat type=fat16 clusters=.* root_cluster=0 cluster_bytes=512" "$WORK/serial.log" &&
           grep -q "m18: vfs fat read file=/HELLO.TXT bytes=15" "$WORK/serial.log" &&
           grep -q "m18: vfs nested read file=/SUB/NESTED.TXT bytes=20" "$WORK/serial.log" &&
           grep -q "m18: vfs cluster chain bytes=1300 ok" "$WORK/serial.log" &&
           grep -qE "m18: initramfs bytes=[0-9]+ file_bytes=21" "$WORK/serial.log" &&
           grep -q "m18: init from fat status=42 reap=reaped pid=.*" "$WORK/serial.log" &&
           grep -q "m17: proc argv=init,basic env=M18=1" "$WORK/serial.log" &&
           grep -q "m17: proc argv=m17proc,basic env=M17=1" "$WORK/serial.log" &&
           grep -qE "m17: argv status=42 pid=[0-9]+ gen=[0-9]+" "$WORK/serial.log" &&
           grep -q "m17: concurrent statuses=42,43" "$WORK/serial.log" &&
           grep -q "m17: wait timeout=timeout retry=exited/43" "$WORK/serial.log" &&
           grep -q "m17: generation advanced=1 stale=invalid" "$WORK/serial.log" &&
           grep -q "m17: nx fault status=-15 sibling=44" "$WORK/serial.log" &&
           grep -q "m17: guard fault status=-15 sibling=44" "$WORK/serial.log" &&
           grep -q "m17: bad loads rejected=4" "$WORK/serial.log" &&
           grep -qE "m17: reclaim aspaces created=[0-9]+ destroyed=[0-9]+ free_pages_match=1" "$WORK/serial.log" &&
           grep -qE "m17: process table slots=0 live=0 spawned=[0-9]+ reaped=[0-9]+" "$WORK/serial.log" &&
           grep -q "M14 checks passed" "$WORK/serial.log" &&
           grep -q "M13 checks passed" "$WORK/serial.log" &&
           grep -q "M12 checks passed" "$WORK/serial.log" &&
           grep -q "M11 checks passed" "$WORK/serial.log" &&
           grep -q "acpi: madt revision=.* cpus=.* ioapics=.* isos=" "$WORK/serial.log" &&
           grep -q "ioapic: id=.* version=.* entries=.* gsi_base=" "$WORK/serial.log" &&
           grep -q "acpi: madt cpus matched limine=" "$WORK/serial.log" &&
           grep -q "m14: irq0 gsi=.* polarity=.* trigger=.* overridden=" "$WORK/serial.log" &&
           grep -q "m14: ioapic ticks=" "$WORK/serial.log" &&
           grep -q "m14: cpu0 sleep ticks=" "$WORK/serial.log" &&
           grep -q "m14: cpu0 preempted=1" "$WORK/serial.log" &&
           grep -q "timer: source=lapic" "$WORK/serial.log" &&
           grep -q "timer: per-cpu ticks=.*sleepers=.*preempted=1" "$WORK/serial.log" &&
           grep -q "heap: concurrent allocs=.*errors=0" "$WORK/serial.log" &&
           grep -q "tlb: irq-off=1" "$WORK/serial.log" &&
           grep -q "concurrent shootdowns=" "$WORK/serial.log" &&
           grep -q "M9 checks passed" "$WORK/serial.log" &&
           grep -q "M8 checks passed" "$WORK/serial.log" &&
           grep -q "M7 checks passed" "$WORK/serial.log" &&
           grep -q "M6 checks passed" "$WORK/serial.log" &&
           grep -q "M5 checks passed" "$WORK/serial.log" &&
           grep -q "M4 checks passed" "$WORK/serial.log" &&
           grep -q "M3 checks passed" "$WORK/serial.log" &&
           grep -q "M2 checks passed" "$WORK/serial.log" &&
           grep -q "M1c checks passed" "$WORK/serial.log" &&
           grep -q "PMM checks passed" "$WORK/serial.log" &&
           grep -q "VMM checks passed" "$WORK/serial.log" &&
           grep -q "heap checks passed" "$WORK/serial.log" &&
           grep -q "timer checks passed" "$WORK/serial.log" &&
           grep -q "scheduler checks passed" "$WORK/serial.log" &&
           grep -q "lifecycle checks passed" "$WORK/serial.log" &&
           grep -q "sleep checks passed" "$WORK/serial.log" &&
           grep -q "block checks passed" "$WORK/serial.log" &&
           grep -q "waitq checks passed" "$WORK/serial.log" &&
           grep -q "timed checks passed" "$WORK/serial.log" &&
           grep -q "mutex checks passed" "$WORK/serial.log" &&
           grep -q "cond checks passed" "$WORK/serial.log" &&
           grep -q "fpu checks passed" "$WORK/serial.log" &&
           grep -q "smp: cpus=$SMP" "$WORK/serial.log" &&
           grep -q "cross-cpu wake=1" "$WORK/serial.log" &&
           grep -q "ap exception=1" "$WORK/serial.log" &&
           grep -q "nested locks=1" "$WORK/serial.log" &&
           grep -q "smp checks passed" "$WORK/serial.log"; then
          exit 0
        fi
        echo "run.sh: selftest exited successfully but the expected log is missing" >&2
        exit 1
        ;;
      35) echo "run.sh: kernel panic" >&2; exit 1 ;;
      124) echo "run.sh: timed out waiting for kernel" >&2; exit 1 ;;
      *) echo "run.sh: unexpected QEMU exit status $status" >&2; exit 1 ;;
    esac
  fi

  if [ "$MODE" = "boot" ]; then
    # The normal kernel idles after boot, so the timeout is expected. Assert
    # that boot reached the forced PIT fallback and handed control to idle.
    if grep -q "timer: source=pit" "$WORK/serial.log" &&
       grep -q "scheduler: boot task exiting to idle" "$WORK/serial.log"; then
      exit 0
    fi
    echo "run.sh: fallback boot did not reach the PIT timer path" >&2
    exit 1
  fi

  # Fault test: the kernel must catch #PF, report CR2 and exit through
  # isa-debug-exit with the failure code (35).
  case $status in
    35)
      if grep -q "vector 14: #PF" "$WORK/serial.log" &&
         grep -q "cr2=0x0" "$WORK/serial.log"; then
        exit 0
      fi
      echo "run.sh: fault test exited with 35 but the expected #PF log is missing" >&2
      exit 1
      ;;
    124) echo "run.sh: timed out waiting for kernel" >&2; exit 1 ;;
    *) echo "run.sh: unexpected QEMU exit status $status for fault test" >&2; exit 1 ;;
  esac
fi

exec "${QEMU[@]}" -serial stdio
