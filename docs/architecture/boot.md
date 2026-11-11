# Boot and early bring-up

**Purpose:** trace the path from the Limine/UEFI handoff through `_start` and
`kmain` to the point where the kernel either enters normal operation or runs a
test variant.

**Implementation status:** **IMPLEMENTED** for the UEFI/Limine path described
here. There is no BIOS boot path in the current build.

## Boot chain

1. QEMU starts OVMF, which loads `BOOTX64.EFI` from the synthesized FAT ESP.
2. Limine reads [`boot/limine.conf`](../../boot/limine.conf) and boots the
   `zig-kernel` entry with `protocol: limine`.
3. Limine loads the higher-half ELF described by [`linker.ld`](../../linker.ld),
   enables the requested 4-level paging mode, and jumps to `_start` with its own
   stack and interrupts disabled.
4. `_start` switches to the kernel-owned stack and calls `kmain`.

The boot menu sets `timeout: 0`, enables serial output at 115200 baud, and
disables verbose boot messages. The kernel path in the menu is
`boot():/zig-kernel`; [`tools/run.sh`](../../tools/run.sh) copies the requested
kernel image to that name inside the ESP.

## Limine requests

The protocol bindings live in [`src/limine.zig`](../../src/limine.zig). The
kernel requests:

| Request | Purpose |
| --- | --- |
| Base revision | Declares base revision 3 and detects an unsupported bootloader revision. |
| Framebuffer | Supplies the framebuffer used by the text console. |
| HHDM | Supplies the higher-half direct-map offset. |
| Memory map | Supplies the physical ranges used to initialize the PMM. |
| Executable address | Supplies the kernel's physical and virtual base addresses. |
| Paging mode | Forces 4-level paging; the VMM also rejects a set `CR4.LA57`. |
| MP | Asks Limine to bootstrap and park secondary CPUs until the kernel publishes `goto_address`. |

The request structures are placed in `.limine_requests` by the linker script.
That section is kept writable because Limine stores response pointers there.
The base-revision marker is valid only when `base_revision[2]` is zero;
`limine.baseRevisionSupported()` checks this.

## Linker layout

[`linker.ld`](../../linker.ld) places the image at `0xffffffff80000000` and
defines four page-aligned `PT_LOAD` segments:

| Segment | Permissions | Contents |
| --- | --- | --- |
| `limine` | read + write | `.limine_requests_start`, `.limine_requests`, `.limine_requests_end` |
| `text` | read + execute | `.text` and `.text.*` |
| `rodata` | read | `.rodata`, `.rodata.*`, `.rodata.cst*` |
| `data` | read + write | `.data`, `.data.rel.ro*`, `.bss`, `COMMON` |

Every segment starts on its own page because Limine rejects images where
segments with different permissions share a page. `__kernel_start`,
`__kernel_requests_end`, `__kernel_text_start`, `__kernel_text_end`,
`__kernel_rodata_start`, `__kernel_rodata_end`, `__kernel_data_start`, and
`__kernel_end` are consumed by the VMM.

## `_start`

`_start` is exported from [`src/main.zig`](../../src/main.zig) as a naked
function. It:

1. loads the top of `kernel_stack` into `RSP` (`kernel_stack` is a 64 KiB
   aligned array exported by [`gdt.zig`](../../src/arch/x86_64/gdt.zig));
2. clears `RBP`;
3. calls `kmain`;
4. executes `ud2` if `kmain` ever returns.

This avoids running Zig code on Limine's reclaimable boot stack.

## `kmain` sequence

`kmain` executes the following steps in order. Failures during PMM or VMM
initialization print an error and exit QEMU with the failure code.

1. `cli; cld`.
2. `cpu.enableSse()` so compiler-generated SSE code is legal before any
   non-trivial Zig code runs.
3. Initialize COM1 and print `zig-kernel: early boot`.
4. `gdt.init()`: build the GDT, per-CPU TSS descriptors, and #DF IST stacks;
   load CPU 0's GDT/TSS.
5. `idt.init()`: install exception, IRQ, scheduler, and IPI gates; load the IDT.
6. `pic.remap(0x20, 0x28)`: remap the 8259 PIC to vectors 32-47 and mask all
   lines.
7. `cpu.initPerCpu(0, 0)`: install the boot per-CPU block so `%gs:0` always
   points at a scratch FXSAVE area, even before the scheduler exists.
8. Check `limine.baseRevisionSupported()`.
9. `pmm.init()`: build the physical page bitmaps from the Limine memory map.
10. `vmm.init()`: build the kernel PML4, map the kernel and the 4 GiB HHDM,
    mark the framebuffer uncached, enable `CR0.WP`, and switch `CR3`.
11. `heap.init()`: reset the heap free list and break to the reserved base.
12. `console.init()`, `banner()`, and `reportBootInfo()`.
13. `smp.init()`: record Limine's MP response and per-AP contexts. An
    initialization failure is logged but does not abort boot.
14. `lapic.init()`, read the BSP LAPIC ID, reinstall the per-CPU block with that
    ID, call `sched.init()`, and register `vmm.setTlbShootdownHandler`.
15. If an MP response exists, print CPU statistics (`cpus`, `aps`,
    `bsp_lapic_id`, `x2apic`). On a normal boot with APs, release them with
    `smp.start()` and wait with `waitOnline()`. Each AP installs its per-CPU
    state and enters its scheduler idle loop.
16. Branch into the test variant or normal operation. The normal path prints
    the version summary immediately before initializing the PIT and entering
    the scheduler; no milestone-specific line is printed unconditionally.

## Boot variants

The build creates three images from the same source using `build_options` in
[`build.zig`](../../build.zig).

| Variant | Options | Behavior |
| --- | --- | --- |
| Normal kernel | `exit_after_boot = false`, `test_page_fault = false` | Reports boot information, starts the APs into their scheduler idle loops, initializes the PIT, unmasks IRQ0, and exits the boot task into the BSP idle task. |
| Selftest kernel | `exit_after_boot = true`, `test_page_fault = false` | Skips the early AP release, runs the M1c-M12 self-tests, then `selftestSmp()` starts the APs and runs the M11 and M12 SMP, allocator, and TLB checks, triggers `int3`, and exits QEMU with success. |
| Fault-test kernel | `exit_after_boot = false`, `test_page_fault = true` | Starts the APs into their scheduler idle loops, then deliberately dereferences NULL to exercise the #PF path and the failure exit. |

Normal operation after the report is:

```text
console.print("\nboot: " ++ version ++ " initialized (memory, scheduler, SMP)\n")
sched.init()
pit.init(100)
pic.unmask(0)
console.print("timer: PIT 100 Hz, IRQ0 unmasked\n")
console.write("scheduler: boot task exiting to idle (interrupts enabled there)\n")
sched.exit()
```

Unmasking IRQ0 does not enable interrupts by itself. The boot task exits into
the BSP idle task, whose `idleEntry` executes `sti; hlt`; the log wording
reflects that exact transition.

In the selftest variant, the normal scheduler/PIT setup is skipped. The tests
call `sched.init()`, program the PIT, and manage `sti`/`cli` themselves. The
fault-test variant starts APs through the normal path and then faults.

## Console

[`src/console.zig`](../../src/console.zig) provides a text console that mirrors
all output to COM1. It requires a 32-bpp framebuffer with a non-null address,
non-zero dimensions, and a non-zero pitch. It keeps a text grid of up to 256
columns and 128 rows, scrolls by redrawing, and renders an 8x16 bitmap font from
[`src/font.zig`](../../src/font.zig). Colors are packed from the framebuffer's
red/green/blue mask sizes and shifts.

Serial output is initialized separately by [`serial.zig`](../../src/arch/x86_64/serial.zig)
at 115200 baud, 8-N-1, with FIFO enabled and interrupts disabled. Serial writes
time out after roughly one million polls instead of hanging on a dead UART.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Limine/UEFI boot | **IMPLEMENTED** | UEFI only; vendored `BOOTX64.EFI`. |
| Higher-half linker layout | **IMPLEMENTED** | Four page-aligned `PT_LOAD` segments. |
| Own kernel stack | **IMPLEMENTED** | 64 KiB `kernel_stack`; 8 KiB per-CPU #DF IST. |
| Limine base-revision check | **IMPLEMENTED** | Rejects unsupported revisions. |
| Framebuffer + serial console | **IMPLEMENTED** | Requires 32-bpp framebuffer; serial always available. |
| Normal/selftest/fault variants | **IMPLEMENTED** | Selected at build time. |
| BIOS boot path | **PLANNED** | Not present in the current build. |

## Related documentation

- [Overview](overview.md)
- [Memory management](memory.md)
- [CPU and interrupts](cpu-interrupts.md)
- [SMP bring-up](smp.md)
- [Building](../development/building.md)
- [Testing](../development/testing.md)
- [Technical debt](../development/technical-debt.md)
