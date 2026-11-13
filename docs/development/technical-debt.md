# Technical debt and known issues

**Purpose:** record correctness hazards, unsafe assumptions, and current
limitations that are visible in the source. This document describes the state
after M13; **RESOLVED** entries are kept so the audit trail and the remaining
work stay separate.

> **Status legend:** **OPEN** means the issue exists in the current source.
> **PARTIAL** means a feature exists but has a documented limitation.
> **DEFERRED** means the issue is intentionally out of scope for the current
> milestone and is tracked in the [roadmap](roadmap.md). **RESOLVED** means the
> issue was fixed in the pre-M11 bugfix pass, M11, M12, or M13.

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

### 3. The heap was not thread-safe

**Status: RESOLVED (M12).** **Source:**
[`src/memory/heap.zig`](../../src/memory/heap.zig).

The free list, break, and statistics are now protected by `heap_lock`, an
IRQ-safe spinlock acquired for every `alloc`, `free`, `stats`, and `init` call.
`grow` runs under the same lock, so the lock order is heap before
`vmm.table_lock` and `pmm.lock`. The M12 concurrent-heap test runs
allocate/write/verify/free loops on every CPU and reports zero errors.

The grow path deliberately does not unmap pages on failure: it returns the
mapped prefix to the free list and leaves the rest of that reserved range unused.
This avoids holding `heap_lock` across a TLB shootdown. The lost address space
is recorded as issue 15.

### 4. TLB shootdown had a bounded, best-effort wait

**Status: RESOLVED (M12).** **Sources:**
[`src/memory/vmm.zig`](../../src/memory/vmm.zig),
[`src/sched.zig`](../../src/sched.zig).

`unmapPage` clears the PTE, releases the page-table lock, and invokes
`sched.shootdownTlb`. The old implementation used one shared address and an
acknowledgement mask, serialized by a plain spinlock, and gave up after
50,000,000 `pause` iterations.

The replacement uses lock-free per-CPU mailboxes: each shooter owns a row of
`(address, sequence)` slots and each target acknowledges into its own column.
`shootdownTlb` publishes a unique sequence, sends IPI 241, and waits until every
target acknowledges that sequence. The IPI handler takes no locks, so a CPU that
is itself waiting for acknowledgements can still service a request from another
CPU. There is no timeout.

Callers must run `unmapPage` with interrupts enabled when other CPUs are online;
otherwise the waiting CPU cannot take their shootdown IPIs. The heap grow path
satisfies this by never unmapping while `heap_lock` is held. The M12 tests cover
a target with interrupts disabled and several CPUs shooting down concurrently.

### 5. The timer was BSP-only and APs were not preempted by a timer

**Status: RESOLVED (M13).** **Sources:**
[`src/sched.zig`](../../src/sched.zig),
[`src/arch/x86_64/lapic.zig`](../../src/arch/x86_64/lapic.zig),
[`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig).

Each CPU now owns a `cpu_ticks` entry. CPU 0 keeps the 100 Hz PIT on IRQ0; every
AP starts a periodic LAPIC timer on vector 242 after bring-up. The shared
`timerInterrupt` path advances only the local counter, wakes only blocked tasks
pinned to that CPU, and can preempt the local task. The reload value is calibrated
once on the BSP against a 50 ms PIT channel-2 reference, so no IOAPIC or ACPI
support is required.

The M13 test creates a timed sleeper on every AP and runs two CPU-bound tasks on
CPU 1 that must observe each other while both are running. `selftestSmp` still
masks the BSP PIT during the SMP tests, but AP timers remain active.

CPU 0 still uses the PIT rather than its LAPIC timer, and there is no IOAPIC
routing; that remaining work is tracked in the roadmap.

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

### 10. Allocator concurrency is only lightly stressed

**Status: PARTIAL.** The M12 tests run concurrent heap allocations on every CPU
and concurrent per-AP map/unmap loops. They do not force PMM exhaustion or
page-table allocation failure. The VMM's `mapPage` can allocate a page-table page
from the PMM while holding `table_lock`, so the lock order is `table_lock` before
`pmm.lock`; this is documented and exercised, but not under memory pressure.

### 11. Test coverage gaps

**Status: PARTIAL.** **Sources:**
[`src/test_root.zig`](../../src/test_root.zig),
[`tools/run.sh`](../../tools/run.sh).

Covered in M11, M12, and M13:

- AP scheduler workers, cross-CPU wake, AP `int3`/FPU state, TLB shootdown, and
  nested `IrqSpinLock` guards;
- concurrent heap allocation from every CPU;
- TLB shootdown to a CPU with interrupts disabled;
- several CPUs issuing TLB shootdowns concurrently;
- per-AP tick counters, local AP sleep wakeup, and timer-driven AP preemption;
- the smoke assertion builds its expected `smp: cpus=<N>` string from
  `ZIG_KERNEL_SMP`, and checks the M11, M12, and M13 result markers.

Still open:

- no AP NMI test;
- no IOAPIC routing or CPU 0 LAPIC timer test;
- no cross-CPU mutex/condition stress test;
- no allocator test under PMM exhaustion or mapping failure.

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

### 15. Partial heap growth leaks reserved virtual address space

**Status: PARTIAL.** **Source:**
[`src/memory/heap.zig`](../../src/memory/heap.zig).

If a grow fails partway through mapping, the mapped prefix is returned to the
free list but the rest of the reserved range is not reclaimed. The heap keeps a
separate mapped-byte counter so statistics remain accurate, but repeated
failures could exhaust the 64 MiB virtual reservation. Reclaiming the range
would require unmapping pages and a TLB shootdown while the heap lock is held,
which the allocator deliberately avoids.

## Implementation status summary

| Area | Status | Notes |
| --- | --- | --- |
| `IrqSpinLock` correctness | **IMPLEMENTED** | Per-acquisition guard; verified by the full scheduler suite. |
| GS-relative per-CPU layout | **IMPLEMENTED** | `extern struct` plus compile-time offset checks. |
| SMP scheduling | **IMPLEMENTED** | Per-CPU current/idle state; pinned tasks. |
| Cross-CPU wakeups / IPIs | **IMPLEMENTED** | LAPIC/x2APIC, vectors 240/241/242/255. |
| AP exception/FPU safety | **IMPLEMENTED** | `%gs:0` per-CPU FXSAVE; AP `int3` test. |
| TLB shootdown | **IMPLEMENTED** | Lock-free mailboxes; waits for every acknowledgement. |
| Allocator thread safety | **IMPLEMENTED** | Heap, PMM, VMM, console, and serial use IRQ-safe locks. |
| AP setup ordering | **RESOLVED** | SSE and `CR0.WP` set in the assembly stub; global TLB flushed after `CR3`. |
| AP timer / per-CPU ticks | **IMPLEMENTED** | LAPIC timer vector 242; CPU 0 keeps the PIT. |
| Test coverage | **PARTIAL** | M11/M12/M13 tests added; gaps listed above. |
| Resource limits | **PARTIAL** | 4 GiB PMM, 64 MiB heap, 32 tasks, 8 CPUs. |

## Related documentation

- [Synchronization](../architecture/synchronization.md)
- [Scheduling](../architecture/scheduling.md)
- [SMP bring-up](../architecture/smp.md)
- [Memory management](../architecture/memory.md)
- [CPU and interrupts](../architecture/cpu-interrupts.md)
- [Testing](testing.md)
- [Roadmap](roadmap.md)
