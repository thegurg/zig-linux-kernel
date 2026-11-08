# Technical debt and known issues

**Purpose:** record correctness hazards, unsafe assumptions, and current
limitations that are visible in the source. This document describes the state
after M11; **RESOLVED** entries are kept so the audit trail and the remaining
work stay separate.

> **Status legend:** **OPEN** means the issue exists in the current source.
> **PARTIAL** means a feature exists but has a documented limitation.
> **DEFERRED** means the issue is intentionally out of scope for the current
> milestone and is tracked in the [roadmap](roadmap.md). **RESOLVED** means the
> issue was fixed in the pre-M11 bugfix pass or in M11.

## Critical

### 1. `IrqSpinLock` stored saved flags in the shared lock object

**Status: RESOLVED.** **Source:** [`src/sync.zig`](../../src/sync.zig).

The old implementation kept a single `flags: u64` field in the lock object, so
contending CPUs overwrote each other's saved `RFLAGS`, and nested acquisitions
had the same problem. `acquire` now returns a `Guard` value carrying the saved
flags on the caller's stack; `release` takes that guard by value. All
scheduler, VMM, PMM, console, and serial call sites use the guard form.

Guards must still be released on the same CPU and in LIFO order, and
`IrqSpinLock` remains non-reentrant.

### 2. Zig reordered the per-CPU state used by GS-relative assembly

**Status: RESOLVED.** **Sources:**
[`src/arch/x86_64/cpu.zig`](../../src/arch/x86_64/cpu.zig),
[`src/smp.zig`](../../src/smp.zig).

Zig's automatic struct layout reordered the fields of `cpu.PerCpu`, so
`%gs:8`/`%gs:12` did not read `index`/`lapic_id`. Every AP reported CPU index 0,
received no schedulable task, and the SMP test timed out. `PerCpu` is now an
`extern struct`, and compile-time `@offsetOf` checks enforce the offsets used by
assembly (`fpu_state` 0, `index` 8, `lapic_id` 12).

`ApContext`, whose first field is loaded by `smp_entry.S` before Zig runs, was
also changed to `extern struct` with an offset check for `stack_top`.

## High

### 3. The heap is not thread-safe

**Status: PARTIAL.** **Source:**
[`src/memory/heap.zig`](../../src/memory/heap.zig).

The PMM, VMM, console, and serial paths now have IRQ-safe locks. The heap free
list, break, and statistics are still unsynchronized. Two CPUs calling
`heap.alloc` or `heap.free` concurrently can corrupt the free list. The current
M11 tests do not perform concurrent heap allocation, and boot-time allocation is
single-threaded. A heap lock must be added before using the allocator from
multiple CPUs; see the lock ordering in
[synchronization](../architecture/synchronization.md).

### 4. TLB shootdown has a bounded, best-effort wait

**Status: PARTIAL.** **Sources:**
[`src/memory/vmm.zig`](../../src/memory/vmm.zig),
[`src/sched.zig`](../../src/sched.zig).

`unmapPage` clears the PTE, releases the page-table lock, and invokes
`sched.shootdownTlb`, which sends IPI 241 to every other online CPU and waits
for acknowledgements. The wait is bounded at 50,000,000 `pause` iterations.

A target CPU that runs with interrupts disabled for longer than the bound will
not acknowledge in time, and the shooter proceeds without its invalidation. The
current tests shoot down from the BSP while the APs are idle, so this path is
not stressed. A fully robust design needs a per-CPU pending-generation counter
so a CPU can re-check a missed shootdown when it re-enables interrupts.

The shootdown lock is a plain `SpinLock`, deliberately not `IrqSpinLock`, so a
waiting shooter can still take a remote IPI. It must never be held while taking
another lock.

### 5. The timer is BSP-only and APs are not preempted by a timer

**Status: PARTIAL.** **Sources:**
[`src/sched.zig`](../../src/sched.zig),
[`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig).

IRQ0 remains a legacy PIC/PIT interrupt delivered to the BSP. Every tick
increments one global counter and scans all blocked tasks. APs switch tasks only
through explicit scheduler calls or reschedule/TLB IPIs. There is no APIC timer,
no per-CPU tick counter, and no timer-driven AP preemption. The M11 selftest
masks IRQ0 before running the SMP tests, so AP sleep/timeout wakeup is not
covered end-to-end.

### 6. AP NMI handling is not tested

**Status: PARTIAL.** **Sources:**
[`src/arch/x86_64/interrupts.S`](../../src/arch/x86_64/interrupts.S),
[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig).

AP exceptions now save and restore the per-CPU task FPU state, and AP `int3` is
tested. NMI has no dedicated handler or test. The console used by the exception
dispatcher is locked, but an NMI arriving while a CPU holds an IRQ-safe lock
would still see the normal exception path rather than an NMI-safe path.

## Medium

### 7. Fixed resource limits

**Status: PARTIAL.** Current limits are deliberate but constrain later work:

- PMM manages at most 4 GiB of physical memory.
- The heap reserves exactly 64 MiB of virtual address space.
- The task table has 32 slots, including boot and one idle task per CPU.
- `max_cpus` is 8; larger MP responses are rejected.
- AP boot/task stacks are 16 KiB; the BSP kernel stack is 64 KiB; each #DF IST
  stack is 8 KiB.
- Wait queues hold at most `max_tasks` waiters.

### 8. No priorities, migration, or join

**Status: DEFERRED.** The scheduler is round-robin over ready tasks on each CPU.
Tasks are pinned at creation and never migrate. There are no priority levels and
no join/wait-for-exit API; tests poll `finishedCount()`.

### 9. Static, caller-owned task stacks

**Status: PARTIAL.** Tasks use stacks supplied to `sched.create`. There is no
guard page, automatic stack allocation, or stack-overflow detection.

### 10. Allocator concurrency is not stress-tested

**Status: PARTIAL.** The PMM and VMM have locks, but the M11 tests do not run
concurrent allocation/mapping workloads. The VMM's `mapPage` can allocate a
page-table page from the PMM while holding `table_lock`, so the lock order is
`table_lock` before `pmm.lock`; this is documented but only lightly exercised.

### 11. Test coverage gaps

**Status: PARTIAL.** **Sources:**
[`src/test_root.zig`](../../src/test_root.zig),
[`tools/run.sh`](../../tools/run.sh).

Covered in M11:

- AP scheduler workers, cross-CPU wake, AP `int3`/FPU state, TLB shootdown, and
  nested `IrqSpinLock` guards;
- the smoke assertion builds its expected `smp: cpus=<N>` string from
  `ZIG_KERNEL_SMP`, and checks the M11 result markers.

Still open:

- no AP NMI test;
- no concurrent TLB-shootdown or interrupts-disabled-target test;
- no AP timer/timeout test;
- no concurrent heap allocation test;
- no cross-CPU mutex/condition stress test.

## Low

### 12. Heap lacks `resize`/`remap`

**Status: DEFERRED.** [`src/memory/heap.zig`](../../src/memory/heap.zig) sets
`std.mem.Allocator.noResize` and `noRemap`, so callers fall back to
allocate-copy-free. There is no shrinking or in-place growth.

### 13. No NX-bit policy

**Status: DEFERRED.** The VMM defines and uses present/writable/user/cache
bits, but not the NX bit. Kernel mappings are separated into read-only and
read-write segments, not executable and non-executable ones.

### 14. No user mode or address-space isolation

**Status: DEFERRED.** All tasks share the kernel page tables. There are no user
page tables, privilege transitions, or per-process address spaces. The IDT
dispatcher has a `from_user` branch for reporting, but user mode is not
implemented.

## Implementation status summary

| Area | Status | Notes |
| --- | --- | --- |
| `IrqSpinLock` correctness | **IMPLEMENTED** | Per-acquisition guard; verified by the full scheduler suite. |
| GS-relative per-CPU layout | **IMPLEMENTED** | `extern struct` plus compile-time offset checks. |
| SMP scheduling | **IMPLEMENTED** | Per-CPU current/idle state; pinned tasks. |
| Cross-CPU wakeups / IPIs | **IMPLEMENTED** | LAPIC/x2APIC, vectors 240/241/255. |
| AP exception/FPU safety | **IMPLEMENTED** | `%gs:0` per-CPU FXSAVE; AP `int3` test. |
| TLB shootdown | **PARTIAL** | Bounded acknowledgement wait; not stressed with IRQs disabled. |
| Allocator thread safety | **PARTIAL** | PMM/VMM/console/serial locked; heap unlocked. |
| AP setup ordering | **RESOLVED** | SSE and `CR0.WP` set in the assembly stub; global TLB flushed after `CR3`. |
| AP timer / per-CPU ticks | **DEFERRED** | Timer remains BSP PIT. |
| Test coverage | **PARTIAL** | M11 tests added; gaps listed above. |
| Resource limits | **PARTIAL** | 4 GiB PMM, 64 MiB heap, 32 tasks, 8 CPUs. |

## Related documentation

- [Synchronization](../architecture/synchronization.md)
- [Scheduling](../architecture/scheduling.md)
- [SMP bring-up](../architecture/smp.md)
- [Memory management](../architecture/memory.md)
- [CPU and interrupts](../architecture/cpu-interrupts.md)
- [Testing](testing.md)
- [Roadmap](roadmap.md)
