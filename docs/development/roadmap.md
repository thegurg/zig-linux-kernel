# Roadmap

**Purpose:** record planned work separately from implemented behavior. Nothing
in this document is implemented unless it is also described as implemented in
the architecture documents.

**Current status:** M0-M10 are complete. M11 is the next milestone.
No M11 code has been started at the time of this documentation update.

## M11: per-CPU scheduling and SMP-aware wait queues

### Goal

Move scheduling from a single global BSP scheduler to per-CPU scheduler state,
allow APs to schedule tasks, and make blocking primitives work across CPUs.
This requires an interrupt mechanism that can wake another CPU, so LAPIC/IPI
support is part of the milestone rather than an optional extra.

### Why the current design cannot simply be extended

The existing scheduler and wait queues rely on three assumptions:

1. only the BSP runs the scheduler;
2. only the BSP takes IRQ0;
3. disabling interrupts on the current CPU is sufficient to protect scheduler
   and wait-queue state.

Those assumptions break under SMP. Cross-CPU wakeups need a way to interrupt a
remote CPU, and shared state needs real locks with per-acquisition interrupt
state.

### Ordered implementation plan

The order below follows the audit recommendation. The `IrqSpinLock` fix comes
first because every later lock depends on reliable interrupt-state restoration.

1. **Fix `sync.IrqSpinLock`** — replace the shared `flags` field with a
   per-acquisition guard/token, and audit `IrqLock` for the same pattern.
2. **Define lock ordering** — document and enforce the order among task/run-queue
   locks, wait-queue locks, and any allocator/console locks.
3. **Per-CPU scheduler state** — introduce per-CPU `current`, run queues, idle
   tasks, counters, and an AP scheduler entry. Keep the BSP as CPU 0.
4. **AP scheduler entry** — let APs leave the park loop and enter a scheduler
   idle loop instead of halting permanently.
5. **LAPIC/IPI support** — discover and map the local APIC, add an IPI send
   path, and use it for cross-CPU wakeups and TLB shootdown.
6. **SMP-aware wait queues, mutex, and condition** — make enqueue/wake operate
   on the correct CPU's run queue, preserve signal-vs-timeout semantics, and
   avoid lost wakeups.
7. **TLB shootdown** — invalidate remote TLB entries after `vmm.unmapPage` or
   mapping changes that affect other CPUs.
8. **AP exception and FPU state** — replace global `current_fpu_state` use in
   the interrupt path with per-CPU state, and make the dispatcher safe on APs.
9. **Expanded tests** — add KVM, TCG, and Debug runs covering AP scheduling,
   cross-CPU wakeups, nested/contended locks, TLB shootdown, and AP exceptions.

### M11 acceptance criteria (planned)

- APs run scheduler idle loops and can execute tasks.
- A task can be woken on a CPU other than the one it blocked on.
- Wait queues, mutexes, and condition variables preserve their current
  signal/timeout semantics under cross-CPU wakeups.
- `IrqSpinLock` works under contention and nesting without corrupting
  interrupt state.
- TLB shootdown prevents stale translations after unmap.
- AP exceptions use per-CPU FPU and scheduler state.
- The full test flow passes under KVM, TCG, and `-Doptimize=Debug`.

These criteria are **PLANNED**.

### M11 non-goals

- User mode, user address spaces, and system calls.
- A general driver framework or filesystem.
- Replacing the PIC/PIT entirely; the APIC timer may be added for per-CPU
  ticks, but that is a design decision for the milestone.
- More than `max_cpus = 8` without changing the GDT/TSS layout.

## Later work

The following items are deferred beyond M11. They are ordered by dependency,
not by priority.

| Item | Status | Notes |
| --- | --- | --- |
| LAPIC timer / IOAPIC / x2APIC | **PLANNED** | Required for richer interrupt routing; x2APIC is currently only logged. |
| Physical memory above 4 GiB | **PLANNED** | PMM bitmap is sized for 4 GiB. |
| Heap `resize`/`remap` | **PLANNED** | Currently `noResize`/`noRemap`. |
| NX-bit policy | **PLANNED** | No executable/non-executable split yet. |
| User mode and address-space isolation | **PLANNED** | All tasks share kernel page tables. |
| Priorities, migration, join | **PLANNED** | Round-robin only; tests poll counters. |
| Dynamic smoke-test CPU assertion | **PLANNED** | `tools/run.sh` hardcodes `smp: cpus=4`. |
| AP exception/NMI tests | **PLANNED** | Depends on per-CPU interrupt state. |
| Thread-safe PMM/VMM/heap/console/serial | **PLANNED** | Current global state is not locked. |

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
| M11 | **PLANNED** | Per-CPU scheduling and SMP-aware wait queues. |

## Related documentation

- [Overview](../architecture/overview.md)
- [Scheduling](../architecture/scheduling.md)
- [Synchronization](../architecture/synchronization.md)
- [SMP bring-up](../architecture/smp.md)
- [Technical debt](technical-debt.md)
- [Testing](testing.md)
- [Building](building.md)
