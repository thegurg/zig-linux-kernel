# Technical debt and known issues

**Purpose:** record correctness hazards, unsafe assumptions, and current
limitations that are visible in the source. This document describes the state
after the pre-M11 bugfix pass; **RESOLVED** entries are kept so the audit trail
and the remaining work stay separate.

> **Status legend:** **OPEN** means the issue exists in the current source.
> **PARTIAL** means a feature exists but has a documented limitation.
> **DEFERRED** means the issue is intentionally out of scope for the current
> milestone and is tracked in the [roadmap](roadmap.md). **RESOLVED** means the
> issue was fixed in the pre-M11 bugfix pass.

## Critical

### 1. `IrqSpinLock` stored saved flags in the shared lock object

**Status: RESOLVED.** **Source:** [`src/sync.zig`](../../src/sync.zig).

The old implementation kept a single `flags: u64` field in the lock object, so
contending CPUs overwrote each other's saved `RFLAGS`, and nested acquisitions
had the same problem. `acquire` now returns a `Guard` value carrying the saved
flags on the caller's stack; `release` takes that guard by value. All
`task_lock` call sites in [`src/sched.zig`](../../src/sched.zig) use
`const guard = task_lock.acquire(); defer guard.release();`.

Guards must still be released on the same CPU and in LIFO order, and
`IrqSpinLock` remains non-reentrant.

### 2. The `IrqSpinLock` fix had to precede M11 scheduler work

**Status: RESOLVED (ordering constraint satisfied).** The per-acquisition guard
fix landed before any AP was allowed to take scheduler locks. Per-CPU
scheduling, cross-CPU wakeups, and SMP-aware wait queues can now rely on
reliable interrupt-state restoration.

## High

### 3. The scheduler is BSP-only

**Status: PARTIAL.** **Source:** [`src/sched.zig`](../../src/sched.zig).

`current`, `tasks`, `task_count`, the tick/finished/blocked counters, and all
wait queues are global. Only the BSP takes IRQ0 and calls `sched.tick`. APs
never enter the scheduler, so there are no per-CPU run queues, no task
migration, and no way to run a task on a specific CPU.

### 4. Cross-CPU wakeups are impossible without LAPIC/IPI support

**Status: DEFERRED.** There is no local APIC, IOAPIC, APIC timer, or IPI
programming. The kernel uses only the legacy PIC and PIT, and APs never enter
the scheduler. Waking a task on another CPU would require an IPI
mechanism that does not exist.

### 5. AP exception and NMI handling uses BSP/global state

**Status: OPEN.** **Sources:**
[`src/arch/x86_64/interrupts.S`](../../src/arch/x86_64/interrupts.S),
[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig).

`isr_common` saves FPU state through the global `current_fpu_state`, which
points at the BSP's current task. `isr_dispatch` uses the global scheduler and
console without locks. An exception or NMI on an AP would therefore use the
wrong FPU area and unsynchronized global state. APs currently do not enter the
scheduler or exercise this path.

### 6. No TLB shootdown

**Status: DEFERRED.** **Source:** [`src/memory/vmm.zig`](../../src/memory/vmm.zig).

`vmm.unmapPage` executes `invlpg` only on the calling CPU. If another CPU has
translated the page, its TLB entry remains valid. There is no shootdown IPI or
generation counter. This is not exercised today because APs do not share
mutable mappings with the BSP during normal operation, but it is required for
safe SMP memory management.

### 7. PMM, VMM, heap, console, and serial are not thread-safe

**Status: OPEN.** **Sources:**
[`src/memory/pmm.zig`](../../src/memory/pmm.zig),
[`src/memory/vmm.zig`](../../src/memory/vmm.zig),
[`src/memory/heap.zig`](../../src/memory/heap.zig),
[`src/console.zig`](../../src/console.zig),
[`src/arch/x86_64/serial.zig`](../../src/arch/x86_64/serial.zig).

These subsystems use global state without locks:

- the PMM bitmaps, hint, and counters;
- the VMM page tables and CR3 helpers;
- the heap free list and break;
- the console cursor, text grid, and framebuffer writes;
- the serial transmit path.

The current AP workload avoids them after bring-up, but any multi-CPU use will
race. Console output from APs would also interleave.

## Medium

### 8. AP setup ordering and remaining AP integration

**Status: PARTIAL (setup ordering resolved).** **Sources:**
[`src/smp.zig`](../../src/smp.zig),
[`src/arch/x86_64/smp_entry.S`](../../src/arch/x86_64/smp_entry.S).

The pre-Zig setup gaps are fixed in `smp_entry.S`:

- SSE is enabled (CR0.EM/TS clear, CR0.MP/NE set, CR4.OSFXSR/OSXMMEXCPT set,
  `fninit`) before the stub calls `ap_main`, so no compiler-generated SSE
  instruction can fault on an AP.
- APs set `CR0.WP`, matching the BSP and enforcing read-only mappings in ring 0.
- The AP stub clears `CR4.PGE` across the `CR3` write and restores the original
  CR4 value, flushing global translations as well as non-global ones.

What remains is AP integration, not setup ordering:

- APs do not install a per-CPU scheduler entry, timer, or idle loop.
- There is still no general TLB-shootdown mechanism for mapping changes made
  after an AP is running; the stub only flushes at the initial `CR3` switch.

### 9. No APIC support beyond recording the x2APIC flag

**Status: DEFERRED.** `mp_request.flags = 0`, and `stats.x2apic` is only
logged. There is no LAPIC/IOAPIC/APIC-timer/IPI programming. The PIC and PIT
remain the only interrupt sources.

### 10. Stale or misleading log messages

**Status: RESOLVED.** **Source:** [`src/main.zig`](../../src/main.zig),
[`src/smp.zig`](../../src/smp.zig).

- The unconditional `M1c complete` line was removed. The normal boot path now
  prints `boot: <version> initialized (memory, scheduler, SMP)` immediately
  before entering the scheduler; the selftest image keeps its explicit
  `M1c checks passed` marker.
- `timer: PIT 100 Hz, IRQ0 unmasked` replaces the premature "interrupts
  enabled" wording. The following line states that interrupts are enabled in
  the idle task, which is where `sti` actually executes.
- The normal-boot AP message now waits for `smp.waitParked()`, which is backed
  by a `parked_count` incremented at the top of the AP park loop. The log is
  therefore printed only after every AP has entered its final `hlt` loop.

`ap_contexts[*].online` and `.done` fields remain unused (the global counters
are authoritative); they are harmless reserved fields for M11 per-CPU state.

### 11. Test coverage gaps

**Status: PARTIAL.** **Sources:**
[`src/test_root.zig`](../../src/test_root.zig),
[`src/limine.zig`](../../src/limine.zig),
[`tools/run.sh`](../../tools/run.sh).

Resolved in the pre-M11 bugfix pass:

- [`src/test_root.zig`](../../src/test_root.zig) imports `limine.zig` from a
  test block, so the `base revision marker layout` test is part of
  `zig build test`.
- The smoke assertion builds its expected `smp: cpus=<N>` string from
  `ZIG_KERNEL_SMP` (default 4), so non-default CPU counts no longer cause a
  false failure.

Still open:

- There is no AP exception, NMI, or AP FPU-state test.
- There is no TLB-shootdown test (the feature is absent).
- There is no automated nested or cross-CPU `IrqSpinLock` test. The guard
  implementation is covered indirectly by every scheduler/wait-queue test, but
  contention is latent until M11.

### 12. Fixed resource limits

**Status: PARTIAL.** Current limits are deliberate but constrain later work:

- PMM manages at most 4 GiB of physical memory.
- The heap reserves exactly 64 MiB of virtual address space.
- The task table has 8 slots, including boot and idle.
- `max_cpus` is 8; larger MP responses are rejected.
- AP stacks are 16 KiB; the BSP kernel stack is 64 KiB; each #DF IST stack is
  8 KiB.
- Wait queues hold at most `max_tasks` waiters.

## Low

### 13. Heap lacks `resize`/`remap`

**Status: DEFERRED.** [`src/memory/heap.zig`](../../src/memory/heap.zig) sets
`std.mem.Allocator.noResize` and `noRemap`, so callers fall back to
allocate-copy-free. There is no shrinking or in-place growth.

### 14. No NX-bit policy

**Status: DEFERRED.** The VMM defines and uses present/writable/user/cache
bits, but not the NX bit. Kernel mappings are separated into read-only and
read-write segments, not executable and non-executable ones.

### 15. No user mode or address-space isolation

**Status: DEFERRED.** All tasks share the kernel page tables. There are no user
page tables, privilege transitions, or per-process address spaces. The IDT
dispatcher has a `from_user` branch for reporting, but user mode is not
implemented.

### 16. No priorities, migration, or join

**Status: DEFERRED.** The scheduler is round-robin over ready tasks. It has no
priority levels, no task migration, and no join/wait-for-exit API; tests poll
`finishedCount()`.

### 17. Static, caller-owned task stacks

**Status: PARTIAL.** Tasks use stacks supplied to `sched.create`. There is no
guard page, automatic stack allocation, or stack-overflow detection.

### 18. `IrqLock` shared saved flags

**Status: RESOLVED.** `IrqLock.acquire` now returns a guard carrying the saved
flags, so it no longer stores state in the lock object. It remains a single-CPU
interrupt-masking helper and does not serialize across CPUs.

## Implementation status summary

| Area | Status | Notes |
| --- | --- | --- |
| `IrqSpinLock` correctness | **IMPLEMENTED** | Per-acquisition guard; verified by the full scheduler suite. |
| `IrqLock` correctness | **IMPLEMENTED** | Per-acquisition guard; single-CPU semantics unchanged. |
| SMP scheduling | **DEFERRED** | BSP-only scheduler. |
| Cross-CPU wakeups / IPIs | **DEFERRED** | No LAPIC/IPI support. |
| AP exception/FPU safety | **OPEN** | Uses global BSP state. |
| TLB shootdown | **DEFERRED** | Local `invlpg` only; AP boot switch now flushes globals. |
| Allocator/console/serial thread safety | **OPEN** | Global state without locks. |
| AP setup ordering | **RESOLVED** | SSE and `CR0.WP` set in the assembly stub; global TLB flushed after `CR3`. |
| Test coverage | **PARTIAL** | Host Limine test and dynamic SMP assertion added; gaps listed above. |
| Resource limits | **PARTIAL** | 4 GiB PMM, 64 MiB heap, 8 tasks, 8 CPUs. |

## Related documentation

- [Synchronization](../architecture/synchronization.md)
- [Scheduling](../architecture/scheduling.md)
- [SMP bring-up](../architecture/smp.md)
- [Memory management](../architecture/memory.md)
- [CPU and interrupts](../architecture/cpu-interrupts.md)
- [Testing](testing.md)
- [Roadmap](roadmap.md)
