# Testing

**Purpose:** describe the host tests, the QEMU selftest, the fault test, the
harness assertions, and the results recorded for M10.

**Implementation status:** the test flow is **IMPLEMENTED** and is the required
verification path for each milestone. Coverage gaps are documented below and in
[technical debt](technical-debt.md).

## Test layers

| Layer | Command | What it proves |
| --- | --- | --- |
| Host unit tests | part of `zig build test` | The host test harness runs. Current coverage is a trivial pure test. |
| QEMU selftest | `tools/run.sh <selftest> --test` | Boot, memory, interrupts, scheduler, synchronization, FPU, and SMP bring-up work together. |
| QEMU fault test | `tools/run.sh <fault-test> --test-fault` | The `#PF` gate, `CR2` reporting, and fatal-exception exit path work. |

`zig build test` runs all three. It builds the selftest and fault-test images
with the same optimization mode as the normal build (default `ReleaseSafe`).

## Host unit tests

The host test root is [`src/test_root.zig`](../../src/test_root.zig):

```zig
const std = @import("std");

test "host test harness works" {
    try std.testing.expectEqual(@as(u32, 42), 40 + 2);
}
```

Only pure, platform-independent modules may be imported there. Kernel
subsystems are exercised through QEMU because they depend on x86_64 state and
devices.

`src/limine.zig` contains a `test "base revision marker layout"` block, but that
module is not currently part of the host test root, so the block is not wired
into `zig build test`.

## QEMU selftest

The selftest image is built with `exit_after_boot = true`. After boot and SMF
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
| SMP | `smp: cpus=4`, `smp checks passed` | Releases the APs, runs the 100,000-iteration-per-CPU spinlock workload, and checks online count, counter total, and zero overlap. |
| `int3` | `returned from int3`, `M10 checks passed` | Triggers a breakpoint and proves the handler resumes. |
| Success | `M10 checks passed` | Exits QEMU successfully. |

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
smp: cpus=4, aps=3, online=3, counter=400000, expected=400000, overlap=0
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
lines are present.

## Harness assertions

### Selftest mode

The harness requires QEMU status 33 and greps for all of these markers:

```text
returned from int3
M10 checks passed
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

M10 validation recorded:

- default KVM `zig build test`: passed;
- three repeated KVM runs: stable at
  `counter=400000, expected=400000, overlap=0`;
- TCG run: passed;
- `-Doptimize=Debug` run: passed;
- normal kernel run: version `0.13.0-m10`, `cpus=4, aps=3`, and
  `3 APs online, parked`;
- `zig fmt --check build.zig src`: passed;
- `git diff --check`: passed.

The documentation audit later re-ran the default KVM `zig build test` and
observed exit code 0 with no test failures.

## Coverage gaps

- The host test root contains only a trivial test; the Limine test block is not
  wired in.
- There is no automated test for AP exceptions, NMI handling, or AP FPU state.
- There is no test for TLB shootdown because it is not implemented.
- There is no test for nested or cross-CPU `IrqSpinLock` acquisition; the
  shared-flags defect is currently untested and latent.
- The harness hardcodes `smp: cpus=4`, so non-default `ZIG_KERNEL_SMP` values
  can cause false smoke failures.
- There is no test that starts a task on an AP or wakes a task across CPUs,
  because the scheduler is BSP-only.
- Debug builds are validated by running the same test flow with
  `-Doptimize=Debug`, but there is no separate debug-only test suite.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Host test harness | **IMPLEMENTED** | Trivial coverage only. |
| QEMU selftest | **IMPLEMENTED** | Checks M1c-M10 behavior and `int3`. |
| QEMU fault test | **IMPLEMENTED** | Verifies #PF and CR2. |
| Log-marker assertions | **IMPLEMENTED** | Hardcoded marker list. |
| Dynamic SMP assertion | **PLANNED** | `cpus=4` is hardcoded. |
| AP exception/FPU tests | **PLANNED** | No AP exception test yet. |
| TLB-shootdown tests | **PLANNED** | Feature not implemented. |
| Nested/cross-CPU lock tests | **PLANNED** | Needed after the `IrqSpinLock` fix. |

## Related documentation

- [Building](building.md)
- [Technical debt](technical-debt.md)
- [Roadmap](roadmap.md)
- [Scheduling](../architecture/scheduling.md)
- [Synchronization](../architecture/synchronization.md)
- [SMP bring-up](../architecture/smp.md)
