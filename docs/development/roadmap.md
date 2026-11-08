# Roadmap

**Purpose:** record planned work separately from implemented behavior. Nothing
in this document is implemented unless it is also described as implemented in
the architecture documents.

**Current status:** M0-M11 are complete and validated through the QEMU test
flow. The pre-M11 bugfix pass and M11 landed before this documentation update.
M12 is the next milestone and has not been started.

## Pre-M11 bugfix pass (complete)

The architecture audit findings were fixed before starting M11:

- `sync.IrqSpinLock` and `sync.IrqLock` return per-acquisition guards; the
  scheduler's `task_lock` call sites use the guard form.
- AP setup ordering: `smp_entry.S` enables SSE and sets `CR0.WP` before Zig
  code, then flushes global translations across the `CR3` switch.
- Diagnostics: the unconditional `M1c complete` line was removed, the timer
  message no longer claims interrupts are enabled early, and the AP `parked`
  message waits on an explicit `parked_count`.
- `src/test_root.zig` imports the Limine binding test, and `tools/run.sh`
  derives the expected CPU count from `ZIG_KERNEL_SMP`.
- `initialFrame` stores a return trampoline in the task's initial return slot so
  a returning entry exits through the scheduler instead of `ret`-ing into
  garbage.

Validation: default KVM, TCG, and Debug `zig build test` runs pass; the smoke
flow also passes with `ZIG_KERNEL_SMP=1` and `=2`. See
[testing](testing.md) for the recorded results.

## M11: per-CPU scheduling and SMP-aware wait queues (complete)

### Goal

Move scheduling from a single global BSP scheduler to per-CPU scheduler state,
allow APs to schedule tasks, and make blocking primitives work across CPUs. This
requires an interrupt mechanism that can wake another CPU, so LAPIC/IPI support
is part of the milestone.

### What landed

1. **Lock ordering** — the order is documented in
   [synchronization](../architecture/synchronization.md). The scheduler uses one
   global `task_lock`; the VMM and PMM use IRQ-safe allocator locks; the TLB
   shootdown path uses a plain spinlock so a waiting CPU can still take the
   remote shootdown IPI; console and serial lock messages; the heap remains
   unlocked and is documented as partial.
2. **Per-CPU scheduler state** — every CPU has a `CpuState` (current task, idle
   task, scan cursor, pending sleep/wait requests), a private idle stack, and a
   `PerCpu` block installed through the GS base MSR. Tasks are pinned to a CPU
   at creation with `createOn`.
3. **AP scheduler entry** — APs leave Limine's park loop, install their per-CPU
   block, initialise the LAPIC, call `sched.initCpu`, and enter `enterScheduler`,
   which resumes the AP's idle frame. APs no longer halt permanently.
4. **LAPIC/IPI support** — xAPIC and x2APIC are detected from `IA32_APIC_BASE`.
   The kernel programs the spurious vector, reads LAPIC IDs, sends fixed IPIs to
   one CPU or all-but-self, and acknowledges interrupts with LAPIC EOI. Vector
   240 is the reschedule IPI, 241 the TLB IPI, and 255 the spurious gate.
5. **SMP-aware blocking primitives** — wait queues, mutexes, and condition
   variables enqueue and wake task IDs under `task_lock`; waking a task on
   another CPU sends a reschedule IPI. Mutex and condition waits pre-mark the
   current task blocked before releasing the scheduler lock, so a cross-CPU
   unlock cannot lose the wakeup.
6. **TLB shootdown** — `vmm.unmapPage` reports the unmapped address through a
   callback after releasing its page-table lock. The scheduler sends IPI 241 to
   every other online CPU and waits for acknowledgements.
7. **AP exception and FPU state** — `PerCpu.fpu_state` at offset 0 is reached
   through `%gs:0` from the interrupt entry stub and from `sched_resume`. The
   scheduler updates the per-CPU pointer when it switches tasks, so AP
   exceptions save and restore the interrupted AP task's state.
8. **Expanded tests** — the selftest now runs AP scheduler workers, a cross-CPU
   wakeup, an AP `int3`/FPU-preservation test, a TLB-shootdown test, and a
   nested `IrqSpinLock` guard test. The full flow passes under KVM, TCG,
   `-Doptimize=Debug`, and `ZIG_KERNEL_SMP=1/2/4`.

### Key bug found during M11 bring-up

Zig's automatic struct layout reordered the fields of `cpu.PerCpu`, so
`%gs:8`/`%gs:12` did not read `index`/`lapic_id`; every AP appeared to be CPU 0
and received no schedulable task. `PerCpu` is now an `extern struct` with
compile-time offset checks for `fpu_state`, `index`, and `lapic_id`.

### M11 acceptance criteria (met)

- APs run scheduler idle loops and can execute tasks.
- A task can be created on, and woken on, a CPU other than the BSP.
- Wait queues, mutexes, and condition variables preserve their signal/timeout
  semantics under cross-CPU wakeups.
- `IrqSpinLock` works under contention and nesting without corrupting
  interrupt state.
- TLB shootdown invalidates remote translations after `unmapPage`.
- AP exceptions use per-CPU FPU and scheduler state.
- The full test flow passes under KVM, TCG, and `-Doptimize=Debug`.

### M11 non-goals

- User mode, user address spaces, and system calls.
- A general driver framework or filesystem.
- Replacing the PIC/PIT entirely; there is no APIC timer or IOAPIC routing yet.
- More than `max_cpus = 8` without changing the GDT/TSS layout.

## Later work

The following items are deferred beyond M11. They are ordered by dependency,
not by priority.

| Item | Status | Notes |
| --- | --- | --- |
| Heap locking | **PLANNED** | PMM, VMM, console, and serial are locked; the heap free list is not. |
| LAPIC timer / IOAPIC interrupt routing | **PLANNED** | Timer ticks remain BSP-only through the PIT; APs receive only IPIs. |
| Per-CPU timer preemption | **PLANNED** | APs are preempted only by reschedule/TLB IPIs, not by a timer. |
| Physical memory above 4 GiB | **PLANNED** | PMM bitmap is sized for 4 GiB. |
| Heap `resize`/`remap` | **PLANNED** | Currently `noResize`/`noRemap`. |
| NX-bit policy | **PLANNED** | No executable/non-executable split yet. |
| User mode and address-space isolation | **PLANNED** | All tasks share kernel page tables. |
| Priorities, migration, join | **PLANNED** | Round-robin per CPU; tasks are pinned, tests poll counters. |
| AP NMI and additional exception tests | **PLANNED** | AP `int3`/FPU state is covered; NMI is not. |
| Concurrent heap/VMM allocation stress | **PLANNED** | VMM has a lock; heap does not. |

## Milestone history

| Milestone | Status | Summary |
| --- | --- | --- |
| M0 | **IMPLEMENTED** | Higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM/memory-map reporting, SSE. |
| M1a | **IMPLEMENTED** | Kernel stack, GDT/TSS, IDT, exception dispatcher, PIC remap/mask. |
| M1b | **IMPLEMENTED** | Bitmap PMM with double-free protection. |
| M1c | **IMPLEMENTED** | 4-level paging, HHDM, 64 MiB kernel heap. |
| M2 | **IMPLEMENTED** | IRQ stubs, 100 Hz PIT, preemptive round-robin scheduler. |
| M3 | **IMPLEMENTED** | Cooperative yield/exit, idle task, slot reuse. |
| M4 | **IMPLEMENTED** | Sleep and interrupt-safe locking. |
| M5 | **IMPLEMENTED** | Block/wake with blocked-task counter. |
| M6 | **IMPLEMENTED** | Wait queues with stale-waiter pruning. |
| M7 | **IMPLEMENTED** | Timed waits with signal/timeout distinction. |
| M8 | **IMPLEMENTED** | Mutex with ownership transfer and condition variables. |
| M9 | **IMPLEMENTED** | FPU/SIMD context switching. |
| M10 | **IMPLEMENTED** | Limine MP bring-up, per-CPU stacks/TSS, atomic spinlocks, SMP stress test. |
| Pre-M11 | **IMPLEMENTED** | Interrupt-safe guards, AP setup ordering, accurate diagnostics, task return trampoline, host SMP/test harness fixes. |
| M11 | **IMPLEMENTED** | Per-CPU scheduling, LAPIC/x2APIC IPIs, SMP-aware blocking, TLB shootdown, AP exception/FPU state, expanded tests. |

## Related documentation

- [Overview](../architecture/overview.md)
- [Scheduling](../architecture/scheduling.md)
- [Synchronization](../architecture/synchronization.md)
- [SMP bring-up](../architecture/smp.md)
- [Technical debt](technical-debt.md)
- [Testing](testing.md)
- [Building](building.md)
