# zig-kernel

A from-scratch x86_64 kernel written in Zig, booted by [Limine](https://github.com/limine-bootloader/limine) under UEFI. Built for QEMU-first development with a single-command test flow.

## Status
- **M0 complete:** higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM and memory map reporting, SSE bring-up.
- **M1a complete:** own 64 KiB kernel stack, GDT/TSS (`RSP0` + 8 KiB #DF IST stack), 256-entry IDT, exception dispatcher for vectors 0-31, PIC remap/mask.
- **M1b complete:** bitmap physical page allocator built from the Limine memory map (4 GiB managed cap, zero page reserved, double-free protection).
- **M1c complete:** own 4-level page tables, higher-half kernel mapping, 4 GiB HHDM direct map, and a 64 MiB lazily-mapped kernel heap with `std.mem.Allocator` support.
- **M2 complete:** IRQ gates/stubs, 100 Hz PIT on IRQ0, full 15-GPR interrupt context save/restore, and a preemptive round-robin kernel task scheduler with per-task stacks.
- **Next:** M3 - expand the scheduler and task lifecycle.

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
- the selftest checks PMM allocation/free/reuse, page-table translation and
  map/unmap, heap allocation/alignment/coalescing, waits for 30 PIT ticks while
  two round-robin tasks run, triggers `int3` and must return from the handler
  (QEMU status 33);
- the fault test dereferences NULL and must report `#PF` with `CR2` before
  exiting through the failure path (QEMU status 35).

## Layout
```
boot/limine.conf   Limine menu/config
linker.ld          Higher-half layout, page-aligned PT_LOAD segments
src/
  arch/x86_64/     ports, serial, qemu exit, SSE, GDT/TSS, IDT, PIC, PIT
  arch/x86_64/interrupts.S  Exception/IRQ stubs and full GPR save/restore
  console.zig      framebuffer text console + serial mirroring
  font.zig         8x16 bitmap font
  limine.zig       Limine protocol bindings
  main.zig         _start, kmain, panic, boot sequence, M2 smoke test
  memory/pmm.zig   bitmap physical page allocator from the Limine memory map
  memory/vmm.zig   4-level page tables, kernel/HHDM mappings, CR3 switch
  memory/heap.zig  lazily mapped first-fit kernel heap + std.mem.Allocator
  sched.zig        preemptive round-robin task scheduler
tools/run.sh       Build ESP (vvfat) and launch QEMU
tools/genfont.py   Regenerate src/font.zig from a system font
third_party/limine/ Vendored Limine UEFI binary (BOOTX64.EFI)
```

## Notes
- KVM works with `-cpu host`; on some nested-KVM hosts we disable `ldmxcsr` (MXCSR stays at its reset value) to avoid an emulation issue while keeping SSE usable.
- Debug builds use the LLVM backend (`exe.use_llvm = true`) because the self-hosted x86_64 backend ignores custom linker scripts in Zig 0.17.
- `_start` switches from the Limine stack to a fixed 64 KiB kernel stack before calling `kmain`; double faults run on a separate 8 KiB IST stack.
- The PMM only frees `usable` memory-map ranges, never hands out the zero page, and uses a separate allocation bitmap so reserved pages (kernel image, firmware, framebuffer, MMIO) cannot be freed by mistake. Physical memory above 4 GiB is not managed yet.
- M1c forces 4-level paging, builds a fresh PML4, maps the kernel image at its Limine physical base, and maps the first 4 GiB of physical memory at the HHDM offset with 2 MiB pages. Kernel text/rodata are read-only and `CR0.WP` is enabled; the framebuffer's HHDM range is marked uncached.
- The heap reserves `0xffffffff90000000..0xffffffff94000000` and grows in 64 KiB batches from the PMM. It is a first-fit free-list allocator with block headers, coalescing, arbitrary power-of-two alignment, and a `std.mem.Allocator` adapter; `resize`/`remap` are not implemented yet.
- M2 programs the PIT channel 0 to 100 Hz on IRQ0 and unmasks only that PIC line. Every interrupt saves all 15 general-purpose registers into a common frame; the IRQ0 dispatcher sends EOI and calls the round-robin scheduler, which returns the saved-register base of the next task. `tasks[0]` is the boot context, and the selftest creates two workers with static 16 KiB stacks.
- Context switching does not save floating-point/SIMD state yet. M2 tasks must not rely on live XMM registers across a preemption; FPU context switching and richer task lifecycle management are planned for a later milestone.
