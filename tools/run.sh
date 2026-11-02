#!/usr/bin/env bash
# Boot the kernel in QEMU through Limine (UEFI).
#
# Usage:
#   tools/run.sh <kernel.elf>           interactive, serial on stdio
#   tools/run.sh <kernel.elf> --test    headless smoke test, exit code = verdict
#
# The ESP is exposed to QEMU as a synthesized FAT (vvfat) drive backed by a
# directory, so no root, loop devices, mtools or ISO tooling are required.

set -euo pipefail

KERNEL="${1:?usage: run.sh <kernel.elf> [--test]}"
TEST=0
[ "${2:-}" = "--test" ] && TEST=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIMINE_BIN="${LIMINE_BIN:-$ROOT/third_party/limine}"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

missing=0
for f in "$KERNEL" "$LIMINE_BIN/BOOTX64.EFI" "$OVMF_CODE" "$OVMF_VARS_SRC"; do
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
cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
chmod u+w "$WORK/OVMF_VARS.fd"

ACCEL=(-accel tcg -cpu max)
if [ -r /dev/kvm ] && [ -w /dev/kvm ] && [ "${ZIG_KERNEL_NO_KVM:-0}" != "1" ]; then
  ACCEL=(-accel kvm -cpu host)
fi

QEMU=(
  qemu-system-x86_64
  -machine q35
  "${ACCEL[@]}"
  -m 256M
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$WORK/OVMF_VARS.fd"
  -drive "format=raw,file=fat:rw:$ESP,if=none,id=esp"
  -device virtio-blk-pci,drive=esp
  -boot order=c
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
  -no-reboot
  -display none
  -net none
)

if [ $TEST -eq 1 ]; then
  set +e
  timeout 90 "${QEMU[@]}" -serial "file:$WORK/serial.log"
  status=$?
  set -e
  if [ -f "$WORK/serial.log" ]; then
    sed -e 's/\r$//' "$WORK/serial.log"
  fi
  # isa-debug-exit reports (value << 1) | 1: 0x10 -> 33, 0x11 -> 35.
  case $status in
    33) exit 0 ;;
    35) echo "run.sh: kernel panic" >&2; exit 1 ;;
    124) echo "run.sh: timed out waiting for kernel" >&2; exit 1 ;;
    *) echo "run.sh: unexpected QEMU exit status $status" >&2; exit 1 ;;
  esac
fi

exec "${QEMU[@]}" -serial stdio
