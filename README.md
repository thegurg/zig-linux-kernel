# zig-kernel

A from-scratch x86_64 kernel written in Zig, booted by [Limine](https://github.com/limine-bootloader/limine) under UEFI. Built for QEMU-first development with a single-command test flow.

## Status
- **M0 complete:** higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM and memory map reporting, SSE bring-up.
- **M1a complete:** own 64 KiB kernel stack, GDT/TSS (`RSP0` + 8 KiB #DF IST stack), 256-entry IDT, exception dispatcher for vectors 0-31, PIC remap/mask.
- **M1b complete:** bitmap physical page allocator built from the Limine memory map (4 GiB managed cap, zero page reserved, double-free protection).
- **Next:** M1c - own page tables and a kernel heap on top of the PMM.

## Requirements
- Zig 0.17.0 (pinned in `.zig-version`)
- QEMU (`qemu-system-x86_64`), OVMF (`/usr/share/edk2/x64/OVMF_CODE.4m.fd`)
- Linux host (x86_64). No root/sudo required for development.

## Quick start
```bash
export PATH=~/.local/opt/toolchain/zig-x86_64-linux-0.17.0:$PATH
zig build        # build kernel (default: ReleaseSafe)
zig build run    # boot in QEMU (serial on stdio)
zig build test   # host tests + QEMU smoke and fault tests
```

Build options:
- `-Doptimize={debug,safe,fast,small}` (default: `safe`/`ReleaseSafe`)

`zig build test` builds two headless images and checks both with
`isa-debug-exit`:
- the selftest checks PMM allocation/free/reuse, triggers `int3` and must return
  from the handler (QEMU status 33);
- the fault test dereferences NULL and must report `#PF` with `CR2` before
  exiting through the failure path (QEMU status 35).

## Layout
```
boot/limine.conf   Limine menu/config
linker.ld          Higher-half layout, page-aligned PT_LOAD segments
src/
  arch/x86_64/     ports, serial, qemu exit, SSE, GDT/TSS, IDT, PIC
  arch/x86_64/interrupts.S  Exception stubs and common register save/restore
  console.zig      framebuffer text console + serial mirroring
  font.zig         8x16 bitmap font
  limine.zig       Limine protocol bindings
  main.zig         _start, kmain, panic, boot sequence
  memory/pmm.zig   bitmap physical page allocator from the Limine memory map
tools/run.sh       Build ESP (vvfat) and launch QEMU
tools/genfont.py   Regenerate src/font.zig from a system font
third_party/limine/ Vendored Limine UEFI binary (BOOTX64.EFI)
```

## Notes
- KVM works with `-cpu host`; on some nested-KVM hosts we disable `ldmxcsr` (MXCSR stays at its reset value) to avoid an emulation issue while keeping SSE usable.
- Debug builds use the LLVM backend (`exe.use_llvm = true`) because the self-hosted x86_64 backend ignores custom linker scripts in Zig 0.17.
- `_start` switches from the Limine stack to a fixed 64 KiB kernel stack before calling `kmain`; double faults run on a separate 8 KiB IST stack.
- The PMM only frees `usable` memory-map ranges, never hands out the zero page, and uses a separate allocation bitmap so reserved pages (kernel image, firmware, framebuffer, MMIO) cannot be freed by mistake. Physical memory above 4 GiB is not managed yet.
