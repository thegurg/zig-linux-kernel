# SMP bring-up and per-CPU scheduling

**Purpose:** describe the Limine multiprocessor protocol path, application
processor entry, per-CPU state, LAPIC/x2APIC setup, IPIs, and the M11 SMP tests.

**Implementation status:** Limine MP bring-up, per-CPU stacks/TSS, pre-Zig AP
setup, the atomic spinlock stress test, per-CPU scheduler entry, LAPIC and
x2APIC initialisation, reschedule and TLB IPIs, cross-CPU wakeups, TLB
shootdown, and AP exception/FPU-state handling are **IMPLEMENTED**. The timer
and interrupt routing remain PIC/PIT-based and BSP-only; APs receive IPIs but no
timer interrupt. See [technical debt](../development/technical-debt.md).

## Scope

M11 brings secondary CPUs into the scheduler. Every online CPU now has:

- a per-CPU `cpu.PerCpu` block addressed through the GS base MSR;
- its own scheduler idle task, current task, scan cursor, and pending
  sleep/wait requests;
- LAPIC initialisation and a spurious-vector gate;
- IPI dispatch for reschedule (vector 240) and TLB shootdown (vector 241);
- interrupt-time FPU state reachable at `%gs:0`.

Tasks are pinned to the CPU chosen at creation (`sched.createOn`). There is no
load balancing or task migration. The BSP continues to own IRQ0 and the global
tick counter, so deadline wakeups are scanned on the BSP and delivered to other
CPUs by reschedule IPI.

The kernel still does **not** provide an APIC timer, IOAPIC routing, AP
preemption by timer, or per-CPU tick counters. Allocator locking is partial: the
PMM, VMM, console, and serial paths are locked; the heap is not.

## Limine MP protocol

The request is defined in [`src/limine.zig`](../../src/limine.zig):

```zig
pub const MpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: u64,
    extra_argument: u64,
};

pub const MpResponse = extern struct {
    revision: u64,
    flags: u32,
    bsp_lapic_id: u32,
    cpu_count: u64,
    cpus: [*]?*MpInfo,
};

pub const mp_x2apic: u32 = 1 << 0;
```

`mp_request.flags = 0`. Limine bootstraps and parks every AP when the request is
present. The kernel publishes a per-CPU `goto_address` to release an AP; until
then, the bootloader keeps it parked. `extra_argument` is kernel-owned and is
used to pass the AP's `ApContext`. The assembly stub reads it at offset 24.

The `mp_x2apic` response flag is recorded in `smp.Stats.x2apic`, but the
authoritative mode is read from `IA32_APIC_BASE` during LAPIC setup.

## Per-CPU context and stacks

[`src/smp.zig`](../../src/smp.zig) defines a C-layout descriptor:

```zig
pub const ApContext = extern struct {
    stack_top: u64 = 0,
    index: u32 = 0,
    cpu_index: u32 = 0,
    lapic_id: u32 = 0,
    gdt_cpu: u32 = 0,
    info: u64 = 0,
};
```

- `max_cpus = gdt.max_cpus = 8`.
- Each AP gets a private 16 KiB boot stack in `ap_stacks` and another 16 KiB
  stack in `ap_task_stacks` for its scheduler worker.
- `stack_top` must stay at offset 0 because `ap_entry` loads `RSP` from it
  before calling Zig. A compile-time offset check enforces this.
- `cpu_index = ap_index + 1` and `gdt_cpu = ap_index + 1`, because CPU 0 is the
  BSP. The corresponding TSS selector is `0x18 + gdt_cpu * 0x10`.
- `info` stores the address of Limine's `MpInfo` for that processor.

`ap_kernel_cr3` is an exported `u64` written once during `smp.init()` with
`vmm.currentPml4()`. The AP stub loads it before calling Zig code.

### Per-CPU scheduler block

[`src/arch/x86_64/cpu.zig`](../../src/arch/x86_64/cpu.zig) defines:

```zig
pub const PerCpu = extern struct {
    fpu_state: u64 = 0,  // offset 0: %gs:0
    index: u32 = 0,      // offset 8: %gs:8
    lapic_id: u32 = 0,   // offset 12: %gs:12
    online: u64 = 0,
};
```

`extern struct` is required: Zig's automatic layout originally reordered these
fields, so `%gs:8`/`%gs:12` read the wrong data and every AP appeared to be CPU
0. Compile-time `@offsetOf` checks now guard the layout.

`cpu.initPerCpu(index, lapic_id)` fills the block, points `%gs:0` at a scratch
FXSAVE area, and writes `IA32_GS_BASE`. The scheduler later replaces `%gs:0` with
the current task's FPU area. `cpu.currentIndex()` and `cpu.lapicId()` are
single-instruction GS-relative loads.

## Initialization

`smp.init()`:

1. obtains Limine's MP response, returning `NoMpResponse` if absent;
2. rejects more than `max_cpus` processors with `TooManyCpus`;
3. records the CPU count, BSP LAPIC ID, and x2APIC flag;
4. iterates the response's CPU list, skips the BSP, and fills one `ApContext`
   per AP;
5. writes each context address into that CPU's `MpInfo.extra_argument`;
6. sets `stats.aps` and marks the subsystem initialized.

It does not release any AP. A failure is logged by `kmain` but does not abort
boot.

## Releasing APs

`smp.start()`:

1. refuses if not initialized or already started;
2. sets `started`, updates statistics, and resets `online_count` and
   `parked_count`;
3. takes the address of `ap_entry`;
4. for each AP, refreshes `extra_argument` and atomically stores the entry
   address into `info.goto_address` with sequential consistency.

`smp.waitOnline()` spins until `online_count >= stats.aps`, with a limit of
50,000,000 `pause` iterations. `smp.parkedCount()` remains available for the
error path: an AP that cannot initialise its LAPIC or scheduler state increments
it before halting.

## AP entry path

[`src/arch/x86_64/smp_entry.S`](../../src/arch/x86_64/smp_entry.S) is the
assembly entry:

1. load `extra_argument` (offset 24) from the `limine_mp_info` in `RDI` into
   `RAX`;
2. move the `limine_mp_info` pointer into `RSI` (second argument);
3. load the private stack top from the first field of the context (`RSP`);
4. move the context pointer into `RDI` (first argument);
5. enable SSE: clear `CR0.EM`/`CR0.TS`, set `CR0.MP`/`CR0.NE`, set
   `CR4.OSFXSR`/`CR4.OSXMMEXCPT`, and execute `fninit`;
6. set `CR0.WP` so ring-0 writes honor read-only mappings;
7. clear `CR4.PGE`, load `ap_kernel_cr3` into `CR3`, and restore the original
   `CR4` value; clearing PGE flushes global TLB entries that a `CR3` write
   alone would preserve;
8. execute `cld`;
9. call `ap_main`.

Steps 5-7 happen in assembly before any Zig code, because `CR0`/`CR4` are
per-CPU and the compiler may emit SSE as soon as `ap_main` starts. If `ap_main`
returns, the stub halts in a `cli; hlt` loop.

`ap_main(ctx, info)` in [`src/smp.zig`](../../src/smp.zig):

1. installs `ctx.stack_top` as the CPU's TSS `RSP0`;
2. loads the shared GDT and this CPU's TSS with `gdt.load(ctx.gdt_cpu)`;
3. loads the shared IDT with `idt.load()`;
4. calls `cpu.initPerCpu(ctx.cpu_index, ctx.lapic_id)` **before** any code that
   can fault, so `%gs:0` is always valid;
5. enables this CPU's LAPIC (`lapic.init()`);
6. calls `sched.initCpu(ctx.cpu_index, ctx.lapic_id)`, which creates the AP's
   idle task, marks the CPU online in `sched.online_mask`, and points `%gs:0` at
   the idle task's FPU area;
7. increments `online_count`;
8. calls `sched.enterScheduler()`, which resumes the idle task's initial frame
   with interrupts enabled.

If LAPIC or scheduler setup fails, the AP increments `parked_count` and halts.

## Local APIC and IPIs

[`src/arch/x86_64/lapic.zig`](../../src/arch/x86_64/lapic.zig) detects xAPIC or
x2APIC from `IA32_APIC_BASE` (MSR `0x1b`). It always sets the enable bit (`EN`)
on the current CPU before touching APIC registers.

- In xAPIC mode the 4 KiB register window is reached through the HHDM after the
  containing 2 MiB chunk is marked uncached by `vmm.markUncached`.
- In x2APIC mode the same registers are accessed through MSRs.
- `init` sets the spurious vector to `0xff` with the software-enable bit and
  clears the task priority.
- `id()` reads the local APIC ID.
- `eoi()` writes the EOI register.
- `sendIpi(destination, vector)` sends a fixed-delivery edge IPI to one CPU.
- `sendIpiAllButSelf(vector)` uses the all-but-self shorthand.

The IDT installs gates for:

| Vector | Purpose | Dispatcher behavior |
| --- | --- | --- |
| 240 | Reschedule IPI | Acknowledge LAPIC, call `sched.rescheduleInterrupt`. |
| 241 | TLB shootdown IPI | Acknowledge LAPIC, call `sched.tlbInterrupt`, return unchanged. |
| 255 | LAPIC spurious | Ignore; no EOI is required. |

IRQ0 also sends a LAPIC EOI in addition to the PIC EOI.

## Per-CPU scheduling behavior

- `sched.createOn(cpu, ...)` pins a new task to `cpu`. If the target is not the
  calling CPU, a reschedule IPI is sent after the task is inserted.
- Each CPU has `cpu_state[index]` with `current`, `idle`, `next_scan`, and
  pending sleep/wait requests. `pickNextLocked` scans the global task table for
  `ready` tasks whose `cpu` field matches the current CPU.
- The AP idle entry runs `sti; hlt`; a reschedule or TLB IPI wakes it. The IPI
  handler can switch directly to a ready task from the interrupt frame.
- `sched.enterScheduler()` resumes the idle frame through `sched_resume`. The
  idle frame's `RFLAGS` has `IF=1`.
- The BSP's PIT tick increments the global tick counter and scans all blocked
  tasks for deadlines. A timeout on a remote CPU is delivered as a reschedule
  IPI.
- A task's FPU area is per task, and `%gs:0` is updated on every context switch
  on that CPU. AP exception entry therefore saves and restores AP-local state.

## TLB shootdown

`vmm.unmapPage` clears the PTE under the VMM's IRQ-safe `table_lock`, releases
the lock, then invokes the registered `sched.shootdownTlb` callback for the
unmapped address. The callback:

1. takes a plain `SpinLock` so a waiting shooter can still receive the remote
   IPI;
2. reads `sched.online_mask` and excludes the calling CPU;
3. records the address and resets the acknowledgement mask;
4. sends IPI 241 to every other online CPU;
5. waits until every target has set its acknowledgement bit.

The handler executes `invlpg` for the shared address, then sets its bit in
`tlb_acks`. The local CPU has already executed `invlpg` inside the VMM.

The wait is bounded (50,000,000 `pause` iterations); a CPU that cannot
acknowledge in time causes a best-effort completion rather than a permanent
hang. This is a limitation for interrupts-disabled callers and is recorded in
[technical debt](../development/technical-debt.md).

## SMP tests

`smp.runTest()` runs the shared-counter stress workload:

```text
acquire test_lock
    test_inside += 1
    if test_inside != 1: test_overlap += 1
    test_counter += 1
    test_inside -= 1
release test_lock
```

Each AP runs 100,000 iterations as a scheduler task pinned to that CPU, and the
BSP runs the same workload directly. The expected counter is
`stress_iterations * (number_of_APs + 1)`; with three APs it is 400,000. A
correct spinlock keeps `overlap` at zero.

`smp.runCrossCpuWakeTest()` creates a task on CPU 1 that blocks on a wait queue;
the BSP wakes it, which must travel as a reschedule IPI. The task runs to
completion on CPU 1.

`smp.runApExceptionTest()` creates a task on CPU 1, loads an XMM5 pattern, and
executes `int3`. The breakpoint handler must return and the pattern must survive,
proving AP-local FPU save/restore.

`selftestTlbShootdown()` maps and unmaps a test page after the APs are online
and checks that `sched.tlbShootdownCount()` increases. `selftestLockGuards()`
checks that nested `IrqSpinLock` guards disable interrupts while held and
restore the previous state independently.

The selftest log is:

```text
smp: cpus=4, aps=3, online=3, counter=400000, expected=400000, overlap=0
tlb: shootdowns=1
smp: cross-cpu wake=1, ap exception=1, tlb=1, nested locks=1
smp: smp checks passed
```

## Boot-mode behavior

| Mode | AP behavior |
| --- | --- |
| Normal kernel | `kmain` calls `smp.start()` and `smp.waitOnline()` after scheduler/LAPIC init. APs install per-CPU state and enter the scheduler idle loop. The log is `smp: 3 APs online, scheduler idle`. |
| Selftest kernel | `kmain` skips the early release because `exit_after_boot` is true. `selftestSmp()` calls `smp.start()` after the BSP-only tests, waits online, re-enables scheduling, and runs the M11 tests. |
| Fault-test kernel | `kmain` follows the normal release path, so APs are already in the scheduler idle loop before the deliberate NULL dereference. |

The normal-run log is:

```text
smp: cpus=4, aps=3, bsp_lapic_id=0, x2apic=1
smp: 3 APs online, scheduler idle
```

## Recorded validation

M11 validation ran the full matrix:

- default KVM `zig build test` (`SMP=4`, ReleaseSafe): passed;
- `ZIG_KERNEL_NO_KVM=1 zig build test` (TCG): passed;
- `ZIG_KERNEL_SMP=2 zig build test`: passed;
- `ZIG_KERNEL_SMP=1 zig build test`: passed;
- `zig build -Doptimize=Debug test`: passed;
- `zig build`: passed;
- the smoke result was `counter=400000, expected=400000, overlap=0`, with
  `cross-cpu wake=1, ap exception=1, tlb=1, nested locks=1`;
- `zig fmt --check build.zig src` and `git diff --check`: passed.

## Limitations and deferred work

| Item | Status | Notes |
| --- | --- | --- |
| Limine MP bring-up | **IMPLEMENTED** | APs released through `goto_address`. |
| Per-CPU stacks and TSS | **IMPLEMENTED** | 16 KiB AP boot and task stacks; per-CPU #DF IST. |
| Pre-Zig AP setup | **IMPLEMENTED** | SSE, `CR0.WP`, and global TLB flush in `smp_entry.S`. |
| Per-CPU scheduler/run queues | **IMPLEMENTED** | Pinned tasks; one global task table guarded by `task_lock`. |
| Local APIC and x2APIC | **IMPLEMENTED** | xAPIC MMIO through HHDM; x2APIC MSRs. |
| IPIs and cross-CPU wakeups | **IMPLEMENTED** | Vectors 240 and 241; spurious gate 255. |
| TLB shootdown | **PARTIAL** | Bounded wait; callers that disable interrupts can delay acknowledgement. |
| AP exception and FPU state | **IMPLEMENTED** | `%gs:0` per-CPU FXSAVE pointer; AP `int3` test. |
| PMM/VMM/console/serial locking | **IMPLEMENTED** | IRQ-safe locks; VMM page-table lock plus TLB callback. |
| Heap locking | **PLANNED** | Heap free list remains single-CPU. |
| APIC timer / IOAPIC routing | **PLANNED** | Timer remains BSP PIT/IRQ0. |
| Timer-driven AP preemption | **PLANNED** | APs only switch on IPIs or explicit calls. |
| More than 8 CPUs | **PLANNED** | `max_cpus = 8`; larger responses are rejected. |

## Related documentation

- [Overview](overview.md)
- [Scheduling](scheduling.md)
- [Synchronization](synchronization.md)
- [CPU and interrupts](cpu-interrupts.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
- [Testing](../development/testing.md)
