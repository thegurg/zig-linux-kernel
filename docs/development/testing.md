# Testing

**Purpose:** describe the host tests, the QEMU selftest, the fault test, the
harness assertions, and the validation recorded for M12.

**Implementation status:** the test flow is **IMPLEMENTED** and is the required
verification path for each milestone. Coverage gaps are documented below and in
[technical debt](technical-debt.md).

## Test layers

| Layer | Command | What it proves |
| --- | --- | --- |
| Host unit tests | part of `zig build test` | The host harness and the pure Limine binding test run. |
| QEMU selftest | `tools/run.sh <selftest> --test` | Boot, memory, interrupts, per-CPU scheduling, synchronization, FPU, LAPIC/IPIs, concurrent allocation, and TLB-shootdown tests work together. |
| QEMU fault test | `tools/run.sh <fault-test> --test-fault` | The `#PF` gate, `CR2` reporting, and fatal-exception exit path work. |

`zig build test` runs all three. It builds the selftest and fault-test images
with the same optimization mode as the normal build (default `ReleaseSafe`).

## Host unit tests

The host test root is [`src/test_root.zig`](../../src/test_root.zig):

```zig
const std = @import("std");

test {
    _ = @import("limine.zig");
}

test "host test harness works" {
    try std.testing.expectEqual(@as(u32, 42), 40 + 2);
}
```

Importing `limine.zig` from a test block pulls its
`test "base revision marker layout"` into the same test binary. Only pure,
platform-independent modules may be imported there; kernel subsystems are
exercised through QEMU because they depend on x86_64 state and devices. The
host test run currently executes three tests.

## QEMU selftest

The selftest image is built with `exit_after_boot = true`. After boot and SMP
initialization, `kmain` runs the checks in this order.

| Check | Log marker(s) | Behavior |
| --- | --- | --- |
| PMM | `PMM checks passed` | Allocates four pages; checks alignment, range, distinctness, free count, reuse, double-free rejection, misaligned free rejection, out-of-range free rejection, and zero-page rejection. |
| VMM | `VMM checks passed` | Verifies active paging, current PML4, kernel translation, framebuffer translation, HHDM write/read through a mapped page, map/unmap behavior, and misaligned/already-mapped rejection. |
| Heap | `heap checks passed` | Allocates aligned blocks, verifies non-overlap and contents, frees and reuses a block, uses the `std.mem.Allocator` adapter, rejects an oversized allocation, and checks final counters. |
| M1c | `M1c checks passed` | Summarizes the memory layer checks. |
| M2 timer/scheduler | `timer checks passed`, `scheduler checks passed`, `M2 checks passed` | Programs the PIT at 100 Hz, waits for at least 30 ticks while two workers yield/exit, and checks both counters and the finished count. |
| M3 lifecycle | `lifecycle checks passed`, `M3 checks passed` | Creates a third worker in a finished slot and verifies it runs. |
| M4 sleep | `sleep checks passed`, `M4 checks passed` | Sleeps for 5 ticks and checks the deadline elapsed and the worker ran. |
| M5 block/wake | `block checks passed`, `M5 checks passed` | Waits for the worker to block, wakes it explicitly, and checks it ran twice. |
| M6 wait queue | `waitq checks passed`, `M6 checks passed` | Waits for a worker to block on a `WaitQueue`, calls `wakeOne`, and checks it ran twice. |
| M7 timed wait | `timed checks passed`, `M7 checks passed` | Verifies the timeout path without a signal, then the signaled path before the deadline. |
| M8 mutex | `mutex checks passed` | Two workers serialize a critical section across a yield; checks value, completion count, and zero overlap. |
| M8 condition | `cond checks passed`, `M8 checks passed` | A waiter and signaller handshake through a condition variable and associated mutex. |
| M9 FPU | `fpu checks passed`, `M9 checks passed` | Two tasks keep distinct XMM0 patterns across a cooperative yield and interleave. |
| M11 SMP workers | `smp: cpus=<ZIG_KERNEL_SMP>`, `smp: cpus=..., aps=..., online=..., counter=..., expected=..., overlap=0` | Starts the APs, creates a pinned scheduler task per AP, runs the 100,000-iteration-per-CPU spinlock workload on every CPU, and checks online count, counter total, and zero overlap. |
| M11 cross-CPU wake | `smp: cross-cpu wake=1` | A task blocked on CPU 1 is woken from the BSP via a reschedule IPI and completes on CPU 1. |
| M11 AP exception/FPU | `smp: cross-cpu wake=1, ap exception=1, tlb=1, nested locks=1` | An AP task preserves XMM5 across `int3`; `int3` returns. |
| M11 TLB shootdown | `tlb: shootdowns=<n>` | Maps and unmaps a test page after APs are online and checks the shootdown counter increased. |
| M11 nested locks | `nested locks=1` | Nested `IrqSpinLock` guards disable interrupts while held and restore the outer state on release. |
| M11 result | `M11 checks passed` | The scheduler/SMP group completed. |
| M12 concurrent heap | `heap: concurrent allocs=<n>, errors=0` | Every CPU allocates, writes, verifies, and frees blocks concurrently. The count is 1,000 per online CPU (BSP included). |
| M12 IRQ-off TLB | `tlb: irq-off=1` | A CPU disables interrupts, the BSP unmaps a page, and the shootdown completes only after that CPU enables interrupts and services the pending IPI. |
| M12 concurrent TLB | `tlb: irq-off=1, concurrent shootdowns=<n>, errors=0` | Every AP maps and unmaps a private page concurrently; the reported count is the number of shootdowns issued with zero errors. |
| `int3` | `returned from int3`, `M12 checks passed` | Triggers a breakpoint on the BSP and proves the handler resumes. |
| Success | `M12 checks passed` | Exits QEMU successfully. |

The selftest logs diagnostic lines such as:

```text
timer: 30 ticks at 100 Hz
scheduler: worker counters a=..., b=..., finished=2
lifecycle: worker-c=1, finished=3, elapsed=...
sleep: worker-sleep=1, finished=4, elapsed=...
block: worker-block=2, finished=5, elapsed=...
waitq: worker-wait=2, finished=6, elapsed=...
timed: timeout=... ticks, signaled=1, finished=8, elapsed=... ticks
mutex: value=2, done=2, overlap=0, finished=..., elapsed=... ticks
cond: ready=0, waiter=1, signaler=1, signals=1, finished=..., elapsed=... ticks
fpu: done=2, a_ok=1, b_ok=1, interleaved=1, finished=..., elapsed=... ticks
smp: 3 APs online for scheduler tests
smp: cpus=4, aps=3, online=3, counter=400000, expected=400000, overlap=0
tlb: shootdowns=1
smp: cross-cpu wake=1, ap exception=1, tlb=1, nested locks=1
heap: concurrent allocs=4000, errors=0
tlb: irq-off=1, concurrent shootdowns=150, errors=0
```

Timing values vary by host and acceleration mode; the assertions check
conditions rather than exact tick counts except where a minimum is required.

## QEMU fault test

The fault-test image is built with `test_page_fault = true`. After normal boot
and AP release, `kmain` deliberately executes a NULL read:

```zig
asm volatile (
    \\xor %%rax, %%rax
    \\movb (%%rax), %%al
    ::: .{ .rax = true, .memory = true });
```

The #PF handler must print:

```text
[exception] vector 14: #PF
  cr2=0x0
```

and the kernel exits through the failure path, producing QEMU status 35. The
harness accepts status 35 only if both the `vector 14: #PF` and `cr2=0x0` log
lines are present. In this image the APs are already in their scheduler idle
loops, so the fault path runs with active per-CPU scheduler state.

## Harness assertions

### Selftest mode

The harness requires QEMU status 33 and greps for all of these markers. The
expected SMP marker is generated from `ZIG_KERNEL_SMP` (default 4), so the
example below shows the default:

```text
returned from int3
M12 checks passed
M11 checks passed
heap: concurrent allocs=.*errors=0
tlb: irq-off=1
concurrent shootdowns=
M9 checks passed
M8 checks passed
M7 checks passed
M6 checks passed
M5 checks passed
M4 checks passed
M3 checks passed
M2 checks passed
M1c checks passed
PMM checks passed
VMM checks passed
heap checks passed
timer checks passed
scheduler checks passed
lifecycle checks passed
sleep checks passed
block checks passed
waitq checks passed
timed checks passed
mutex checks passed
cond checks passed
fpu checks passed
smp: cpus=4
cross-cpu wake=1
ap exception=1
nested locks=1
smp checks passed
```

If QEMU exits 33 but a marker is missing, the harness exits 1 with
`selftest exited successfully but the expected log is missing`.

### Fault-test mode

The harness requires QEMU status 35 and the `#PF`/`CR2` markers described above.
A status of 124 is reported as a timeout; any other status is unexpected.

### Exit-status handling

| Status | Selftest | Fault test |
| --- | --- | --- |
| 33 | Accepted only with all log markers. | Unexpected. |
| 35 | Reported as a kernel panic. | Accepted only with the #PF markers. |
| 124 | Reported as a timeout. | Reported as a timeout. |
| Other | Unexpected status. | Unexpected status. |

The test modes time out after 90 seconds.

## Recorded validation

M12 validation ran the full matrix:

- `zig build` (default ReleaseSafe): passed;
- default KVM `zig build test` (`SMP=4`): passed;
- TCG `ZIG_KERNEL_NO_KVM=1 zig build test`: passed;
- `ZIG_KERNEL_SMP=2 zig build test`: passed;
- `ZIG_KERNEL_SMP=1 zig build test`: passed;
- `zig build -Doptimize=Debug test`: passed.

The default KVM run reported:

```text
smp: cpus=4, aps=3, online=3, counter=400000, expected=400000, overlap=0
tlb: shootdowns=1
smp: cross-cpu wake=1, ap exception=1, tlb=1, nested locks=1
selftest: M11 checks passed
heap: concurrent allocs=4000, errors=0
tlb: irq-off=1, concurrent shootdowns=150, errors=0
selftest: M12 checks passed
selftest: exiting QEMU
```

With `ZIG_KERNEL_SMP=2`, the heap test reported 2,000 allocations and 50
shootdowns. With `ZIG_KERNEL_SMP=1`, the AP-only tests were skipped and the BSP
completed 1,000 allocations.

`zig fmt --check build.zig src` and `git diff --check` were run before the M12
commit. Earlier M10, pre-M11, and M11 validation remains in
[SMP](../architecture/smp.md#recorded-validation) and the roadmap.

## Coverage gaps

- There is no AP NMI test. AP `int3` and FPU-state preservation are covered.
- The M12 tests cover a target with interrupts disabled and several concurrent
  shootdowns, but not a CPU that never re-enables interrupts.
- The SMP timer path is not exercised: `selftestSmp` masks IRQ0 before running
  the M11/M12 tests, and APs have no timer. AP sleep/timeout wakeups are
  therefore not covered end-to-end.
- There is no cross-CPU mutex/condition stress test; the cross-CPU wake test
  covers the wait-queue/IPI path.
- The concurrent heap test does not force PMM exhaustion or page-table
  allocation failure.
- Debug builds are validated by running the same test flow with
  `-Doptimize=Debug`, but there is no separate debug-only test suite.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Host test harness | **IMPLEMENTED** | Harness plus Limine marker test; three tests total. |
| QEMU selftest | **IMPLEMENTED** | Checks M1c-M12 behavior, AP scheduling, IPIs, concurrent allocation, TLB hardening, and `int3`. |
| QEMU fault test | **IMPLEMENTED** | Verifies #PF and CR2 with APs online. |
| Log-marker assertions | **IMPLEMENTED** | Marker list plus dynamic `smp: cpus=<N>` and M11/M12 test results. |
| Dynamic SMP assertion | **IMPLEMENTED** | Derived from `ZIG_KERNEL_SMP`; verified with 1, 2, and 4 CPUs. |
| AP exception/FPU test | **IMPLEMENTED** | `int3` on CPU 1 with XMM5 preservation. |
| TLB-shootdown test | **IMPLEMENTED** | Counter check, IRQ-off target, and concurrent shootdowns. |
| Nested lock test | **IMPLEMENTED** | Nested `IrqSpinLock` guards. |
| Cross-CPU wake test | **IMPLEMENTED** | BSP wakes a CPU 1 task. |
| Concurrent heap test | **IMPLEMENTED** | All CPUs allocate/write/verify/free concurrently. |
| AP timer / NMI tests | **PLANNED** | APs have no timer; NMI is not tested. |
| Allocator failure-path test | **PLANNED** | No PMM-exhaustion or mapping-failure test. |

## Related documentation

- [Building](building.md)
- [Technical debt](technical-debt.md)
- [Roadmap](roadmap.md)
- [Scheduling](../architecture/scheduling.md)
- [Synchronization](../architecture/synchronization.md)
- [SMP bring-up](../architecture/smp.md)
