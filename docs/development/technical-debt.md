# Technical debt and known issues

**Purpose:** record correctness hazards, unsafe assumptions, and current
limitations that are visible in the source. This document describes the state
after M15; **RESOLVED** entries are kept so the audit trail and the remaining
work stay separate.

> **Status legend:** **OPEN** means the issue exists in the current source.
> **PARTIAL** means a feature exists but has a documented limitation.
> **DEFERRED** means the issue is intentionally out of scope for the current
> milestone and is tracked in the [roadmap](roadmap.md). **RESOLVED** means the
> issue was fixed in the pre-M11 bugfix pass, M11, M12, M13, M14, or M15.

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
is recorded as issue 16.

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

**Status: RESOLVED (M14).** **Sources:**
[`src/sched.zig`](../../src/sched.zig),
[`src/arch/x86_64/lapic.zig`](../../src/arch/x86_64/lapic.zig),
[`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig),
[`src/acpi.zig`](../../src/acpi.zig),
[`src/arch/x86_64/ioapic.zig`](../../src/arch/x86_64/ioapic.zig).

Each CPU owns a `cpu_ticks` entry. M13 gave every AP a periodic LAPIC timer on
vector 242; M14 moved CPU 0 onto the same vector after calibrating the timer on
the BSP against a 50 ms PIT channel-2 reference. The shared `timerInterrupt` path
advances only the local counter, wakes only blocked tasks pinned to that CPU, and
can preempt the local task.

M14 also parses the ACPI MADT, resolves ISA IRQ0 through its Interrupt Source
Override, and drives an IOAPIC redirection entry. The PIT IRQ0/PIC path remains
the documented fallback and is exercised by the `force_pit` boot image. PIT
channel 2 remains a calibration-only reference and is never an interrupt source.
An IOAPIC-delivered fixed interrupt is acknowledged with a LAPIC EOI; the legacy
PIC path keeps its separate PIC EOI.

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

### 8. No task migration or load balancing

**Status: DEFERRED (M20).** Every task is pinned at creation and never migrates.
M15 added priority levels and single-waiter join, so the scheduler now has
weighted selection and exit statuses, but a ready task cannot move to an idle
CPU. Tests still poll `finishedCount()` for tasks that are not joinable.

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

Covered in M11, M12, M13, M14, and M15:

- AP scheduler workers, cross-CPU wake, AP `int3`/FPU state, TLB shootdown, and
  nested `IrqSpinLock` guards;
- concurrent heap allocation from every CPU;
- TLB shootdown to a CPU with interrupts disabled;
- several CPUs issuing TLB shootdowns concurrently;
- per-AP tick counters, local AP sleep wakeup, and timer-driven AP preemption;
- ACPI/MADT discovery, ISO-resolved IRQ0, IOAPIC redirection readback, end-to-end
  IOAPIC delivery with a LAPIC EOI, pin masking, and the CPU 0 LAPIC timer;
- invariant-TSC detection, PIT-based calibration, cross-CPU sync, monotonic
  samples on every AP, deadline heap push/pop, `sleepMs`, join outcomes,
  priority order, and the tick fallback;
- the `force_pit` fallback boot path;
- the smoke assertion builds its expected `smp: cpus=<N>` string from
  `ZIG_KERNEL_SMP`, and checks the M11-M15 result markers.

Still open:

- no AP NMI test;
- no test for ISA IRQs other than IRQ0, level-triggered ISOs, multiple IOAPICs,
  or MSI/MSI-X;
- no corrupted-ACPI-table injection test;
- no cross-CPU mutex/condition stress test;
- no allocator test under PMM exhaustion or mapping failure;
- no TSC-sync timeout or out-of-tolerance-offset test;
- no concurrent-joiner, `detach`-race, or joined-slot-reuse stress test.

### 12. ACPI/IOAPIC platform assumptions are narrow

**Status: PARTIAL.** **Sources:**
[`src/acpi.zig`](../../src/acpi.zig),
[`src/arch/x86_64/ioapic.zig`](../../src/arch/x86_64/ioapic.zig).

- ACPI discovery runs only on the BSP and assumes the tables remain valid in
  memory for the kernel lifetime.
- The MADT Local APIC Address Override is parsed and logged, but the LAPIC driver
  continues to derive its base from `IA32_APIC_BASE`. The MSR value is
  authoritative.
- `ioapic.init()` marks the 2 MiB HHDM chunk containing each IOAPIC window
  uncached. This assumes the window lies within a single mapped 2 MiB chunk and
  that `vmm.markUncached` succeeds; a failure skips that controller.
- IOAPIC programming is BSP-only at boot and has no lock. It is not yet called
  concurrently from other CPUs or from a general interrupt-routing API.
- Only ISA IRQ0 is exercised end-to-end. The resolution helper is generic, but
  other bus/IRQ combinations and level-triggered semantics are untested.
- MSI/MSI-X, PCI interrupt routing, and full AML/namespace evaluation are
  deferred to M18 or later.

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

### 16. Partial heap growth leaks reserved virtual address space

**Status: PARTIAL.** **Source:**
[`src/memory/heap.zig`](../../src/memory/heap.zig).

If a grow fails partway through mapping, the mapped prefix is returned to the
free list but the rest of the reserved range is not reclaimed. The heap keeps a
separate mapped-byte counter so statistics remain accurate, but repeated
failures could exhaust the 64 MiB virtual reservation. Reclaiming the range
would require unmapping pages and a TLB shootdown while the heap lock is held,
which the allocator deliberately avoids.

## Timekeeping limitations (M15)

### 17. TSC selection depends on CPUID and one calibration pass

**Status: PARTIAL.** **Source:**
[`src/time.zig`](../../src/time.zig).

The TSC is used only when CPUID advertises both TSC support and the invariant
(non-stop) bit. Calibration runs once on the BSP with three 20 ms PIT-channel-2
samples and rejects a spread above 2%, a zero delta, or a rate outside
100 MHz-10 GHz. A platform whose TSC drifts after boot, whose PIT reference is
inaccurate, or whose CPUID lies about invariance is not re-checked. A rejected
or absent TSC silently falls back to ticks and records the reason in `info()`;
there is no runtime re-calibration or migration back to the TSC.

KVM hides the invariant-TSC bit by default for migration safety. The test harness
requests `+invtsc` when the host advertises `nonstop_tsc`; a host without that
CPU feature, or TCG, exercises only the tick fallback.

### 18. TSC sync skew is measured, not corrected iteratively

**Status: PARTIAL.** **Sources:**
[`src/time.zig`](../../src/time.zig),
[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig).

`syncAll()` broadcasts one reference sample with IPI 243 and stores each CPU's
raw offset. The measured spread includes IPI delivery and sampling jitter; it is
reported but not used to refine offsets or compensate for oscillator drift. The
BSP waits up to 100,000,000 `pause` iterations for acknowledgements and returns
false on timeout, but callers may continue with unsynchronized clocks. No CPU is
periodically resynchronized after the initial pass. A CPU that never
acknowledges is not isolated or marked offline.

### 19. Sleep and join are tick-granular, and join has one waiter

**Status: PARTIAL.** **Source:** [`src/sched.zig`](../../src/sched.zig).

`sleepMs`/`sleepNs` round up to the 100 Hz scheduler tick, so the minimum sleep
is 10 ms and a wakeup can be up to one tick late. A timed `join` uses the same
deadline heap and inherits that granularity. Each task has one
`join_waiter_id`; a concurrent join returns `invalid`. A joinable task retains
its slot and `*Task` pointer until joined or detached, so unreaped tasks can
exhaust the 32-slot table. There is no `join`-all, no process reaping, and no
test for a `detach`/`join` race. Priority ageing prevents starvation but is not
strict priority scheduling and has no priority inheritance.

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
| Per-CPU timer / ticks | **IMPLEMENTED** | LAPIC timer vector 242 on CPU 0 and APs; PIT IRQ0 fallback. |
| Monotonic time base | **IMPLEMENTED** | Invariant TSC or 100 Hz ticks; atomic maximum clamp. |
| Cross-CPU TSC sync | **PARTIAL** | One IPI pass and per-CPU offsets; measured skew, no drift correction. |
| Deadline queue | **IMPLEMENTED** | Per-CPU min-heap; finite deadlines only. |
| Join and priorities | **PARTIAL** | Single waiter; tick-granular timeout; priority ageing. |
| Task migration | **DEFERRED** | Planned for M20. |
| ACPI/MADT discovery | **IMPLEMENTED** | Validated RSDP/XSDT/RSDT/MADT; BSP-only; narrow table coverage. |
| IOAPIC routing | **IMPLEMENTED** | Uncached MMIO, redirection read/write, mask/unmask, IRQ0 delivery test. |
| MSI/MSI-X and PCI routing | **DEFERRED** | Planned for M18; not part of M15. |
| Test coverage | **PARTIAL** | M11-M15 tests added; gaps listed above. |
| Resource limits | **PARTIAL** | 4 GiB PMM, 64 MiB heap, 32 tasks, 8 CPUs. |

## Related documentation

- [Synchronization](../architecture/synchronization.md)
- [Scheduling](../architecture/scheduling.md)
- [SMP bring-up](../architecture/smp.md)
- [Memory management](../architecture/memory.md)
- [CPU and interrupts](../architecture/cpu-interrupts.md)
- [Testing](testing.md)
- [Roadmap](roadmap.md)
