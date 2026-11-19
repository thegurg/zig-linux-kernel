# Testing

**Purpose:** describe the host tests, the QEMU selftest, the fault test, the
fallback boot test, the harness assertions, and the validation recorded for M14.

**Implementation status:** the test flow is **IMPLEMENTED** and is the required
verification path for each milestone. Coverage gaps are documented below and in
[technical debt](technical-debt.md).

## Test layers

| Layer | Command | What it proves |
| --- | --- | --- |
| Host unit tests | part of `zig build test` | The host harness and the pure Limine binding test run. |
| QEMU selftest | `tools/run.sh <selftest> --test` | Boot, memory, interrupts, per-CPU scheduling, per-CPU timers, ACPI/IOAPIC delivery, synchronization, FPU, LAPIC/IPIs, concurrent allocation, and TLB-shootdown tests work together. |
| QEMU fault test | `tools/run.sh <fault-test> --test-fault` | The `#PF` gate, `CR2` reporting, and fatal-exception exit path work. |
| QEMU fallback boot | `tools/run.sh <fallback> --test-boot` | A `force_pit` image reaches the legacy PIT timer path and the idle transition. |

`zig build test` runs all four. It builds the selftest, fault-test, and fallback
images with the same optimization mode as the normal build (default
`ReleaseSafe`).

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
| M13 AP sleep | `timer: per-cpu ticks=<n>, sleepers=<aps>, ...` | One sleeper per AP records its CPU's tick counter, sleeps for 3 ticks, and records the delta; the selftest requires the summed deltas to reach 3 ticks per AP, proving the AP LAPIC timer fires and wakes local deadlines. |
| M13 AP preemption | `preempted=1` | Two CPU-bound tasks pinned to CPU 1 each observe the other's counter while both are still running, which requires timer-driven preemption. |
| M13 result | `timer: per-cpu ticks=..., sleepers=..., preempted=1`, `M13 checks passed` | The per-CPU timer group completed with the expected sleeper count and preemption. |
| M14 ACPI/MADT | `acpi: madt revision=...`, `acpi: madt cpus matched limine=...` | ACPI is ready, the MADT CPU count matches Limine, and the BSP LAPIC ID is present. |
| M14 ISO route | `m14: irq0 gsi=..., polarity=..., trigger=..., overridden=...` | IRQ0 is resolved through the MADT ISO rather than a hardcoded GSI. |
| M14 IOAPIC readback | `ioapic: id=... version=... entries=... gsi_base=...`, `m14: ioapic entry low=... high=...` | The IOAPIC is mapped and the redirection entry has vector 242, the BSP destination, the ISO polarity/trigger, and no mask bit. |
| M14 IOAPIC delivery | `m14: ioapic ticks=5` | PIT IRQ0 routed through the IOAPIC reaches vector 242 and is acknowledged with a LAPIC EOI; the pin is then masked and checked. |
| M14 CPU 0 timer | `timer: source=lapic`, `m14: cpu0 sleep ticks=5`, `m14: cpu0 preempted=1` | CPU 0's LAPIC timer wakes a local sleeper and preempts two CPU-bound tasks. |
| M14 result | `M14 checks passed` | The ACPI/IOAPIC/CPU 0 timer group completed. |
| `int3` | `returned from int3`, `M14 checks passed` | Triggers a breakpoint on the BSP and proves the handler resumes. |
| Success | `M14 checks passed` | Exits QEMU successfully. |

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
timer: LAPIC 625396 counts per tick
timer: per-cpu ticks=9, sleepers=3, preempted=1
acpi: madt revision=3 cpus=4/4 ioapics=1 isos=5 lapic=0xfee00000
ioapic: id=0 version=17 entries=24 gsi_base=0 address=0xfec00000
acpi: madt cpus matched limine=4, bsp_lapic_id=0
m14: irq0 gsi=2, polarity=active_high, trigger=edge, overridden=1
m14: ioapic entry low=0xf2 high=0x0
m14: ioapic ticks=5
timer: source=lapic
m14: cpu0 sleep ticks=5
m14: cpu0 preempted=1 a=2339567 b=1 ticks=3
```

The `preempt_a`/`preempt_b`/`preempt_ticks` and `m14` counter fields are
diagnostics only and are not asserted. Timing values vary by host and
acceleration mode; the assertions check conditions rather than exact tick counts
except where a minimum is required.

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
M16 checks passed
M15 checks passed
M14 checks passed
M13 checks passed
M12 checks passed
M11 checks passed
m16: user write ok
m16: user sleep ok
m16: user exit status=42
m16: user null fault status=-15
m16: isolation data a=161 b=178
m16: isolation extra holder=126 probe=-15
m16: preemption counters=[0-9]+,[0-9]+ ticks=[0-9]+
m16: user badptr rejected
m16: user badptr status=0
m16: aspace created=9 destroyed=9
M17 checks passed
m17: proc argv=m17proc,basic env=M17=1
m17: argv status=42 pid=[0-9]+ gen=[0-9]+
m17: concurrent statuses=42,43
m17: wait timeout=timeout retry=exited/43
m17: generation advanced=1 stale=invalid
m17: nx fault status=-15 sibling=44
m17: guard fault status=-15 sibling=44
m17: bad loads rejected=4
m17: reclaim aspaces created=[0-9]+ destroyed=[0-9]+ free_pages_match=1
m17: process table slots=0 live=0 spawned=[0-9]+ reaped=[0-9]+
m15: tsc supported=.* invariant=.* calibrated=.* hz=.* source=.*
m15: rate_ns=.* expected_ns=.* tolerance_ns=
m15: cross-cpu skew_ns=.* sleep_ns=.* tolerance_ns=   (or "m15: cross-cpu skipped cpus=1")
m15: deadlines pushes=.* pops=.*
m15: join joined=joined/42 already=already_finished/7 twice=invalid timeout=timeout retry=joined/9
m15: priority order=2,1,0
m15: fallback source=ticks monotonic=1
acpi: madt revision=.* cpus=.* ioapics=.* isos=
ioapic: id=.* version=.* entries=.* gsi_base=
acpi: madt cpus matched limine=
m14: irq0 gsi=.* polarity=.* trigger=.* overridden=
m14: ioapic ticks=
m14: cpu0 sleep ticks=
m14: cpu0 preempted=1
timer: source=lapic
timer: per-cpu ticks=.*sleepers=.*preempted=1
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

### Fallback-boot mode

The fallback image is built with `force_pit = true`. The normal kernel idles
after boot, so the harness runs QEMU with a 20-second timeout and then accepts
the run only if the serial log contains both:

```text
timer: source=pit
scheduler: boot task exiting to idle
```

A missing marker, or any other failure before the timeout, exits 1.

### Exit-status handling

| Status | Selftest | Fault test | Fallback boot |
| --- | --- | --- | --- |
| 33 | Accepted only with all log markers. | Unexpected. | Unexpected. |
| 35 | Reported as a kernel panic. | Accepted only with the #PF markers. | Reported as a kernel panic. |
| 124 | Reported as a timeout. | Reported as a timeout. | Expected; accepted only with the fallback markers. |
| Other | Unexpected status. | Unexpected status. | Unexpected status. |

The selftest and fault-test modes time out after 90 seconds. The fallback-boot
mode times out after 20 seconds because the guest is expected to stay idle.

## Recorded validation

### M17 validation

M17 validation ran the full matrix:

- `zig build` (default ReleaseSafe): passed;
- default KVM `zig build test` (`SMP=4`): passed;
- TCG `ZIG_KERNEL_NO_KVM=1 zig build test`: passed;
- `ZIG_KERNEL_SMP=2 zig build test`: passed;
- `ZIG_KERNEL_SMP=1 zig build test`: passed;
- `zig build -Doptimize=Debug test`: passed.

The default KVM run reported:

```text
selftest: checking M17 ELF loading and process lifecycle
m17: proc argv=m17proc,basic env=M17=1
m17: argv status=42 pid=1 gen=2
m17: proc argv=m17proc,basic env=M17=1
m17: concurrent statuses=42,43
m17: wait timeout=timeout retry=exited/43
m17: generation advanced=1 stale=invalid
m17: proc nx attempt
m17: nx fault status=-15 sibling=44
m17: proc guard attempt
m17: guard fault status=-15 sibling=44
m17: bad loads rejected=4
m17: reclaim aspaces created=10 destroyed=10 free_pages_match=1
m17: process table slots=0 live=0 spawned=10 reaped=10
selftest: M17 checks passed
```

The TCG, `SMP=2`, `SMP=1`, and Debug runs produced the same markers. The process
tests run on CPU 0, so `SMP=1` exercises the same path without APs. The NX test
depends on `EFER.NXE` being enabled on the executing CPU; `SMP=2` and `SMP=4`
runs also exercise the AP-side `enableNx` call during bring-up, though the M17
processes themselves remain pinned to CPU 0.

The M17 assertions require all M11-M16 markers to remain present. The four
rejected loads are a 64-byte non-ELF image, a byte-swapped `EM_386` machine
field, a program header rewritten to overlap the text segment, and a 20,000-byte
argument that cannot fit in the four-page stack. `zig fmt --check build.zig src`
and `git diff --check` passed before the commit. The checked-in
`src/user/proc.elf` is generated by `tools/build-user.sh`.

### M16 validation

M16 validation ran the full matrix:

- `zig build` (default ReleaseSafe): passed;
- default KVM `zig build test` (`SMP=4`): passed;
- TCG `ZIG_KERNEL_NO_KVM=1 zig build test`: passed;
- `ZIG_KERNEL_SMP=2 zig build test`: passed;
- `ZIG_KERNEL_SMP=1 zig build test`: passed;
- `zig build -Doptimize=Debug test`: passed.

The default KVM run reported:

```text
selftest: checking M16 ring 3 and address spaces
m16: user write ok
m16: user sleep ok
m16: user exit status=42
m16: user null fault status=-15
m16: isolation data a=161 b=178
m16: isolation extra holder=126 probe=-15
m16: preemption counters=36074295,43085469 ticks=3
m16: user badptr rejected
m16: user badptr status=0
m16: aspace created=9 destroyed=9
selftest: M16 checks passed
selftest: exiting QEMU
```

The TCG, `SMP=2`, `SMP=1`, and Debug runs produced the same markers with
different preemption counters. The user tests are pinned to CPU 0, so
`SMP=1` exercises the same code path without APs. The fault test still reports
`vector 14: #PF` and `cr2=0x0`; the fallback image still reaches
`timer: source=pit` and the idle transition.

The M16 assertions also require all M11-M15 markers to remain present.
`zig fmt --check build.zig src` and `git diff --check` passed before the commit.
The checked-in `src/user/demo.elf` is generated by `tools/build-user.sh`; rerun
that script after editing `demo.S` or `demo.ld`.

### M15 validation

M15 validation ran the full matrix:

- `zig build` (default ReleaseSafe): passed;
- default KVM `zig build test` (`SMP=4`): passed;
- TCG `ZIG_KERNEL_NO_KVM=1 zig build test`: passed;
- `ZIG_KERNEL_SMP=2 zig build test`: passed;
- `ZIG_KERNEL_SMP=1 zig build test`: passed;
- `zig build -Doptimize=Debug test`: passed.

The KVM harness now selects `-cpu host,+invtsc` when the host advertises
`nonstop_tsc`, so the TSC clocksource is exercised instead of silently falling
back. The default run reported:

```text
time: tsc=1 invariant=1 calibrated=1 hz=2501183000 source=tsc reason=none
time: sync cpus=4 skew=133473 ns
m15: tsc supported=1 invariant=1 calibrated=1 hz=2501183000 source=tsc reason=none
m15: rate_ns=198760384 expected_ns=200000000 tolerance_ns=40000000
m15: sync cpus=4 skew=190817 ns
m15: cross-cpu skew_ns=48841 sleep_ns=49120356 tolerance_ns=50000000
m15: deadlines pushes=1 pops=1 sleep_ns=49930354 ticks=5
m15: join joined=joined/42 already=already_finished/7 twice=invalid timeout=timeout retry=joined/9
m15: priority order=2,1,0 count=3
m15: fallback source=ticks monotonic=1 sleep_ns=50000000
selftest: M15 checks passed
selftest: exiting QEMU
```

The TCG run reported `time: tsc=1 invariant=0 calibrated=0 hz=0 source=ticks
reason=non_invariant` and still passed every M15 check, proving the fallback
clocksource keeps the same API and monotonicity. With `ZIG_KERNEL_SMP=1` there
is no AP, so the cross-CPU probe logs `m15: cross-cpu skipped cpus=1`; the
harness accepts that marker in place of the skew/sleep line. The `force_pit`
image reported `time: tsc=1 invariant=1 calibrated=0 hz=0 source=ticks
reason=forced` and `timer: source=pit, 100 Hz, IRQ0 unmasked`; `--test-boot`
accepted the expected idle timeout.

The M15 assertions also require the M11-M14 markers to remain present.
`zig fmt --check build.zig src` and `git diff --check` passed before the commit.

The observed sync spread (roughly 50-200 microseconds under KVM) is the IPI
sampling spread, not a pure oscillator skew. The cross-CPU test tolerance is
50 ms, deliberately loose for emulated and loaded hosts.

### M14 validation

M14 validation ran the full matrix:

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
timer: per-cpu ticks=9, sleepers=3, preempted=1 (a=1, b=2082676, ticks=1)
selftest: M13 checks passed
acpi: madt revision=3 cpus=4/4 ioapics=1 isos=5 lapic=0xfee00000
ioapic: id=0 version=17 entries=24 gsi_base=0 address=0xfec00000
acpi: madt cpus matched limine=4, bsp_lapic_id=0
m14: irq0 gsi=2, polarity=active_high, trigger=edge, overridden=1
m14: ioapic entry low=0xf2 high=0x0
m14: ioapic ticks=5
timer: source=lapic
m14: cpu0 sleep ticks=5
m14: cpu0 preempted=1 a=2339567 b=1 ticks=3
selftest: M14 checks passed
selftest: exiting QEMU
```

The `force_pit` image booted through `timer: source=pit, 100 Hz, IRQ0 unmasked`
and `scheduler: boot task exiting to idle`; the `--test-boot` harness accepted
the 20-second idle timeout. With `ZIG_KERNEL_SMP=2`, one AP sleeper reported
ticks and the preemption test passed. With `ZIG_KERNEL_SMP=1`, the AP-only timer
part was skipped, while the M14 CPU 0 sleeper and preemption tests still ran.

`zig fmt --check build.zig src` and `git diff --check` were run before the M14
commit. Earlier M10-M13 validation remains in
[SMP](../architecture/smp.md#recorded-validation) and the roadmap.

## Coverage gaps

- There is no AP NMI test. AP `int3` and FPU-state preservation are covered.
- The M12 tests cover a target with interrupts disabled and several concurrent
  shootdowns, but not a CPU that never re-enables interrupts.
- M14 exercises ISA IRQ0 only. Other ISAs, level-triggered ISOs, multiple
  IOAPICs, and general PCI interrupt routing are not tested.
- There is no test that ACPI tables are rejected when a checksum or length is
  deliberately corrupted; validation paths are exercised only by the real
  firmware tables.
- There is no cross-CPU mutex/condition stress test; the cross-CPU wake test
  covers the wait-queue/IPI path.
- The concurrent heap test does not force PMM exhaustion or page-table
  allocation failure.
- M15 does not test a non-invariant TSC on a real host with a working TSC; the
  fallback is exercised by TCG and by the runtime source-switch hook.
- The TSC sync path has no test for a target that never acknowledges the IPI or
  for a host whose TSC offsets exceed the 50 ms timestamp tolerance.
- Join coverage is single-waiter only; there is no test for `detach` racing
  with `join`, nor for reusing a joined slot under contention.
- M17 exercises one three-segment `ET_EXEC` fixture. It verifies malformed
  images, an overlapping segment, a wrong machine, and an oversized argument,
  but does not cover every header field, a huge number of program headers,
  `p_memsz > p_filesz` with uninitialised BSS beyond the file data, PIE, or a
  dynamic loader.
- NX and guard-page faults are tested on CPU 0 only. There is no test that a
  user process runs on an AP after that AP enables NXE, and no test for stack
  growth on a guard-page fault (growth is not implemented).
- `spawn`/`wait`/`reap` are tested sequentially from one kernel task. There is
  no concurrent spawn/wait stress, no `wait` from two kernel tasks on one
  process, and no process-table exhaustion test.
- Failed loads are checked through four rejections and the address-space/free
  page counters; the test does not force PMM exhaustion partway through a
  multi-segment mapping.
- The user isolation test covers two address spaces at one virtual address; it
  does not sweep a range of addresses or stress address-space creation under
  PMM pressure.
- User syscalls are tested through the fixture only; there is no fuzzing of the
  syscall frame or of arbitrary user pointers beyond one unmapped and one
  non-canonical address.
- Debug builds are validated by running the same test flow with
  `-Doptimize=Debug`, but there is no separate debug-only test suite.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Host test harness | **IMPLEMENTED** | Harness plus Limine marker test; three tests total. |
| QEMU selftest | **IMPLEMENTED** | Checks M1c-M17 behavior, AP scheduling, IPIs, per-CPU timers, ACPI/IOAPIC delivery, concurrent allocation, TLB hardening, timekeeping, join, priorities, ring 3, address-space isolation, user copies, general ELF loading, W^X/NX, argv/envp, process lifecycle, and `int3`. |
| QEMU fault test | **IMPLEMENTED** | Verifies #PF and CR2 with APs online. |
| QEMU fallback boot test | **IMPLEMENTED** | `force_pit` image reaches the PIT timer path and idle transition. |
| Log-marker assertions | **IMPLEMENTED** | Marker list plus dynamic `smp: cpus=<N>` and M11-M17 test results. |
| Dynamic SMP assertion | **IMPLEMENTED** | Derived from `ZIG_KERNEL_SMP`; verified with 1, 2, and 4 CPUs. |
| AP exception/FPU test | **IMPLEMENTED** | `int3` on CPU 1 with XMM5 preservation. |
| TLB-shootdown test | **IMPLEMENTED** | Counter check, IRQ-off target, and concurrent shootdowns. |
| Nested lock test | **IMPLEMENTED** | Nested `IrqSpinLock` guards. |
| Cross-CPU wake test | **IMPLEMENTED** | BSP wakes a CPU 1 task. |
| Concurrent heap test | **IMPLEMENTED** | All CPUs allocate/write/verify/free concurrently. |
| AP timer / sleep test | **IMPLEMENTED** | One LAPIC-timer sleeper per AP; local deadline wakeup. |
| AP timer preemption test | **IMPLEMENTED** | Two CPU-bound CPU 1 tasks must observe each other. |
| ACPI/MADT/IOAPIC test | **IMPLEMENTED** | ISO-resolved IRQ0, redirection readback, end-to-end delivery, mask check. |
| CPU 0 LAPIC timer test | **IMPLEMENTED** | Local sleeper and two preempted CPU-bound tasks. |
| TSC detection/calibration test | **IMPLEMENTED** | Reports CPUID bits, rate, and source; checks the 200 ms rate window. |
| Cross-CPU time test | **IMPLEMENTED** | TSC sync, per-AP monotonic samples, barrier skew, and `sleepMs` on every AP. |
| Deadline-queue test | **IMPLEMENTED** | Push/pop counters and a timed sleep of at least five ticks. |
| Join test | **IMPLEMENTED** | Success/failure statuses, already-finished, repeated join, and timeout/retry. |
| Priority test | **IMPLEMENTED** | Three tasks must run high, normal, low. |
| Fallback clocksource test | **IMPLEMENTED** | Runtime switch to ticks, monotonicity, and a bounded sleep. |
| User syscall test | **IMPLEMENTED** | Serial write, getpid/yield/sleepMs, exit status 42. |
| User fault test | **IMPLEMENTED** | Ring-3 NULL dereference terminates only that task with `-15`. |
| Address-space isolation test | **IMPLEMENTED** | Two private data pages plus an extra-page probe across address spaces. |
| User pointer validation test | **IMPLEMENTED** | Unmapped and non-canonical pointers return `-EFAULT` without a panic. |
| User preemption test | **IMPLEMENTED** | Two busy ring-3 tasks advance under the LAPIC timer. |
| Address-space teardown test | **IMPLEMENTED** | Created and destroyed counters match at 9/9 for M16. |
| General ELF loader test | **IMPLEMENTED** | Validated `ET_EXEC` load; bad header, machine, overlap, and stack overflow rejected. |
| W^X/NX test | **IMPLEMENTED** | RW+NX data fetch faults with `-15`; only the offending process dies. |
| Stack guard-page test | **IMPLEMENTED** | Write to the unmapped page below the stack faults with `-15`. |
| argv/envp test | **IMPLEMENTED** | The fixture prints the received `argv`/`envp` and exits 42. |
| Process lifecycle test | **IMPLEMENTED** | Concurrent spawn/wait, timeout and retry, generations, reaping, and empty table. |
| Process reclaim test | **IMPLEMENTED** | Address-space and free-page counts match after the run. |
| AP NMI test | **PLANNED** | NMI is not tested. |
| Allocator failure-path test | **PLANNED** | No PMM-exhaustion or mapping-failure test. |

## Related documentation

- [Building](building.md)
- [Technical debt](technical-debt.md)
- [Roadmap](roadmap.md)
- [Scheduling](../architecture/scheduling.md)
- [Synchronization](../architecture/synchronization.md)
- [SMP bring-up](../architecture/smp.md)
