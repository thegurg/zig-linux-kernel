# CPU and interrupts

**Purpose:** document x86_64 CPU mode setup, per-CPU state, descriptor tables,
interrupt and exception handling, the legacy PIC/PIT, the local APIC/IPIs, and
the interrupt-facing FPU state.

**Implementation status:** CPU bring-up, GDT/TSS, IDT, exception dispatch,
PIC/PIT, LAPIC/x2APIC, IPI dispatch, and per-CPU interrupt-time FPU
save/restore are **IMPLEMENTED** on every online CPU. The timer remains a
BSP-only PIT interrupt; APs receive reschedule and TLB IPIs. See
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

The GS base is not changed by `iretq` or by task switches; only the pointer at
`%gs:0` changes per task.

## GDT and TSS

[`src/arch/x86_64/gdt.zig`](../../src/arch/x86_64/gdt.zig) builds a flat
long-mode GDT:

| Entry | Selector | Meaning |
| --- | --- | --- |
| 0 | `0x00` | Null descriptor. |
| 1 | `0x08` | 64-bit kernel code, present, DPL0, `L=1`. |
| 2 | `0x10` | Kernel data, present, DPL0, writable, `D/B=1`. |
| 3.. | `0x18 + cpu * 0x10` | Low/high TSS descriptor pair for each CPU. |

- `max_cpus = 8`, so the GDT has `3 + 2 * 8 = 19` qwords.
- CPU 0 is the BSP; its TSS selector is `0x18`. CPU N uses
  `0x18 + N * 0x10`.
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
updates the TSS `RSP0` field; APs use it to install their private stack.

## IDT and gate layout

[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig) owns a 256-entry IDT
of 16-byte gates. `idt.init()` installs:

| Vectors | Handler table | Notes |
| --- | --- | --- |
| 0-31 | `isr_stub_table` | CPU exceptions; vector 8 uses IST1 for `#DF`. |
| 32-47 | `irq_stub_table` | PIC IRQs; only IRQ0 is unmasked. |
| 48-53 | `sched_stub_table` | Scheduler software interrupts. |
| 240, 241 | `ipi_stub_table[0..2]` | Reschedule and TLB-shootdown IPIs. |
| 255 | `ipi_stub_table[2]` | LAPIC spurious-interrupt gate. |

Every gate is a present, DPL0, 64-bit interrupt gate (`type_attr = 0x8e`).
`idt.load()` executes `lidt`; the BSP fills the table, and APs load the same
shared table.

### Scheduler software interrupts

| Vector | Public API | Dispatcher entry |
| --- | --- | --- |
| 48 | `sched.yield()` | `sched.yieldCurrent` |
| 49 | `sched.exit()` | `sched.exitCurrent` |
| 50 | `sched.sleep(ticks)` | `sched.sleepCurrent` |
| 51 | `sched.block()` / mutex/condition waits | `sched.blockCurrent` |
| 52 | `WaitQueue.wait()` | `sched.waitQueueCurrent` |
| 53 | `WaitQueue.waitTimeout(ticks)` | `sched.waitTimeoutCurrent` |

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
2. pushes all 15 general-purpose registers;
3. reads `%gs:0`; if non-zero, executes `fxsave64` into that 512-byte area;
4. aligns `RSP` to 16 bytes, passes the frame pointer and saved-register base to
   `isr_dispatch`, and calls it;
5. takes the returned saved-register base, re-reads `%gs:0`, restores that FPU
   area with `fxrstor64`, pops the 15 registers, drops the vector and error
   code, and executes `iretq`.

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
   `saved_rsp` unchanged.
3. **Spurious vector 255**: return `saved_rsp` without an EOI.
4. **IRQ 32-47**: send a PIC EOI and a LAPIC EOI. IRQ0 returns
   `sched.tick(saved_rsp)`; all other IRQs return `saved_rsp` unchanged.
5. **Scheduler vectors 48-53**: call the matching scheduler entry and return
   the saved-register base it selects.
6. **Other exceptions**: print vector number and name, error code, RIP, CS,
   RFLAGS, and (for user-mode frames) RSP/SS.
7. For vector 14 (`#PF`), read `CR2` and print it.
8. For vector 3 (`int3`), print `breakpoint handled, resuming` and return
   `saved_rsp`; this is the path both the BSP smoke test and the AP exception
   test use.
9. Any other exception is fatal: print `fatal exception, halting` and exit QEMU
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

The scheduler uses vector 240 for reschedule and 241 for TLB shootdown. See
[SMP](smp.md) and [synchronization](synchronization.md) for the protocols.

## PIC and PIT

### 8259 PIC

[`src/arch/x86_64/pic.zig`](../../src/arch/x86_64/pic.zig) remaps the PIC to
vectors 32-47 and starts with all lines masked. `remap(0x20, 0x28)` configures
the master at `0x20`, the slave at `0x28`, the cascade through master IRQ2, and
8086/88 mode. `mask`, `unmask`, and `sendEoi` operate on the master or slave
data ports as appropriate. Unmasking an IRQ 8-15 also unmasks the master
cascade line.

The kernel unmasks only IRQ0 for the PIT. The PIC and PIT are the only timer
source; there is no APIC timer or IOAPIC routing yet. APs receive only IPIs.

### 8253/8254 PIT

[`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig) programs PIT channel
0 as a square-wave generator (`mode 3`, lobyte/hibyte, binary) with
`base_frequency = 1_193_182` and a divisor clamped to `1..0xffff`. The kernel
uses 100 Hz. The PIT line remains masked until the caller explicitly unmasks
IRQ0.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| SSE/FPU enablement | **IMPLEMENTED** | BSP in `kmain`; APs in the assembly stub before Zig code. |
| Per-CPU GS-based state | **IMPLEMENTED** | Extern layout with `%gs:0/8/12` offsets checked at compile time. |
| GDT/TSS with per-CPU #DF IST | **IMPLEMENTED** | `max_cpus = 8`; 8 KiB #DF stacks. |
| IDT and exception dispatch | **IMPLEMENTED** | Vectors 0-31, CR2 reporting for #PF. |
| IRQ stubs and full GPR save | **IMPLEMENTED** | 15 GPRs; scheduler resumption via returned base. |
| Interrupt-time FPU save/restore | **IMPLEMENTED** | Per-CPU `%gs:0`; AP `int3` test. |
| PIC remap/mask/EOI | **IMPLEMENTED** | Only IRQ0 enabled. |
| PIT at 100 Hz | **IMPLEMENTED** | Channel 0, mode 3; BSP only. |
| LAPIC/x2APIC and IPIs | **IMPLEMENTED** | Vectors 240/241; spurious gate 255. |
| APIC timer / IOAPIC routing | **PLANNED** | No per-CPU timer or IOAPIC yet. |
| User-mode interrupt frames | **PLANNED** | `from_user` reporting exists, but user mode is not implemented. |

## Related documentation

- [Overview](overview.md)
- [Boot and early bring-up](boot.md)
- [Scheduling](scheduling.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
