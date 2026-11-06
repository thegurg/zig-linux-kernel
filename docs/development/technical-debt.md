# Technical debt and known issues

**Purpose:** record correctness hazards, unsafe assumptions, and current
limitations that are visible in the source. This document describes the state of
M10; it does not claim that any listed fix is implemented.

> **Status legend:** **OPEN** means the issue exists in the current source.
> **PARTIAL** means a feature exists but has a documented limitation.
> **DEFERRED** means the issue is intentionally out of scope for the current
> milestone and is tracked in the [roadmap](roadmap.md).

## Critical

### 1. `IrqSpinLock` stores saved flags in the shared lock object

**Status: OPEN.** **Source:** [`src/sync.zig`](../../src/sync.zig).

`IrqSpinLock` has a single `flags: u64` field. `acquire` writes the current
`RFLAGS` into that field before spinning, and `release` restores it after
unlocking. Under contention, another CPU overwrites `self.flags` before the
first CPU releases, so the first release restores the wrong interrupt state.
Nested acquisition on one CPU has the same problem, and the lock is not
reentrant.

This is currently latent because the scheduler is BSP-only, the main
`IrqSpinLock` user is the scheduler's `task_lock`, and APs do not take
scheduler locks. It becomes a real hazard as soon as APs enter the scheduler or
share a lock with an interrupt handler.

**Recommended direction:** use an acquisition-local guard or a returned token
that carries the saved `RFLAGS` per acquisition, and define a lock ordering
before enabling cross-CPU use.

### 2. The `IrqSpinLock` fix must precede M11 scheduler work

**Status: OPEN (ordering constraint).** The audit concluded that the
`IrqSpinLock` shared-flags problem must be fixed before APs are allowed to take
scheduler locks. Per-CPU scheduling, cross-CPU wakeups, and SMP-aware wait
queues depend on reliable interrupt-state restoration.

## High

### 3. The scheduler is BSP-only

**Status: PARTIAL.** **Source:** [`src/sched.zig`](../../src/sched.zig).

`current`, `tasks`, `task_count`, the tick/finished/blocked counters, and all
wait queues are global. Only the BSP takes IRQ0 and calls `sched.tick`. APs
never enter the scheduler, so there are no per-CPU run queues, no task
migration, and no way to run a task on a specific CPU.

### 4. Cross-CPU wakeups are impossible without LAPIC/IPI support

**Status: DEFERRED.** There is no local APIC, IOAPIC, APIC timer, or IPI
programming. The kernel uses only the legacy PIC and PIT, and APs run with
interrupts disabled. Waking a task on another CPU would require an IPI
mechanism that does not exist.

### 5. AP exception and NMI handling uses BSP/global state

**Status: OPEN.** **Sources:**
[`src/arch/x86_64/interrupts.S`](../../src/arch/x86_64/interrupts.S),
[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig).

`isr_common` saves FPU state through the global `current_fpu_state`, which
points at the BSP's current task. `isr_dispatch` uses the global scheduler and
console without locks. An exception or NMI on an AP would therefore use the
wrong FPU area and unsynchronized global state. APs currently run with
interrupts disabled and do not exercise this path.

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

### 8. AP setup gaps

**Status: OPEN.** **Sources:**
[`src/smp.zig`](../../src/smp.zig),
[`src/arch/x86_64/smp_entry.S`](../../src/arch/x86_64/smp_entry.S).

- `ap_main` calls Zig code before `cpu.enableSse()`. If the compiler emits an
  SSE instruction before that call, the AP can fault.
- APs do not set `CR0.WP`, unlike the BSP during `vmm.init()`.
- The AP stub switches `CR3` without flushing global TLB entries. The BSP has
  already flushed them before releasing APs, so the shared mappings work, but
  this is not a general solution after later mapping changes.
- APs do not install a per-CPU scheduler entry, timer, or idle loop.

### 9. No APIC support beyond recording the x2APIC flag

**Status: DEFERRED.** `mp_request.flags = 0`, and `stats.x2apic` is only
logged. There is no LAPIC/IOAPIC/APIC-timer/IPI programming. The PIC and PIT
remain the only interrupt sources.

### 10. Stale or misleading log messages

**Status: OPEN.** **Source:** [`src/main.zig`](../../src/main.zig).

- The line `M1c complete. Paging and kernel heap are live.` is printed
  unconditionally, even after later milestones have run and even though it is
  not tied to a specific check.
- `timer: PIT 100 Hz, interrupts enabled` is printed before `sched.exit()`
  reaches the idle task, which is where `sti` actually executes. The message
  describes the intended state, not the exact moment interrupts are enabled.
- `smp: N APs online, parked` is printed after `online_count` reaches the
  target, but an AP may still be between that increment and its `hlt`.
- `ap_contexts[*].online` and `.done` fields exist but are not used by the
  current code; the global counters are used instead.

These logs are useful diagnostics, but tests should not treat them as precise
synchronization points.

### 11. Test coverage gaps

**Status: OPEN.** **Sources:**
[`src/test_root.zig`](../../src/test_root.zig),
[`src/limine.zig`](../../src/limine.zig),
[`tools/run.sh`](../../tools/run.sh).

- The host test root contains only a trivial test.
- The `limine.zig` `base revision marker layout` test is not wired into
  `zig build test`.
- There is no AP exception, NMI, or AP FPU-state test.
- There is no TLB-shootdown test (the feature is absent).
- There is no nested or cross-CPU `IrqSpinLock` test; the shared-flags defect
  is latent.
- The smoke test hardcodes `grep -q "smp: cpus=4"`, so any
  `ZIG_KERNEL_SMP` value other than 4 can cause a false failure.

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

### 18. `IrqLock` shares the same saved-flags pattern

**Status: OPEN.** `IrqLock` also stores `flags` in the lock object. It is
explicitly a single-CPU helper and does not serialize across CPUs, but the
shared-flags pattern has the same nesting hazard as `IrqSpinLock`.

## Implementation status summary

| Area | Status | Notes |
| --- | --- | --- |
| `IrqSpinLock` correctness | **OPEN / critical** | Shared flags; fix before M11. |
| SMP scheduling | **DEFERRED** | BSP-only scheduler. |
| Cross-CPU wakeups / IPIs | **DEFERRED** | No LAPIC/IPI support. |
| AP exception/FPU safety | **OPEN** | Uses global BSP state. |
| TLB shootdown | **DEFERRED** | Local `invlpg` only. |
| Allocator/console/serial thread safety | **OPEN** | Global state without locks. |
| AP setup ordering | **OPEN** | Zig before `enableSse`, no `CR0.WP`, no global TLB flush. |
| Test coverage | **PARTIAL** | Smoke/fault tests exist; gaps listed above. |
| Resource limits | **PARTIAL** | 4 GiB PMM, 64 MiB heap, 8 tasks, 8 CPUs. |

## Related documentation

- [Synchronization](../architecture/synchronization.md)
- [Scheduling](../architecture/scheduling.md)
- [SMP bring-up](../architecture/smp.md)
- [Memory management](../architecture/memory.md)
- [CPU and interrupts](../architecture/cpu-interrupts.md)
- [Testing](testing.md)
- [Roadmap](roadmap.md)
