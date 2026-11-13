# Architecture overview

**Purpose:** describe what zig-kernel is, the constraints it is built under,
which milestones are implemented, and how the source tree is organized.

**Implementation status:** M0-M13 are implemented and validated through the
QEMU test flow. M14 is planned. See the per-subsystem documents for the exact
status of individual features.

## Project facts

| Item | Value | Source |
| --- | --- | --- |
| Language | Zig 0.17.0, pinned in `.zig-version` | [`.zig-version`](../../.zig-version) |
| Target | `x86_64-freestanding-none` | [`build.zig`](../../build.zig) |
| Boot path | Limine 12.9.4, UEFI, Limine boot protocol base revision 3 | [`src/limine.zig`](../../src/limine.zig) |
| Kernel base | `0xffffffff80000000` (higher half) | [`linker.ld`](../../linker.ld) |
| Default build | `ReleaseSafe` with LLVM (`exe.use_llvm = true`) | [`build.zig`](../../build.zig) |
| Current version string | `0.16.0-m13` | [`src/main.zig`](../../src/main.zig) |
| Primary test platform | QEMU with KVM when available, TCG as fallback | [`tools/run.sh`](../../tools/run.sh) |

## Design constraints

- The kernel is written from scratch. Only a small amount of `std` is used
  (`std.mem`, `std.fmt`, `std.mem.Allocator` adapters, and similar helpers);
  memory management, scheduling, synchronization, and architecture support are
  project-owned.
- The kernel is freestanding and higher-half. Limine loads it through UEFI;
  there is no BIOS path in the current build.
- Development must not require root, `sudo`, `mtools`, `xorriso`, or
  `losetup`. The QEMU harness exposes a directory as a synthesized FAT drive
  through QEMU's `vvfat` support.
- Every milestone must be verifiable with an automated QEMU smoke test, in
  addition to host-side tests where applicable.
- Default builds keep safety checks enabled (`ReleaseSafe`).
- The scheduler is per-CPU: every online CPU has its own current task, idle
  task, run state, and tick counter. Tasks are pinned to the CPU chosen at
  creation. CPU 0 uses the PIT on IRQ0; each AP uses a periodic LAPIC timer.

## Milestone status

| Milestone | Scope | Status |
| --- | --- | --- |
| M0 | Higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM and memory-map reporting, SSE bring-up | **IMPLEMENTED** |
| M1a | Own 64 KiB kernel stack, GDT/TSS (`RSP0` + per-CPU 8 KiB #DF IST stack), 256-entry IDT, exception dispatcher for vectors 0-31, PIC remap/mask | **IMPLEMENTED** |
| M1b | Bitmap physical page allocator from the Limine memory map, 4 GiB managed cap, reserved zero page, double-free protection | **IMPLEMENTED** |
| M1c | Own 4-level page tables, higher-half kernel mapping, 4 GiB HHDM direct map, 64 MiB lazily mapped kernel heap with `std.mem.Allocator` support | **IMPLEMENTED** |
| M2 | IRQ gates/stubs, 100 Hz PIT on IRQ0, full 15-GPR interrupt context, preemptive round-robin scheduler with per-task stacks | **IMPLEMENTED** |
| M3 | Cooperative `yield`/`exit` software interrupts, idle task, reuse of finished task slots | **IMPLEMENTED** |
| M4 | Timer-based blocking sleep, deadline wakeups in the timer tick, interrupt-safe lock | **IMPLEMENTED** |
| M5 | Indefinite blocking (`sched.block`) and explicit wakeup (`sched.wake`) with a blocked-task counter | **IMPLEMENTED** |
| M6 | `sched.WaitQueue` with `wait`, `wakeOne`, `wakeAll`, and stale-waiter pruning | **IMPLEMENTED** |
| M7 | Timed wait queues (`WaitQueue.waitTimeout`) distinguishing signal from timeout | **IMPLEMENTED** |
| M8 | Blocking `sched.Mutex` with ownership transfer and `sched.Condition` with `wait`, `signal`, `broadcast` | **IMPLEMENTED** |
| M9 | FPU/SIMD context switching with per-task `FXSAVE`/`FXRSTOR` areas | **IMPLEMENTED** |
| M10 | Limine MP bring-up, per-CPU stacks/TSS, atomic spinlocks, SMP stress test | **IMPLEMENTED** |
| M11 | Per-CPU scheduling, LAPIC/x2APIC IPIs, SMP-aware wait queues/mutex/condition, TLB shootdown, AP exception/FPU state | **IMPLEMENTED** |
| M12 | IRQ-safe heap locking, concurrent allocator stress, lock-free TLB-shootdown mailboxes, IRQ-off and concurrent shootdown tests | **IMPLEMENTED** |
| M13 | Per-CPU tick counters, AP LAPIC timers calibrated against the PIT, local deadline wakeups, timer-driven AP preemption | **IMPLEMENTED** |
| M14 | Next milestone; not yet scoped or started | **PLANNED** |

Detailed milestone behavior is documented in the subsystem pages:
[memory](memory.md), [CPU and interrupts](cpu-interrupts.md),
[scheduling](scheduling.md), [synchronization](synchronization.md), and
[SMP](smp.md).

## How the pieces fit together

```text
Limine (UEFI)
    |
    v
_start -> kernel stack -> kmain
    |
    +-- SSE enable, serial, GDT/TSS, IDT, PIC remap, per-CPU block
    +-- PMM -> VMM -> heap
    +-- framebuffer console + boot report
    +-- SMP init (Limine MP request)
    +-- LAPIC/x2APIC init, scheduler init, timer calibration, TLB-shootdown hook
    +-- normal boot: start APs -> per-CPU scheduler idle
    +-- selftest / fault-test variant
    |
    v
normal boot: PIT 100 Hz -> IRQ0 on BSP; AP LAPIC timers -> per-CPU ticks
```

Every CPU runs its own scheduler state and tick counter. IRQ0 drives preemption
on the BSP; APs enter their idle tasks and are preempted by their LAPIC timers,
which also wake local timed sleepers. APs additionally receive reschedule (240)
and TLB-shootdown (241) IPIs. Blocking primitives wake tasks across CPUs. Heap,
PMM, VMM, console, and serial state use IRQ-safe locks; `unmapPage` issues a
lock-free shootdown after releasing the page-table lock.

## Source layout

| Path | Purpose |
| --- | --- |
| [`boot/limine.conf`](../../boot/limine.conf) | Limine menu and kernel path. |
| [`linker.ld`](../../linker.ld) | Higher-half layout and page-aligned `PT_LOAD` segments. |
| [`src/main.zig`](../../src/main.zig) | `_start`, `kmain`, panic, boot sequence, and M1c-M13 self-tests. |
| [`src/limine.zig`](../../src/limine.zig) | Limine protocol structures and requests. |
| [`src/console.zig`](../../src/console.zig) | Framebuffer text console with serial mirroring. |
| [`src/font.zig`](../../src/font.zig) | 8x16 bitmap font. |
| [`src/sched.zig`](../../src/sched.zig) | Per-CPU scheduler, wait queues, mutex/condition, FPU state, idle tasks, IPIs, TLB shootdown. |
| [`src/sync.zig`](../../src/sync.zig) | Spinlocks and interrupt save/restore helpers. |
| [`src/smp.zig`](../../src/smp.zig) | Limine MP bring-up, AP contexts, AP scheduler entry, SMP tests. |
| [`src/memory/pmm.zig`](../../src/memory/pmm.zig) | Bitmap physical page allocator. |
| [`src/memory/vmm.zig`](../../src/memory/vmm.zig) | 4-level page tables, kernel/HHDM mappings, CR3 switch. |
| [`src/memory/heap.zig`](../../src/memory/heap.zig) | IRQ-safe, lazily mapped first-fit kernel heap and `std.mem.Allocator` adapter. |
| [`src/arch/x86_64/cpu.zig`](../../src/arch/x86_64/cpu.zig) | SSE/FPU enablement and GS-based per-CPU state. |
| [`src/arch/x86_64/lapic.zig`](../../src/arch/x86_64/lapic.zig) | xAPIC/x2APIC detection, initialization, EOI, IPIs, and the periodic LAPIC timer. |
| [`src/arch/x86_64/gdt.zig`](../../src/arch/x86_64/gdt.zig) | GDT, per-CPU TSS, #DF IST stacks. |
| [`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig) | IDT, exception dispatch, IRQ dispatch. |
| [`src/arch/x86_64/interrupts.S`](../../src/arch/x86_64/interrupts.S) | Exception/IRQ/scheduler stubs and FPU save/restore. |
| [`src/arch/x86_64/smp_entry.S`](../../src/arch/x86_64/smp_entry.S) | AP entry: private stack, kernel CR3, `ap_main`. |
| [`src/arch/x86_64/pic.zig`](../../src/arch/x86_64/pic.zig) | 8259 PIC remap, mask, EOI. |
| [`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig) | 8253/8254 PIT channel 0. |
| [`src/arch/x86_64/port.zig`](../../src/arch/x86_64/port.zig) | Port I/O helpers. |
| [`src/arch/x86_64/serial.zig`](../../src/arch/x86_64/serial.zig) | COM1 serial driver. |
| [`src/arch/x86_64/qemu.zig`](../../src/arch/x86_64/qemu.zig) | `isa-debug-exit` helper. |
| [`src/test_root.zig`](../../src/test_root.zig) | Host-side unit-test root. |
| [`tools/run.sh`](../../tools/run.sh) | Build the ESP directory and launch QEMU. |
| [`tools/genfont.py`](../../tools/genfont.py) | Regenerate `src/font.zig` from a system font. |
| [`third_party/limine/`](../../third_party/limine) | Vendored Limine UEFI binary and notices. |

## Related documentation

- [Documentation index](../README.md)
- [Boot and early bring-up](boot.md)
- [Memory management](memory.md)
- [CPU and interrupts](cpu-interrupts.md)
- [Scheduling](scheduling.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
