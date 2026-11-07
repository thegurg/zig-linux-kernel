# SMP bring-up

**Purpose:** describe the Limine multiprocessor protocol path, application
processor entry, per-CPU stacks/TSS, the SMP stress test, and what "SMP
support" does and does not mean in M10.

**Implementation status:** AP bring-up, per-CPU stacks/TSS, atomic spinlocks,
and the SMP stress test are **IMPLEMENTED**. Per-CPU scheduling, LAPIC/IPI
support, cross-CPU wakeups, and SMP-aware wait queues are **PLANNED** for M11.

## Scope: SMP bring-up is not SMP scheduling

M10 brings secondary CPUs online and lets them share the kernel's page tables,
GDT, IDT, and one atomic spinlock. It does **not**:

- give APs scheduler state, run queues, or tasks;
- deliver timer interrupts to APs;
- wake a task on another CPU;
- program the local APIC, IOAPIC, APIC timer, or IPIs;
- shoot down TLB entries on other CPUs;
- make the PMM, VMM, heap, console, or serial driver thread-safe.

The scheduler remains BSP-only. APs either park in `hlt` or run the stress
workload and then park.

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

The `mp_x2apic` response flag is recorded in `smp.Stats.x2apic` and logged. No
x2APIC programming is performed.

## Per-CPU context and stacks

[`src/smp.zig`](../../src/smp.zig) defines:

```zig
pub const ApContext = struct {
    stack_top: u64 = 0,
    index: u32 = 0,
    lapic_id: u32 = 0,
    gdt_cpu: u32 = 0,
    info: u64 = 0,
    online: u64 = 0,
    done: u64 = 0,
};
```

- `max_cpus = gdt.max_cpus = 8`.
- Each AP gets a private 16 KiB stack in `ap_stacks`.
- `stack_top` points at the top of that stack and is the first field read by
  `ap_entry`.
- `gdt_cpu = ap_index + 1`, because CPU 0 is the BSP. The corresponding TSS
  selector is `0x18 + gdt_cpu * 0x10`.
- `info` stores the address of Limine's `MpInfo` for that processor.

`ap_kernel_cr3` is an exported `u64` written once during `smp.init()` with
`vmm.currentPml4()`. The AP stub loads it before calling Zig code.

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

`smp.start(run_test)`:

1. refuses if not initialized or already started;
2. records `test_mode = run_test`, sets `started`, and updates statistics;
3. takes the address of `ap_entry`;
4. for each AP, refreshes `extra_argument` and atomically stores the entry
   address into `info.goto_address` with sequential consistency.

`smp.waitOnline()` spins until `online_count >= stats.aps`, with a limit of
50,000,000 `pause` iterations.

## AP entry path

[`src/arch/x86_64/smp_entry.S`](../../src/arch/x86_64/smp_entry.S) is the
assembly entry:

1. load `extra_argument` (offset 24) from the `limine_mp_info` in `RDI` into
   `RAX`;
2. move the `limine_mp_info` pointer into `RSI` (second argument);
3. load the private stack top from the first field of the context (`RSP`);
4. move the context pointer into `RDI` (first argument);
5. load `ap_kernel_cr3` into `RAX` and write it to `CR3`;
6. execute `cld`;
7. call `ap_main`.

If `ap_main` returns, the stub halts in a `cli; hlt` loop.

`ap_main(ctx, info)` in [`src/smp.zig`](../../src/smp.zig):

1. calls `gdt.setKernelStack(ctx.gdt_cpu, ctx.stack_top)`;
2. loads the shared GDT and this CPU's TSS with `gdt.load(ctx.gdt_cpu)`;
3. loads the shared IDT with `idt.load()`;
4. calls `cpu.enableSse()`;
5. increments `online_count` with an atomic add;
6. if not in test mode, parks immediately;
7. otherwise spins until `test_go` is set;
8. runs the stress workload;
9. increments `done_count` and parks.

### Known AP setup gaps

- `ap_main` executes Zig code before `cpu.enableSse()`; this relies on the
  compiler not emitting SSE instructions before that point.
- APs do not set `CR0.WP`.
- The AP stub switches `CR3` but does not flush global TLB entries. The BSP
  flushes global entries during `vmm.init()` before APs are released, so the
  shared mappings are already valid, but this is not a general TLB-shootdown
  mechanism.
- APs do not install a timer or enter the scheduler; the park loop executes
  `cli; hlt`. IRQ0 remains a BSP-only path in the current design.

These are tracked in [technical debt](../development/technical-debt.md).

## SMP stress test

`smp.runTest()` requires that APs have not already been started. It resets the
test counters, calls `start(true)`, waits for all APs online, publishes
`test_go`, runs the workload on the BSP, waits for every AP to finish, and
returns a `TestResult`.

The workload (`runWorkload`) performs 100,000 iterations per CPU:

```text
acquire test_lock
    test_inside += 1
    if test_inside != 1: test_overlap += 1
    test_counter += 1
    test_inside -= 1
release test_lock
```

The expected counter is:

```text
stress_iterations * (number_of_APs + 1)
```

With `-smp 4` (BSP + 3 APs), the expected value is `400000`. A correct spinlock
keeps the critical-section depth at exactly one, so `overlap` must be zero.

The selftest reports:

```text
smp: cpus=4, aps=3, online=3, counter=400000, expected=400000, overlap=0
```

and passes when `online == aps`, `counter == expected`, and `overlap == 0`.

## Boot-mode behavior

| Mode | AP behavior |
| --- | --- |
| Normal kernel | `kmain` calls `smp.start(false)` and `waitOnline()` when APs exist. APs increment `online_count`, then park. The log is `smp: 3 APs online, parked`. |
| Selftest kernel | `kmain` skips the normal release because `exit_after_boot` is true. `selftestSmp()` calls `smp.runTest()`, which releases the APs in test mode. |
| Fault-test kernel | `kmain` follows the normal release path (it only checks `exit_after_boot`), so APs come online and park before the deliberate NULL dereference. |

The normal-run log after M10 validation was:

```text
smp: cpus=4, aps=3, bsp_lapic_id=..., x2apic=0
smp: 3 APs online, parked
```

The `parked` log is printed after `online_count` reaches the target; the AP may
still be between the increment and its `hlt`, so the message describes the
intended end state rather than a confirmed halted state. This is a diagnostic
nuance, not a scheduling guarantee.

## Recorded validation

M10 validation reported:

- default KVM `zig build test` passed;
- three repeated KVM runs were stable:
  `counter=400000, expected=400000, overlap=0`;
- TCG passed;
- `-Doptimize=Debug` passed;
- a normal kernel run printed `0.13.0-m10`, `cpus=4, aps=3`, and
  `3 APs online, parked`;
- `zig fmt --check build.zig src` and `git diff --check` passed.

The later documentation audit re-ran the default KVM `zig build test` and saw
exit code 0 with no test failures.

## Limitations and deferred work

| Item | Status | Notes |
| --- | --- | --- |
| Limine MP bring-up | **IMPLEMENTED** | APs released through `goto_address`. |
| Per-CPU stacks and TSS | **IMPLEMENTED** | 16 KiB AP stacks; per-CPU #DF IST. |
| Atomic spinlock stress test | **IMPLEMENTED** | 100,000 iterations per CPU. |
| Per-CPU scheduler/run queues | **PLANNED** | M11. |
| Local APIC / IOAPIC / APIC timer | **PLANNED** | None programmed; PIC/PIT only. |
| IPIs and cross-CPU wakeups | **PLANNED** | No IPI mechanism exists. |
| TLB shootdown | **PLANNED** | `vmm.unmapPage` invalidates only the local CPU. |
| SMP-safe PMM/VMM/heap/console/serial | **PLANNED** | Current code is not thread-safe. |
| Per-CPU exception/NMI handling | **PLANNED** | AP exception path uses global BSP state. |
| x2APIC support | **PLANNED** | Response flag is only recorded and logged. |
| More than 8 CPUs | **PLANNED** | `max_cpus = 8`; larger responses are rejected. |

## Related documentation

- [Overview](overview.md)
- [Scheduling](scheduling.md)
- [Synchronization](synchronization.md)
- [CPU and interrupts](cpu-interrupts.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
- [Testing](../development/testing.md)
