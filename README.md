# zig-kernel

A from-scratch x86_64 kernel written in Zig, booted by [Limine](https://github.com/limine-bootloader/limine) under UEFI. Built for QEMU-first development with a single-command test flow.

## Goals (M0)
- Higher-half kernel at `0xffffffff80000000`
- Limine boot protocol with framebuffer, HHDM, and memory map requests
- Early boot via COM1 and a simple 8x16 bitmap framebuffer console
- SSE/SSE2 enabled for compiler-generated vector operations
- `zig build test` runs host unit tests and a QEMU smoke test (`isa-debug-exit`)

## Requirements
- Zig 0.17.0 (pinned in `.zig-version`)
- QEMU (`qemu-system-x86_64`), OVMF (`/usr/share/edk2/x64/OVMF_CODE.4m.fd`)
- Linux host (x86_64). No root/sudo required for development.

## Quick start
```bash
export PATH=~/.local/opt/toolchain/zig-x86_64-linux-0.17.0:$PATH
zig build        # build kernel (default: ReleaseSafe)
zig build run    # boot in QEMU (serial on stdio)
zig build test   # host tests + QEMU smoke test
```

Build options:
- `-Doptimize={debug,safe,fast,small}` (default: `safe`/`ReleaseSafe`)

`zig build test` builds a separate selftest kernel that exits QEMU via the
`isa-debug-exit` device once M0 init succeeds (QEMU status 33 = pass).

## Layout
```
boot/limine.conf   Limine menu/config
linker.ld          Higher-half layout, page-aligned PT_LOAD segments
src/
  arch/x86_64/     ports, serial, qemu exit, SSE bring-up
  console.zig      framebuffer text console + serial mirroring
  font.zig         8x16 bitmap font
  limine.zig       Limine protocol bindings
  main.zig         kmain, panic, boot sequence
tools/run.sh       Build ESP (vvfat) and launch QEMU
tools/genfont.py   Regenerate src/font.zig from a system font
third_party/limine/ Vendored Limine UEFI binary (BOOTX64.EFI)
```

## Notes
- KVM works with `-cpu host`; on some nested-KVM hosts we disable `ldmxcsr` (MXCSR stays at its reset value) to avoid an emulation issue while keeping SSE usable.
- Debug builds use the LLVM backend (`exe.use_llvm = true`) because the self-hosted x86_64 backend ignores custom linker scripts in Zig 0.17.
- The kernel must not rely on the bootloader stack for large allocations; a fixed kernel stack may be added later if needed.
