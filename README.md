# zig-kernel

A from-scratch x86_64 kernel written in Zig, booted by [Limine](https://github.com/limine-bootloader/limine) under UEFI. Built for QEMU-first development with a single-command test flow.

## Status
- **M0 complete:** higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM and memory map reporting, SSE bring-up.
- **M1a complete:** own 64 KiB kernel stack, GDT/TSS (`RSP0` + 8 KiB #DF IST stack), 256-entry IDT, exception dispatcher for vectors 0-31, PIC remap/mask.
- **M1b complete:** bitmap physical page allocator built from the Limine memory map (4 GiB managed cap, zero page reserved, double-free protection).
- **M1c complete:** own 4-level page tables, higher-half kernel mapping, 4 GiB HHDM direct map, and a 64 MiB lazily-mapped kernel heap with `std.mem.Allocator` support.
- **M2 complete:** IRQ gates/stubs, 100 Hz PIT on IRQ0, full 15-GPR interrupt context save/restore, and a preemptive round-robin kernel task scheduler with per-task stacks.
- **M3 complete:** cooperative `yield`/`exit` software interrupts, an idle task that runs when no other task is ready, and reuse of finished task slots.
- **M4 complete:** timer-based blocking sleep (`sched.sleep`), deadline wakeups in the timer tick, and interrupt-safe lock guards (`sync.IrqLock`, `sync.IrqSpinLock`).
- **M5 complete:** explicit indefinite blocking (`sched.block`) and wakeup (`sched.wake`) with a blocked-task counter.
- **M6 complete:** `sched.WaitQueue` with `wait`, `wakeOne` and `wakeAll`, plus pruning of stale waiter entries.
- **M7 complete:** timed wait queues (`WaitQueue.waitTimeout`) that distinguish an explicit signal from a deadline timeout.
- **M8 complete:** blocking `sched.Mutex` with ownership transfer, plus `sched.Condition` with `wait`, `signal` and `broadcast`.
- **M9 complete:** FPU/SIMD context switching with per-task `FXSAVE`/`FXRSTOR` areas.
- **M10 complete:** Limine MP bring-up with per-CPU stacks/TSS, atomic spinlocks, and an SMP stress test.
- **Pre-M11 bugfix pass complete:** per-acquisition interrupt guards, AP SSE/`CR0.WP`/global-TLB setup ordering, accurate diagnostics, a task return trampoline, and a dynamic SMP test assertion.
- **M11 complete:** per-CPU scheduling with pinned tasks and per-CPU idle tasks, LAPIC/x2APIC IPIs, SMP-aware wait queues/mutex/condition variables, TLB shootdown, GS-based per-CPU FPU state on APs, and expanded QEMU tests.
- **M12 complete:** IRQ-safe heap locking with a concurrent allocator stress test, lock-free per-CPU TLB-shootdown mailboxes, and tests for interrupts-disabled targets and concurrent shootdowns.
- **Next:** M13 (not started). See the [roadmap](docs/development/roadmap.md).

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
  two round-robin tasks yield and exit, creates a third task to verify
  finished-slot reuse, creates a sleeping task and checks that it wakes after
  its deadline, blocks a worker until the boot task wakes it explicitly, puts
  another worker on a wait queue and wakes it with `wakeOne`, verifies both the
  timeout and signaled paths of `WaitQueue.waitTimeout`, checks mutex exclusion
  across a yield and a condition-variable wait/signal handshake, checks that two
  tasks keep distinct `xmm0` patterns across a cooperative yield, then runs the
  M11 SMP checks: per-AP pinned tasks and a shared spinlock-protected counter
  that must reach `100000 * CPUs` with zero overlap, a cross-CPU wakeup via
  reschedule IPI, an AP `int3` with XMM5 preservation, a TLB shootdown after
  `unmapPage`, and nested `IrqSpinLock` guards; the M12 checks then allocate,
  write, verify, and free blocks on every CPU concurrently, shoot down to a CPU
  with interrupts disabled, and run concurrent per-AP map/unmap shootdowns; it
  then triggers `int3` and must return from the handler (QEMU status 33);
- the fault test dereferences NULL and must report `#PF` with `CR2` before
  exiting through the failure path (QEMU status 35).

## Layout
```
boot/limine.conf   Limine menu/config
linker.ld          Higher-half layout, page-aligned PT_LOAD segments
src/
  arch/x86_64/     ports, serial, qemu exit, SSE, per-CPU state, GDT/TSS, IDT, PIC, PIT, LAPIC
  arch/x86_64/cpu.zig       per-CPU GS-based state and SSE/FPU enablement
  arch/x86_64/lapic.zig     xAPIC/x2APIC detection, EOI, and IPIs
  arch/x86_64/interrupts.S  Exception/IRQ/IPI stubs, GPR and FPU save/restore
  arch/x86_64/smp_entry.S   AP entry: private stack, kernel CR3, ap_main
  console.zig      framebuffer text console + serial mirroring
  font.zig         8x16 bitmap font
  limine.zig       Limine protocol bindings
  main.zig         _start, kmain, panic, boot sequence, M1c-M12 smoke tests
  memory/pmm.zig   bitmap physical page allocator from the Limine memory map
  memory/vmm.zig   4-level page tables, kernel/HHDM mappings, CR3 switch, TLB shootdown hook
  memory/heap.zig  locked lazily mapped first-fit kernel heap + std.mem.Allocator
  sched.zig        per-CPU scheduler, wait queues, mutex/condition, IPIs, TLB shootdown
  smp.zig          Limine MP bring-up, AP scheduler entry and M11 SMP tests
  sync.zig         IRQ-safe and SMP-safe spinlocks, interrupt save/restore
tools/run.sh       Build ESP (vvfat) and launch QEMU
tools/genfont.py   Regenerate src/font.zig from a system font
third_party/limine/ Vendored Limine UEFI binary (BOOTX64.EFI)
docs/              Architecture and development documentation
```

## Documentation
Detailed documentation lives in [`docs/`](docs/README.md), split by subsystem
and workflow:

- [Architecture overview](docs/architecture/overview.md)
- [Boot and early bring-up](docs/architecture/boot.md)
- [Memory management](docs/architecture/memory.md)
- [CPU and interrupts](docs/architecture/cpu-interrupts.md)
- [Scheduling](docs/architecture/scheduling.md)
- [Synchronization](docs/architecture/synchronization.md)
- [SMP bring-up](docs/architecture/smp.md)
- [Building](docs/development/building.md)
- [Testing](docs/development/testing.md)
- [Technical debt and known issues](docs/development/technical-debt.md)
- [Roadmap](docs/development/roadmap.md)

The detailed implementation notes that previously lived in this README are
maintained in those documents, with source references, implementation status,
test results, limitations, and planned work kept separate.
