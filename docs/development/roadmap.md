# Roadmap

**Purpose:** record planned work separately from implemented behavior. Nothing
in this document is implemented unless it is also described as implemented in
the architecture documents.

**Current status:** M0-M14 are complete and validated through the QEMU test
flow. M15 is the next milestone. M15-M20 are planned and are recorded below with
their scope and verification criteria.

## Pre-M11 bugfix pass (complete)

The architecture audit findings were fixed before starting M11:

- `sync.IrqSpinLock` and `sync.IrqLock` return per-acquisition guards; the
  scheduler's `task_lock` call sites use the guard form.
- AP setup ordering: `smp_entry.S` enables SSE and sets `CR0.WP` before Zig
  code, then flushes global translations across the `CR3` switch.
- Diagnostics: the unconditional `M1c complete` line was removed, the timer
  message no longer claims interrupts are enabled early, and the AP `parked`
  message waits on an explicit `parked_count`.
- `src/test_root.zig` imports the Limine binding test, and `tools/run.sh`
  derives the expected CPU count from `ZIG_KERNEL_SMP`.
- `initialFrame` stores a return trampoline in the task's initial return slot so
  a returning entry exits through the scheduler instead of `ret`-ing into
  garbage.

Validation: default KVM, TCG, and Debug `zig build test` runs pass; the smoke
flow also passes with `ZIG_KERNEL_SMP=1` and `=2`. See
[testing](testing.md) for the recorded results.

## M11: per-CPU scheduling and SMP-aware wait queues (complete)

### Goal

Move scheduling from a single global BSP scheduler to per-CPU scheduler state,
allow APs to schedule tasks, and make blocking primitives work across CPUs. This
requires an interrupt mechanism that can wake another CPU, so LAPIC/IPI support
is part of the milestone.

### What landed

1. **Lock ordering** — the order is documented in
   [synchronization](../architecture/synchronization.md). The scheduler uses one
   global `task_lock`; the VMM and PMM use IRQ-safe allocator locks; console and
   serial lock messages. The heap lock and the lock-free TLB mailboxes arrived
   in M12.
2. **Per-CPU scheduler state** — every CPU has a `CpuState` (current task, idle
   task, scan cursor, pending sleep/wait requests), a private idle stack, and a
   `PerCpu` block installed through the GS base MSR. Tasks are pinned to a CPU
   at creation with `createOn`.
3. **AP scheduler entry** — APs leave Limine's park loop, install their per-CPU
   block, initialise the LAPIC, call `sched.initCpu`, and enter `enterScheduler`,
   which resumes the AP's idle frame. APs no longer halt permanently.
4. **LAPIC/IPI support** — xAPIC and x2APIC are detected from `IA32_APIC_BASE`.
   The kernel programs the spurious vector, reads LAPIC IDs, sends fixed IPIs to
   one CPU or all-but-self, and acknowledges interrupts with LAPIC EOI. Vector
   240 is the reschedule IPI, 241 the TLB IPI, and 255 the spurious gate.
5. **SMP-aware blocking primitives** — wait queues, mutexes, and condition
   variables enqueue and wake task IDs under `task_lock`; waking a task on
   another CPU sends a reschedule IPI. Mutex and condition waits pre-mark the
   current task blocked before releasing the scheduler lock, so a cross-CPU
   unlock cannot lose the wakeup.
6. **TLB shootdown** — `vmm.unmapPage` reports the unmapped address through a
   callback after releasing its page-table lock. The scheduler sends IPI 241 to
   every other online CPU and waits for acknowledgements.
7. **AP exception and FPU state** — `PerCpu.fpu_state` at offset 0 is reached
   through `%gs:0` from the interrupt entry stub and from `sched_resume`. The
   scheduler updates the per-CPU pointer when it switches tasks, so AP
   exceptions save and restore the interrupted AP task's state.
8. **Expanded tests** — the selftest now runs AP scheduler workers, a cross-CPU
   wakeup, an AP `int3`/FPU-preservation test, a TLB-shootdown test, and a
   nested `IrqSpinLock` guard test. The full flow passes under KVM, TCG,
   `-Doptimize=Debug`, and `ZIG_KERNEL_SMP=1/2/4`.

### Key bug found during M11 bring-up

Zig's automatic struct layout reordered the fields of `cpu.PerCpu`, so
`%gs:8`/`%gs:12` did not read `index`/`lapic_id`; every AP appeared to be CPU 0
and received no schedulable task. `PerCpu` is now an `extern struct` with
compile-time offset checks for `fpu_state`, `index`, and `lapic_id`.

### M11 acceptance criteria (met)

- APs run scheduler idle loops and can execute tasks.
- A task can be created on, and woken on, a CPU other than the BSP.
- Wait queues, mutexes, and condition variables preserve their signal/timeout
  semantics under cross-CPU wakeups.
- `IrqSpinLock` works under contention and nesting without corrupting
  interrupt state.
- TLB shootdown invalidates remote translations after `unmapPage`.
- AP exceptions use per-CPU FPU and scheduler state.
- The full test flow passes under KVM, TCG, and `-Doptimize=Debug`.

### M11 non-goals

- User mode, user address spaces, and system calls.
- A general driver framework or filesystem.
- Replacing the PIC/PIT entirely; IOAPIC routing and a CPU 0 LAPIC timer remain deferred.
- More than `max_cpus = 8` without changing the GDT/TSS layout.

## M12: allocator locking and TLB hardening (complete)

### Goal

Make the kernel heap safe for concurrent use and replace the bounded,
shared-state TLB shootdown with a protocol that cannot silently drop an
invalidation. Both changes must be verifiable under QEMU with active APs.

### What landed

1. **Heap lock** — `heap.alloc`, `free`, `stats`, and `init` take one IRQ-safe
   `heap_lock`. `growLocked` maps and zeroes new pages while holding it, so the
   lock order is `heap.lock` → `vmm.table_lock` → `pmm.lock`.
2. **Partial-growth policy** — a grow that fails partway returns the mapped
   prefix to the free list and leaves the reserved-but-unmapped tail unused. It
   never unmaps while holding `heap_lock`, so it never waits for a TLB shootdown
   with the lock held. `heap_mapped_bytes` keeps statistics accurate.
3. **Lock-free TLB mailboxes** — each shooter owns a row of `(address,
   sequence)` cells and each target acknowledges into its own column. The global
   sequence counter makes stale requests distinguishable. The IPI handler scans
   every shooter row, invalidates new sequences, and takes no locks.
4. **Unbounded acknowledgement wait** — `shootdownTlb` waits until every target
   acknowledges its sequence. A target with interrupts disabled keeps the
   request pending in its LAPIC until it enables interrupts. Callers must call
   `unmapPage` with interrupts enabled when other CPUs are online.
5. **M12 tests** — `runConcurrentHeapTest` runs allocate/write/verify/free loops
   on every CPU; `runIrqOffShootdownTest` shoots down to a CPU with interrupts
   disabled; `runConcurrentShootdownTest` has every AP map/unmap a private page
   concurrently. The selftest enables BSP interrupts for this phase while IRQ0
   stays masked.

### Validation

The full matrix passed: default KVM `zig build test` (`SMP=4`), TCG
(`ZIG_KERNEL_NO_KVM=1`), `ZIG_KERNEL_SMP=2`, `ZIG_KERNEL_SMP=1`, Debug
(`-Doptimize=Debug`), and `zig build`. The default run reported:

```text
heap: concurrent allocs=4000, errors=0
tlb: irq-off=1, concurrent shootdowns=150, errors=0
selftest: M12 checks passed
```

`SMP=2` reported 2,000 allocations and 50 shootdowns; `SMP=1` skipped the
AP-only tests and completed 1,000 BSP allocations. See
[testing](testing.md) for the full record.

### M12 non-goals

- Per-CPU heap arenas or size classes.
- Reclaiming the reserved tail left by a partial grow.
- A TLB-shootdown fast path based on PCID or generation counters.
- PMM exhaustion or page-table allocation-failure injection.

## M13: per-CPU timers and AP preemption (complete)

### Goal

Give application processors their own timer-driven ticks so their tasks are
preempted and their timed sleepers wake locally, without changing CPU 0's
existing PIT behavior.

### What landed

1. **Per-CPU tick counters** — the single global `tick_counter` was replaced by
   `cpu_ticks[max_cpus]`. Every CPU advances only its own counter.
2. **AP LAPIC timers** — each AP starts a periodic LAPIC timer on vector 242
   during bring-up. CPU 0 keeps the 100 Hz PIT on IRQ0, so existing BSP tests and
   boot behavior are unchanged.
3. **Calibration** — the BSP measures a masked one-shot LAPIC count against a
   50 ms PIT channel-2 reference and publishes the reload value before releasing
   the APs. The measurement does not need interrupts or IOAPIC/ACPI support.
4. **Local deadline handling** — a timer tick wakes only blocked tasks pinned to
   that CPU and compares deadlines against that CPU's counter. Cross-CPU wakeups
   still use the reschedule IPI.
5. **Timer dispatch** — `sched.timerInterrupt` is shared by PIT IRQ0 and LAPIC
   vector 242. The AP timer fires with interrupts enabled in the idle frame, and
   `timerInterrupt` may switch tasks like any other preemption point.
6. **M13 tests** — one sleeper per AP proves that each AP counter advances and
   `sched.sleep` wakes on that AP. Two CPU-bound tasks pinned to CPU 1 prove
   timer-driven preemption: each must observe the other's counter while both are
   still running.

### Validation

The full matrix passed: default KVM `zig build test` (`SMP=4`), TCG
(`ZIG_KERNEL_NO_KVM=1`), `ZIG_KERNEL_SMP=2`, `ZIG_KERNEL_SMP=1`, Debug
(`-Doptimize=Debug`), and `zig build`. The default run reported:

```text
timer: LAPIC 625396 counts per tick
timer: per-cpu ticks=9, sleepers=3, preempted=1
selftest: M13 checks passed
```

`SMP=2` reported one AP sleeper with three ticks of sleep; `SMP=1` skipped the
AP-only part and reported zero sleepers. The preemption test also passed on
repeated KVM runs and under TCG. See [testing](testing.md) for the full record.

### M13 non-goals

- Replacing the BSP PIT with a LAPIC timer on CPU 0.
- IOAPIC routing or ACPI MADT parsing.
- A per-CPU timer abstraction for drivers.
- AP NMI or watchdog support.

## M14: ACPI, IOAPIC, and uniform per-CPU timers (complete)

### Goal

Replace the legacy PIC/PIT boot timer assumption with an ACPI-described
platform and a LAPIC timer on every CPU. Preserve a PIC/PIT fallback so a
platform without usable ACPI still boots.

### What landed

1. **ACPI discovery** — [`src/limine.zig`](../../src/limine.zig) now issues the
   Limine RSDP request (base revision 3 returns a physical address), and
   [`src/acpi.zig`](../../src/acpi.zig) validates `RSDP -> XSDT` (or `RSDT`) ->
   `MADT` signatures, lengths, checksums, and physical ranges before reading
   through the HHDM.
2. **MADT data** — the parser records enabled local and x2APICs, I/O APICs, the
   LAPIC address override, and every Interrupt Source Override (ISO). `kmain`
   logs the revision and counts:
   `acpi: madt revision=3 cpus=4/4 ioapics=1 isos=5 lapic=0xfee00000`.
3. **ISA IRQ resolution** — `acpi.isaIrqRoute()` makes the ISO authoritative for
   bus-0 ISA IRQs; the identity mapping `GSI == IRQ` is used only when no ISO
   exists. On QEMU q35, IRQ0 resolves to GSI 2, active-high, edge-triggered, so
   the kernel does not hardcode GSI 2.
4. **IOAPIC driver** — [`src/arch/x86_64/ioapic.zig`](../../src/arch/x86_64/ioapic.zig)
   maps every MADT-described IOAPIC window through the HHDM, marks the covering
   chunk uncached, reads version/ID/entry count, masks every pin, and programs
   redirection entries with vector, destination APIC ID, polarity, trigger mode,
   and mask state. It can also mask/unmask and read back a pin.
5. **EOI rule** — an IOAPIC-delivered fixed interrupt is acknowledged with a
   Local APIC EOI only. The M14 delivery test routes ISA IRQ0 to vector 242, whose
   dispatcher sends a LAPIC EOI; the legacy PIC IRQ0 path keeps its separate PIC
   EOI.
6. **CPU 0 timer** — the BSP calibrates the LAPIC timer before releasing the APs.
   Normal boot starts a periodic LAPIC timer on vector 242 for CPU 0, so CPU 0 and
   every AP use the same timer mechanism. The PIT IRQ0 path remains the fallback.
7. **Calibration source** — PIT channel 2 stays a blocking millisecond reference
   for LAPIC calibration only. It is not programmed as an interrupt source.
8. **Fallback** — a failed ACPI/IOAPIC setup or LAPIC calibration is logged and
   leaves the PIC/PIT path available. A dedicated `force_pit` image exercises
   that path in `zig build test`.

### Scope

1. **ACPI discovery** — add a Limine RSDP request and parse `RSDP -> XSDT`
   (or `RSDT`) -> `MADT` with signature, length, and checksum validation.
2. **MADT data** — record enabled local APICs, I/O APICs, the LAPIC address
   override, and every Interrupt Source Override (ISO). Log the table version
   and counts.
3. **ISA IRQ resolution** — do not hardcode GSI 2 for PIT IRQ0. Resolve ISA
   IRQ0 through the MADT ISO and apply its polarity and trigger mode. Use GSI 0
   only when no ISO exists. The same helper must be usable for later ISA IRQs.
4. **IOAPIC driver** — map the IOAPIC MMIO window uncached, read its version
   and redirection-entry count, and program a redirection entry with vector,
   destination APIC ID, polarity, trigger mode, and mask state.
5. **EOI rule** — an IOAPIC-routed fixed interrupt is acknowledged with a Local
   APIC EOI. The IOAPIC has no EOI register; do not send a PIC EOI for an
   IOAPIC-delivered vector.
6. **CPU 0 timer** — calibrate the LAPIC timer on the BSP and start a periodic
   timer on vector 242. CPU 0 and every AP now use the same timer mechanism.
7. **Calibration source** — PIT channel 2 remains a blocking millisecond
   reference for LAPIC calibration only. It is not an interrupt source and must
   not be programmed as one.
8. **Fallback** — if ACPI/IOAPIC setup or LAPIC calibration fails, log the
   reason and keep the existing PIT IRQ0 path working.

### Tests

- Log and assert the MADT CPU/IOAPIC/ISO counts and the resolved `IRQ0 -> GSI`
  mapping, including the ISO polarity and trigger mode.
- Read back an IOAPIC redirection entry after programming it.
- End-to-end IOAPIC delivery test: stop the CPU 0 LAPIC timer, program PIT
  channel 0, route ISA IRQ0 through its resolved GSI to vector 242, observe
  counter ticks, then mask the redirection entry. The tick handler must send a
  Local APIC EOI.
- Start the CPU 0 LAPIC timer again and verify a CPU 0 sleeper and CPU 0
  preemption test.
- All M2-M13 tests continue to pass under KVM and TCG. The fallback path is
  exercised by a build/test option or by deliberately unavailable ACPI, not by
  weakening the default assertions.

### Validation

The full matrix passed: `zig build` (default ReleaseSafe), default KVM
`zig build test` (`SMP=4`), TCG (`ZIG_KERNEL_NO_KVM=1`), `ZIG_KERNEL_SMP=2`,
`ZIG_KERNEL_SMP=1`, and Debug (`-Doptimize=Debug`). The default run reported:

```text
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
```

The `force_pit` image booted through the fallback path and reported
`timer: source=pit, 100 Hz, IRQ0 unmasked`; `tools/run.sh --test-boot` asserts
it. `zig fmt --check src build.zig` and `git diff --check` also passed. See
[testing](testing.md) for the full record.

### Non-goals

- MSI/MSI-X and PCI interrupt routing.
- LAPIC timer replacement of the PIT calibration reference.
- Full AML parsing or ACPI namespace evaluation.

## M15: timekeeping and scheduler contracts (planned)

### Goal

Give the kernel a monotonic time base and scheduler APIs suitable for user
code, without yet adding process isolation.

### Scope

1. **Invariant TSC detection** — check CPUID for a non-stop invariant TSC and
   record whether the platform provides one.
2. **TSC calibration** — measure the TSC against the LAPIC/PIT reference and
   expose a nanosecond monotonic clock.
3. **Cross-CPU synchronization** — verify TSC values are comparable across
   CPUs and synchronize or correct them at AP bring-up.
4. **Monotonicity validation** — reject or clamp backward jumps and document
   the tolerated skew.
5. **Fallback clocksource** — if the TSC is missing, unstable, or
   non-invariant, fall back to a calibrated tick counter without changing the
   public time API.
6. **Deadline queue** — replace the full blocked-task scan with a deadline
   queue while keeping tick-based scheduling.
7. **Sleep and join** — add millisecond/nanosecond sleep helpers, task `join`
   with exit status and timeout, and priority levels with a documented
   starvation policy. Task migration remains planned for M20.

### Tests

- TSC presence and invariant-TSC CPUID bits are reported.
- The monotonic clock is nondecreasing and its rate matches the LAPIC/PIT
  reference within a stated tolerance on every CPU.
- Cross-CPU timestamps taken around a synchronization point agree within the
  documented tolerance.
- `sleepMs` wakes within bounds; join returns success, timeout, and
  already-exited statuses correctly; priority ordering is asserted.
- The fallback clocksource passes the same monotonicity and sleep tests.

## M16: ring 3, address spaces, and syscalls (planned)

### Goal

Establish the first isolation boundary: a user task with its own address space
and a minimal syscall path.

### Scope

1. **Address spaces** — one private low-half PML4 per task, with the kernel
   high half shared.
2. **Privilege transition** — ring-3 entry, a DPL3 syscall gate (`int 0x80`
   first), `swapgs`, per-CPU TSS `RSP0`, and a per-task kernel stack.
3. **User memory** — `copyFromUser`/`copyToUser` with range and canonical
   address validation.
4. **Syscalls** — `write`, `exit`, `yield`, `sleepMs`, and `getpid`.
5. **Minimal test-only loader** — load exactly one embedded ELF64 test
   program with `PT_LOAD` segments. This loader is deliberately minimal and is
   not the general process loader.
6. **CR3 switching** — switch address spaces on task switch and tear down the
   user half on exit.

### Tests

- User `write` reaches the serial console; `exit` returns a status.
- A user NULL fault kills only the offending task.
- Two user tasks cannot access each other's mappings.
- Timer preemption works while a user task is running.
- Invalid user pointers are rejected without a kernel panic.

### Non-goals

- General ELF validation, PIE, dynamic linking, `exec`, and `argv`.
- General process creation and reaping; these belong to M17.

## M17: ELF64 loading and process lifecycle (planned)

### Goal

Turn the M16 test-only loader into a general process model.

### Scope

1. **ELF validation** — magic, class, machine, bounds, overlap, and supported
   `ET_EXEC` program headers.
2. **W^X and NX** — code RX, data and stack RW+NX, guard pages, and EFER.NXE.
3. **Initial stack** — `argc`, `argv`, `envp`, and alignment.
4. **Process API** — `spawn`, `wait`, `reap`, a process table, exit-status
   storage, and generation IDs so finished slots are not confused with live
   tasks.
5. **Teardown** — free user pages, destroy the PML4, issue TLB shootdowns, and
   safely reuse finished task slots.

### Tests

- Load and run an embedded ELF; spawn and reap two processes concurrently.
- Waiting returns the expected status; a timeout path is covered.
- An NX violation kills only the offending process.
- Failed loads are rejected without leaking pages or address spaces.
- Address spaces are reclaimed and reusable after reaping.

## M18: PCI, virtio-blk, and VFS/initramfs (planned)

### Goal

Read real storage through a virtio block device and expose files to the process
model.

### Scope

1. **PCI enumeration** — legacy config-space access (`0xCF8`/`0xCFC`) first;
   ECAM is optional and depends on MCFG.
2. **IOAPIC and MSI-X stay separate** — IOAPIC routing from M14 is not MSI-X.
   MSI-X requires its own PCI capability discovery, table mapping, vector
   allocation, and per-vector masking.
3. **virtio-blk, polling first** — feature negotiation, virtqueues, descriptor
   chains, and block completion by polling. This is the required path.
4. **MSI-X extension** — within M18 only after polling works, add MSI-X with
   its own capability and interrupt setup. Interrupt delivery must be tested
   independently of the polling path.
5. **Block layer and VFS** — 512-byte sector access, a sector-pattern test, a
   minimal VFS, and a read-only FAT16/FAT32 driver.
6. **Initramfs fallback** — Limine modules and a tar reader for tests and for
   systems without a block device.
7. **Disk image generation** — a Python script builds the test image; no
   `sudo`, `mtools`, `xorriso`, or `losetup`.

### Tests

- Enumerate PCI devices and identify virtio-blk.
- Read and write known sector patterns through the polling path.
- Mount the generated FAT image and read a known file.
- Load and run `init` from the filesystem.
- If MSI-X is implemented, verify its capability setup and interrupt
  completion separately; the polling tests must keep passing.
- Read a known file from the Limine-module initramfs.

## M19: virtio-net and network stack (planned)

### Goal

Add a small, testable network path.

### Scope

- virtio-net receive/transmit queues and completion handling.
- Ethernet framing, ARP, IPv4, ICMP echo, UDP, and loopback.
- A minimal socket-style API.
- A DNS query smoke test through QEMU user-mode networking.
- TCP and full DHCP are deferred unless the lower layers land cleanly.

### Tests

- Report the MAC address and configured IPv4 address.
- Answer ARP and receive an ICMP echo reply from the QEMU gateway.
- Exchange a UDP datagram and verify loopback.
- All earlier milestones remain green under KVM and TCG.

## M20: robustness, SMP maturity, and observability (planned)

### Goal

Make the kernel diagnosable and hard to break under stress.

### Scope

1. **Serial shell** — `help`, `ps`, `mem`, `cpus`, `time`, `pci`, `mounts`, and
   `net`.
2. **Panic diagnostics** — stack unwinding and per-CPU state dumps.
3. **NMI watchdog** — the test must deliver an NMI to another CPU, not only to
   the initiating CPU. The NMI handler must be safe for NMI context: no
   ordinary locks, no dynamic allocation, no blocking, and no reliance on
   scheduler state.
4. **Migration and load balancing** — move ready tasks between CPUs while
   preserving affinity and wakeup correctness.
5. **Failure injection** — PMM exhaustion, VMM mapping failure, and heap growth
   failure; callers must return errors rather than panic.
6. **Stress** — a long-running combination of allocation, TLB shootdown,
   timers, and user processes.

### Tests

- Scripted shell commands produce expected output.
- A panic test produces a plausible stack and per-CPU dump.
- The NMI watchdog test sends an NMI to a different CPU, observes it in the
  handler, and verifies the target CPU continues afterwards.
- The NMI handler is audited and tested to take no ordinary locks and perform
  no allocation.
- Failure injection returns errors without panicking or leaking resources.
- Migration is observed on more than one CPU without lost wakeups.
- A sustained stress run passes under KVM and TCG.

## Later work

The following items remain deferred beyond M20. They are ordered by
dependency, not by priority.

| Item | Status | Notes |
| --- | --- | --- |
| Reclaim partial heap growth | **PLANNED** | A failed grow leaks the reserved-but-unmapped tail. |
| Physical memory above 4 GiB | **PLANNED** | PMM bitmap is sized for 4 GiB. |
| Heap `resize`/`remap` | **PLANNED** | Currently `noResize`/`noRemap`. |
| Per-CPU heap arenas | **PLANNED** | One global lock serializes all allocations. |
| PCID/generation TLB fast path | **PLANNED** | Shootdowns currently use global mailboxes. |
| More than 8 CPUs | **PLANNED** | `max_cpus = 8`; GDT/TSS layout must change. |

## Milestone history

| Milestone | Status | Summary |
| --- | --- | --- |
| M0 | **IMPLEMENTED** | Higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM/memory-map reporting, SSE. |
| M1a | **IMPLEMENTED** | Kernel stack, GDT/TSS, IDT, exception dispatcher, PIC remap/mask. |
| M1b | **IMPLEMENTED** | Bitmap PMM with double-free protection. |
| M1c | **IMPLEMENTED** | 4-level paging, HHDM, 64 MiB kernel heap. |
| M2 | **IMPLEMENTED** | IRQ stubs, 100 Hz PIT, preemptive round-robin scheduler. |
| M3 | **IMPLEMENTED** | Cooperative yield/exit, idle task, slot reuse. |
| M4 | **IMPLEMENTED** | Sleep and interrupt-safe locking. |
| M5 | **IMPLEMENTED** | Block/wake with blocked-task counter. |
| M6 | **IMPLEMENTED** | Wait queues with stale-waiter pruning. |
| M7 | **IMPLEMENTED** | Timed waits with signal/timeout distinction. |
| M8 | **IMPLEMENTED** | Mutex with ownership transfer and condition variables. |
| M9 | **IMPLEMENTED** | FPU/SIMD context switching. |
| M10 | **IMPLEMENTED** | Limine MP bring-up, per-CPU stacks/TSS, atomic spinlocks, SMP stress test. |
| Pre-M11 | **IMPLEMENTED** | Interrupt-safe guards, AP setup ordering, accurate diagnostics, task return trampoline, host SMP/test harness fixes. |
| M11 | **IMPLEMENTED** | Per-CPU scheduling, LAPIC/x2APIC IPIs, SMP-aware blocking, TLB shootdown, AP exception/FPU state, expanded tests. |
| M12 | **IMPLEMENTED** | IRQ-safe heap lock, concurrent allocator stress, lock-free TLB mailboxes, IRQ-off and concurrent shootdown tests. |
| M13 | **IMPLEMENTED** | Per-CPU tick counters, AP LAPIC timers, local deadline wakeups, timer-driven AP preemption, calibration and tests. |
| M14 | **IMPLEMENTED** | ACPI/MADT discovery, ISO-based ISA IRQ resolution, IOAPIC driver, CPU 0 LAPIC timer, PIC/PIT fallback, IOAPIC delivery and fallback boot tests. |
| M15 | **PLANNED** | Invariant-TSC detection, cross-CPU clock synchronization, monotonic time, fallback clocksource, deadline queue, sleep/join/priorities. |
| M16 | **PLANNED** | Ring 3, per-task address spaces, syscall gate, user memory validation, minimal test-only ELF loader. |
| M17 | **PLANNED** | General ELF64 validation, W^X/NX, argv, spawn/wait/reap, process table, address-space teardown. |
| M18 | **PLANNED** | PCI enumeration, virtio-blk polling, optional MSI-X extension, block layer, VFS, FAT, initramfs. |
| M19 | **PLANNED** | virtio-net, Ethernet/ARP/IPv4/ICMP/UDP, loopback, minimal socket API. |
| M20 | **PLANNED** | Shell, panic unwinding, cross-CPU NMI watchdog, migration, failure injection, stress. |

## Related documentation

- [Overview](../architecture/overview.md)
- [Scheduling](../architecture/scheduling.md)
- [Synchronization](../architecture/synchronization.md)
- [SMP bring-up](../architecture/smp.md)
- [Technical debt](technical-debt.md)
- [Testing](testing.md)
- [Building](building.md)
