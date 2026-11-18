# CPU and interrupts

**Purpose:** document x86_64 CPU mode setup, per-CPU state, descriptor tables,
interrupt and exception handling, the legacy PIC/PIT, ACPI/MADT discovery, the
I/O APIC, the local APIC/IPIs, timekeeping, and the interrupt-facing FPU state.

**Implementation status:** CPU bring-up, GDT/TSS, IDT, exception dispatch,
PIC/PIT, ACPI/MADT parsing, IOAPIC redirection, LAPIC/x2APIC, IPI dispatch,
per-CPU LAPIC timers, per-CPU interrupt-time FPU save/restore, and the monotonic
time base are **IMPLEMENTED**. The preferred clocksource is the invariant TSC,
calibrated against PIT channel 2 and synchronized across CPUs with IPI 243; a
calibrated 100 Hz tick fallback preserves the public API. CPU 0 and every AP use
a periodic LAPIC timer on vector 242; the PIT IRQ0 path remains the fallback. See
[technical debt](../development/technical-debt.md).

## SSE and FPU enablement

[`src/arch/x86_64/cpu.zig`](../../src/arch/x86_64/cpu.zig) contains
`enableSse()`. It runs before non-trivial Zig code because firmware does not
guarantee `CR4.OSFXSR`, and executing SSE instructions with `OSFXSR` clear
raises `#UD`. KVM enforces this strictly; TCG tends to tolerate it.

`enableSse()`:

- clears `CR0.EM` (bit 2) and `CR0.TS` (bit 3);
- sets `CR0.MP` (bit 1) and `CR0.NE` (bit 5);
- sets `CR4.OSFXSR` (bit 9) and `CR4.OSXMMEXCPT` (bit 10);
- executes `fninit`.

`MXCSR` is deliberately left at its architectural reset value (`0x1f80`: all
SIMD exceptions masked, round to nearest). `ldmxcsr` has been observed to fault
under KVM on some nested-KVM hosts, so the kernel does not program it.

The BSP calls `enableSse()` at the very start of `kmain`. APs enable SSE in the
assembly entry stub (`smp_entry.S`) before calling any Zig code, because `CR0`
and `CR4` are per-CPU and the compiler may emit SSE as soon as `ap_main`
starts. The stub also sets `CR0.WP`, matching the BSP's write-protect policy.

## Per-CPU state and the GS base

Every CPU installs a `cpu.PerCpu` block and points `IA32_GS_BASE`
(MSR `0xc0000101`) at it:

```zig
pub const PerCpu = extern struct {
    fpu_state: u64 = 0,  // offset 0:  %gs:0
    index: u32 = 0,      // offset 8:  %gs:8
    lapic_id: u32 = 0,   // offset 12: %gs:12
    online: u64 = 0,
};
```

`extern struct` and compile-time offset checks are required: Zig's automatic
layout now reorders fields, and the assembly depends on these exact offsets.

- The BSP calls `cpu.initPerCpu(0, bsp_lapic_id)` after loading the GDT and
  after LAPIC discovery.
- Each AP calls `cpu.initPerCpu` after `gdt.load` and before any code that can
  fault.
- `%gs:0` initially points at `boot_fpu_state`, a scratch FXSAVE area.
  `sched.init` and `sched.initCpu` replace it with the current task's FPU area.
- `cpu.currentIndex()` and `cpu.lapicId()` are `movl %gs:8` / `movl %gs:12`.
- `cpu.initPerCpu` also clears `IA32_KERNEL_GS_BASE` (`0xc0000102`) to zero.
  The kernel invariant is `GS_BASE = per-CPU block` and `KERNEL_GS_BASE = 0`
  while executing in the kernel; ring-3 code may use `GS` freely. Entry from
  ring 3 executes `swapgs` before dereferencing `%gs:0`, and the resume path
  executes `swapgs` again before returning to a user frame.

The GS base is not changed by `iretq` or by kernel task switches; only the
pointer at `%gs:0` changes per task. A user task's GS value is preserved by the
`swapgs` pair rather than by saving an MSR on every switch.

## GDT and TSS

[`src/arch/x86_64/gdt.zig`](../../src/arch/x86_64/gdt.zig) builds a flat
long-mode GDT:

| Entry | Selector | Meaning |
| --- | --- | --- |
| 0 | `0x00` | Null descriptor. |
| 1 | `0x08` | 64-bit kernel code, present, DPL0, `L=1`. |
| 2 | `0x10` | Kernel data, present, DPL0, writable, `D/B=1`. |
| 3 | `0x18` | 64-bit user code, present, DPL3, `L=1`. |
| 4 | `0x20` | User data, present, DPL3, writable, `D/B=1`. |
| 5.. | `0x28 + cpu * 0x10` | Low/high TSS descriptor pair for each CPU. |

- `max_cpus = 8`, so the GDT has `5 + 2 * 8 = 21` qwords.
- CPU 0 is the BSP; its TSS selector is `0x28`. CPU N uses
  `0x28 + N * 0x10`.
- Each TSS is 104 bytes and is built byte-wise because fields are unaligned.
  `RSP0` is at offset `0x04`, `IST1` at `0x24`, and the I/O map base at `0x66`
  (`0xffff`, meaning no I/O permission bitmap).
- Every CPU gets an 8 KiB double-fault stack; `IST1` points at it and vector 8
  (`#DF`) uses IST index 1.
- The bootstrap kernel stack is a 64 KiB exported array, `kernel_stack`.

`gdt.init()` fills all per-CPU TSS descriptors, computes the GDTR, and calls
`gdt.load(0)`. `gdt.load(cpu)` reloads the shared GDT, far-returns through
`0x08` to reload `CS`, reloads `SS/DS/ES/FS/GS` with `0x10`, and executes
`ltr` with that CPU's TSS selector. Because loading a data-segment selector
changes the GS base state in long mode, callers must install the per-CPU block
with `cpu.initPerCpu` **after** `gdt.load`. `gdt.setKernelStack(cpu, top)`
updates the TSS `RSP0` field; APs use it to install their private stack, and the
scheduler rewrites it on every task switch so a ring-3 interrupt lands on the
current task's kernel stack.

## IDT and gate layout

[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig) owns a 256-entry IDT
of 16-byte gates. `idt.init()` installs:

| Vectors | Handler table | Notes |
| --- | --- | --- |
| 0-31 | `isr_stub_table` | CPU exceptions; vector 8 uses IST1 for `#DF`. |
| 32-47 | `irq_stub_table` | PIC IRQs; only IRQ0 is unmasked. |
| 48-54 | `sched_stub_table` | Scheduler software interrupts and join. |
| 240, 241, 243 | `ipi_stub_table[0..3]` | Reschedule, TLB-shootdown, and TSC-sync IPIs. |
| 242 | `timer_stub_table[0]` | Periodic LAPIC timer on every CPU, including CPU 0. |
| 128 | `syscall_stub_table[0]` | DPL3 `int 0x80` syscall gate. |
| 255 | `ipi_stub_table[3]` | LAPIC spurious-interrupt gate. |

Every gate is a present, 64-bit interrupt gate (`type_attr = 0x8e`), except the
syscall gate, which sets DPL3 (`0xee`). `idt.load()` executes `lidt`; the BSP
fills the table, and APs load the same shared table.

### Scheduler software interrupts

| Vector | Public API | Dispatcher entry |
| --- | --- | --- |
| 48 | `sched.yield()` | `sched.yieldCurrent` |
| 49 | `sched.exit()` | `sched.exitCurrent` |
| 50 | `sched.sleep(ticks)` | `sched.sleepCurrent` |
| 51 | `sched.block()` / mutex/condition waits | `sched.blockCurrent` |
| 52 | `WaitQueue.wait()` | `sched.waitQueueCurrent` |
| 53 | `WaitQueue.waitTimeout(ticks)` | `sched.waitTimeoutCurrent` |
| 54 | `sched.join(task, timeout_ms)` | `sched.joinCurrent` |
| 128 | `int 0x80` from ring 3 | `syscall.dispatch` |

## Interrupt entry and exit

All stubs live in [`src/arch/x86_64/interrupts.S`](../../src/arch/x86_64/interrupts.S).
Each stub normalizes the stack to:

```text
[rsp + 0]   vector
[rsp + 8]   error code (synthesized as 0 when the CPU pushes none)
[rsp + 16]  RIP
[rsp + 24]  CS
[rsp + 32]  RFLAGS
[rsp + 40]  RSP
[rsp + 48]  SS
```

`isr_common` then:

1. executes `cld`;
2. tests the interrupted `CS` at `[rsp + 24]`; if it is a ring-3 selector, it
   executes `swapgs` so `%gs:0` names the per-CPU block again;
3. pushes all 15 general-purpose registers;
4. reads `%gs:0`; if non-zero, executes `fxsave64` into that 512-byte area;
5. aligns `RSP` to 16 bytes, passes the frame pointer and saved-register base to
   `isr_dispatch`, and calls it;
6. takes the returned saved-register base, re-reads `%gs:0`, restores that FPU
   area with `fxrstor64`, pops the 15 registers, drops the vector and error
   code, and, when returning to a ring-3 frame, executes `swapgs` immediately
   before `iretq`.

The FPU save happens before the dispatcher can use SIMD registers. The restore
happens immediately before `iretq`, after the dispatcher has finished. Because
the address lives in `%gs:0`, each CPU saves and restores its own task's state,
including when an exception occurs on an AP. If the pointer is zero, both
operations are skipped.

`sched_resume(rsp)` is the non-interrupt counterpart used to enter an AP's first
idle frame. It restores the FPU area from `%gs:0`, pops the saved registers,
drops vector/error, and executes `iretq`.

The `Frame` structure in `idt.zig` mirrors the CPU frame plus the two values
pushed by the stubs:

```zig
const Frame = extern struct {
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};
```

## Dispatcher behavior

`isr_dispatch(frame, saved_rsp)` in
[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig) handles vectors in
this order:

1. **Reschedule IPI 240**: send LAPIC EOI and return
   `sched.rescheduleInterrupt(saved_rsp)`.
2. **TLB IPI 241**: send LAPIC EOI, call `sched.tlbInterrupt()`, and return
   `saved_rsp` unchanged. The handler scans the lock-free per-CPU mailboxes and
   takes no kernel locks, so it can run while another CPU is waiting for
   shootdown acknowledgements.
3. **TSC-sync IPI 243**: send LAPIC EOI, call `time.tscSyncInterrupt()`, and
   return `saved_rsp` unchanged. The handler samples the local TSC, converts it
   to the BSP timeline through the shared reference, and acknowledges the
   sequence without taking a lock.
4. **Timer 242**: send a LAPIC EOI and return `sched.timerInterrupt(saved_rsp)`.
   This is the timer path on CPU 0 and every AP. An ISA IRQ routed through the
   IOAPIC uses this vector too, so it is acknowledged with a LAPIC EOI only.
5. **Syscall 128**: call `syscall.dispatch(saved_rsp)`. The dispatcher reads the
   number and arguments from the saved frame, validates any user buffer with the
   VMM, and either rewrites `RAX` and returns the same frame or calls a scheduler
   exit/sleep/yield entry that selects a different frame.
6. **Spurious vector 255**: return `saved_rsp` without an EOI.
7. **IRQ 32-47**: send a PIC EOI and a LAPIC EOI. IRQ0 returns
   `sched.timerInterrupt(saved_rsp)`; all other IRQs return `saved_rsp`
   unchanged. This path is used only for legacy PIC-delivered interrupts.
8. **Scheduler vectors 48-54**: call the matching scheduler entry and return
   the saved-register base it selects.
9. **Other exceptions**: print vector number and name, error code, RIP, CS,
   RFLAGS, and (for user-mode frames) RSP/SS.
10. For vector 14 (`#PF`), read `CR2` and print it.
11. If the frame came from ring 3, terminate only the current task: print
    `user fault: task=<id>, terminating task`, convert the vector to
    `-(vector + 1)` (a user `#PF` is `-15`), and return
    `sched.exitUserFault(saved_rsp, status)`. Kernel faults still halt.
12. For vector 3 (`int3`), print `breakpoint handled, resuming` and return
    `saved_rsp`; this is the path both the BSP smoke test and the AP exception
    test use.
13. Any other exception is fatal: print `fatal exception, halting` and exit QEMU
    with the failure code.

The dispatcher uses the global console, which has its own IRQ-safe message
lock, and the scheduler's `task_lock`. Exceptions on an AP therefore save and
restore the correct FPU area, but they still run through the shared IDT and
console paths.

## Local APIC and IPIs

[`src/arch/x86_64/lapic.zig`](../../src/arch/x86_64/lapic.zig) detects xAPIC or
x2APIC from `IA32_APIC_BASE` (MSR `0x1b`). It sets the enable bit on every CPU
before accessing APIC registers.

- xAPIC mode uses a 4 KiB MMIO window reached through the HHDM. The covering
  2 MiB chunk is marked uncached with `vmm.markUncached`.
- x2APIC mode uses MSRs for ID, EOI, TPR, SPIV, and ICR.
- `init()` programs spurious vector `0xff` with the software-enable bit and
  clears TPR.
- `eoi()` acknowledges the current interrupt.
- `sendIpi(destination, vector)` sends a fixed-delivery edge IPI.
- `sendIpiAllButSelf(vector)` uses the all-but-self shorthand.
- `calibrateTimer(hz)` programs a masked one-shot timer, measures 50 ms against
  PIT channel 2, and stores the reload count for that tick rate. It runs on the
  BSP before the APs are released; every CPU reuses the result.
- `startPeriodicTimer(vector)` programs a divided-by-16 periodic timer;
  `stopTimer()` masks it. Normal boot starts it on CPU 0; each AP starts it
  during bring-up.

The scheduler uses vector 240 for reschedule, 241 for TLB shootdown, and 242 for
the per-CPU timer. Timekeeping uses vector 243 for cross-CPU TSC
synchronization. The timer gate sends a LAPIC EOI, which is also the correct
acknowledgement when vector 242 is reached through an IOAPIC redirection entry.
See [SMP](smp.md) and [synchronization](synchronization.md) for the protocols.

## ACPI and the I/O APIC

### ACPI discovery

[`src/acpi.zig`](../../src/acpi.zig) obtains the RSDP from the Limine request in
[`src/limine.zig`](../../src/limine.zig). Under base revision 3 the response is a
physical address, so every table is validated and then read through the HHDM.

`acpi.init()`:

1. checks the `RSD PTR ` signature, the revision, the 20-byte checksum, and, for
   revision 2 or later, the extended length and full checksum;
2. follows the XSDT (or the RSDT on older tables) after validating its
   signature, length, checksum, and physical range;
3. finds the `APIC` MADT, validates it, and parses its entries.

The parser records:

- Processor Local APIC and Processor Local x2APIC entries, including the
  enabled flag;
- I/O APIC entries with their ID, 32-bit MMIO address, and GSI base;
- the Local APIC Address Override;
- every Interrupt Source Override (bus, source IRQ, GSI, polarity, trigger).

Unsupported entry types are skipped. A malformed length or a table that exceeds
the parser's fixed entry limits is rejected rather than read out of bounds. Only
the MADT is interpreted; AML and the ACPI namespace are not.

`acpi.isaIrqRoute(irq)` resolves a bus-0 ISA IRQ. An ISO is authoritative: for
IRQ0 on QEMU q35 it reports GSI 2, active-high, edge-triggered. Only when no ISO
exists does the identity mapping (`GSI == IRQ`) apply, which is GSI 0 for IRQ0.

### IOAPIC driver

[`src/arch/x86_64/ioapic.zig`](../../src/arch/x86_64/ioapic.zig) maps every
MADT-described IOAPIC through the HHDM and marks the covering 2 MiB chunk
uncached with `vmm.markUncached` before the first register access.

`ioapic.init()` reads the IOAPIC ID and version register, derives the number of
redirection entries from the version, and masks every pin. `program()` writes a
redirection entry with:

- the vector and destination APIC ID;
- ISO polarity (`active_low` sets bit 13);
- trigger mode (`level` sets bit 15);
- the mask bit.

The high word is written while the entry is masked, then the low word is
published and unmasked, avoiding a transient mixed destination/vector pair.
`routeIsaIrq()` combines `acpi.isaIrqRoute()` with `program()`, reads the entry
back, and returns both words so the caller can verify vector, destination,
polarity, trigger, and mask state. `setMasked()` and `isMasked()` operate on a
single pin.

An IOAPIC has no EOI register. A fixed interrupt delivered through the IOAPIC is
acknowledged with a Local APIC EOI by the vector's normal handler; no PIC EOI is
sent for an IOAPIC-delivered vector.

## PIC and PIT

### 8259 PIC

[`src/arch/x86_64/pic.zig`](../../src/arch/x86_64/pic.zig) remaps the PIC to
vectors 32-47 and starts with all lines masked. `remap(0x20, 0x28)` configures
the master at `0x20`, the slave at `0x28`, the cascade through master IRQ2, and
8086/88 mode. `mask`, `unmask`, and `sendEoi` operate on the master or slave
data ports as appropriate. Unmasking an IRQ 8-15 also unmasks the master
cascade line.

The kernel unmasks only IRQ0 for the PIT. In normal operation CPU 0 uses its
LAPIC timer, and the PIT path is selected only when ACPI/LAPIC calibration is
unavailable or the `force_pit` test image requests it. Application processors
use their own LAPIC timers and never take IRQ0. The M14 test additionally routes
ISA IRQ0 through its MADT-resolved GSI to vector 242 to verify IOAPIC delivery.

### 8253/8254 PIT

[`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig) programs PIT channel
0 as a square-wave generator (`mode 3`, lobyte/hibyte, binary) with
`base_frequency = 1_193_182` and a divisor clamped to `1..0xffff`. The kernel
uses 100 Hz when the PIT is the fallback timer. The PIT line remains masked until
the caller explicitly unmasks IRQ0.

Channel 2 provides a blocking millisecond reference used to calibrate the LAPIC
timer and the TSC before the APs are released and before CPU 0 starts its timer.
It runs in one-shot mode with the speaker output off, so it does not depend on
interrupts or on channel 0 being active. PIT channel 2 is calibration-only and
is never programmed as an interrupt source.

## Timekeeping and the TSC

[`src/time.zig`](../../src/time.zig) provides the monotonic nanosecond clock.
`time.init(force_ticks)` runs after `sched.init()` and before LAPIC timer
calibration:

1. CPUID leaf 1 reports whether the TSC exists (`EDX[4]`); CPUID leaf
   `0x80000007` reports the non-stop invariant-TSC bit (`EDX[8]`).
2. A forced fallback (the `force_pit` image) selects ticks immediately.
3. A missing, non-invariant, unstable, or out-of-range TSC selects the
   calibrated-tick clocksource and records a `FallbackReason`.
4. A usable TSC is calibrated with three 20 ms PIT-channel-2 samples. The median
   is used as the rate; if the spread exceeds 2%, calibration is rejected as
   unstable. Accepted rates must lie between 100 MHz and 10 GHz.
5. `time.syncAll(online_mask)` broadcasts IPI 243 after AP bring-up. The BSP
   publishes one reference TSC value; each target computes
   `offset = reference - local_raw` and stores it per CPU. `nowNs()` adds that
   offset before converting cycles to nanoseconds, so all CPUs report on the BSP
   timeline. The handler takes no locks and acknowledges a sequence number; the
   BSP spins up to 100,000,000 `pause` iterations for all acknowledgements.
6. `nowNs()` applies a global atomic maximum clamp, so a backward step from a
   clocksource or an offset update is never observed by a caller.
7. In tick mode, CPU 0's scheduler timer increments the tick counter
   (`time.timerTick(0)`), and nanoseconds are derived at the 100 Hz rate.

The public surface also includes `time.info()`, `time.currentSource()`,
`time.tickCount()`, `time.msToTicks()`, and `time.nsToTicks()`. The scheduler
uses the conversion helpers for `sleepMs`/`sleepNs` and timed waits. The
`selectSourceForTest` hook switches between the two sources while preserving
continuity; normal kernel code only reads the selected source.

Cross-CPU agreement is measured as the spread of per-CPU TSC offsets after the
sync. The observed M15 spread was roughly 50-200 microseconds under KVM, which
includes IPI delivery and sampling jitter rather than pure oscillator skew. The
M15 test requires the timestamps taken around a barrier to agree within 50 ms, a
deliberately loose bound for emulated and loaded hosts. The TSC path is only
taken when the CPU reports invariant TSC; TCG typically does not, so it exercises
the tick fallback.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| SSE/FPU enablement | **IMPLEMENTED** | BSP in `kmain`; APs in the assembly stub before Zig code. |
| Per-CPU GS-based state | **IMPLEMENTED** | Extern layout with `%gs:0/8/12` offsets checked at compile time; `KERNEL_GS_BASE` cleared. |
| GDT/TSS with per-CPU #DF IST | **IMPLEMENTED** | `max_cpus = 8`; 8 KiB #DF stacks; DPL3 user code/data selectors. |
| IDT and exception dispatch | **IMPLEMENTED** | Vectors 0-31, CR2 reporting for #PF. |
| IRQ stubs and full GPR save | **IMPLEMENTED** | 15 GPRs; scheduler resumption via returned base. |
| Ring-3 `int 0x80` gate | **IMPLEMENTED** | DPL3 gate 128; `swapgs` on entry and before `iretq`. |
| Per-task TSS `RSP0` | **IMPLEMENTED** | Scheduler writes the current task's 16 KiB kernel-stack top on every switch. |
| User-fault termination | **IMPLEMENTED** | Ring-3 exceptions exit only the task with `-(vector + 1)`; kernel faults halt. |
| Interrupt-time FPU save/restore | **IMPLEMENTED** | Per-CPU `%gs:0`; AP `int3` test. |
| PIC remap/mask/EOI | **IMPLEMENTED** | Only IRQ0 enabled; legacy fallback path. |
| PIT at 100 Hz | **IMPLEMENTED** | Channel 0, mode 3; fallback CPU 0 timer source. |
| PIT channel 2 reference | **IMPLEMENTED** | Calibration-only blocking millisecond delay; never an interrupt source. |
| LAPIC/x2APIC and IPIs | **IMPLEMENTED** | Vectors 240/241/243; spurious gate 255. |
| Per-CPU LAPIC timer | **IMPLEMENTED** | Vector 242, periodic, calibrated from PIT channel 2; CPU 0 and APs. |
| Invariant-TSC detection | **IMPLEMENTED** | CPUID leaf 1 and `0x80000007`; records the fallback reason. |
| TSC calibration | **IMPLEMENTED** | Three 20 ms PIT-channel-2 samples, median rate, 2% stability bound. |
| Cross-CPU TSC sync | **IMPLEMENTED** | IPI 243; per-CPU offsets; BSP reference timeline. |
| Monotonic nanosecond clock | **IMPLEMENTED** | Global atomic maximum clamp; `nowNs()` from any CPU. |
| Tick clocksource fallback | **IMPLEMENTED** | CPU 0's 100 Hz ticks; same `nowNs()` API. |
| ACPI RSDP/XSDT/RSDT/MADT parsing | **IMPLEMENTED** | Signature, length, checksum, and range validation; fixed entry limits. |
| MADT CPU/IOAPIC/ISO data | **IMPLEMENTED** | Local/x2APIC, IOAPIC address/GSI base, LAPIC override, ISOs. |
| ISA IRQ-to-GSI resolution | **IMPLEMENTED** | ISO authoritative; identity mapping only when no ISO exists. |
| IOAPIC driver and routing | **IMPLEMENTED** | Uncached HHDM mapping, mask-all init, redirection read/write, readback. |
| IOAPIC EOI rule | **IMPLEMENTED** | Fixed IOAPIC-delivered vectors use a LAPIC EOI only. |
| MSI/MSI-X and general PCI routing | **PLANNED** | Not implemented; belongs to M18. |

## Related documentation

- [Overview](overview.md)
- [Boot and early bring-up](boot.md)
- [Scheduling](scheduling.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
