# CPU and interrupts

**Purpose:** document x86_64 CPU mode setup, descriptor tables, interrupt and
exception handling, the legacy PIC/PIT, and the interrupt-facing FPU state.

**Implementation status:** CPU bring-up, GDT/TSS, IDT, exception dispatch,
PIC/PIT, and interrupt-time FPU save/restore are **IMPLEMENTED** on the
bootstrap processor. APs load the shared GDT/IDT but do not take timer
interrupts, and the AP exception path is not yet SMP-safe.

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

The BSP calls `enableSse()` at the very start of `kmain`. APs call it in
`ap_main` after loading the GDT, TSS, and IDT. Note that APs currently execute
Zig code in `ap_main` before `cpu.enableSse()`; this is recorded as a technical
debt item because it relies on the compiler not emitting SSE before that call.

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
`ltr` with that CPU's TSS selector. `gdt.setKernelStack(cpu, top)` updates the
TSS `RSP0` field; APs use it to install their private stack.

The AP stub switches to the private stack in [`smp_entry.S`](../../src/arch/x86_64/smp_entry.S)
before calling `ap_main`, which then installs that stack as the CPU's TSS
`RSP0`.

## IDT and gate layout

[`src/arch/x86_64/idt.zig`](../../src/arch/x86_64/idt.zig) owns a 256-entry IDT
of 16-byte gates. `idt.init()` installs:

| Vectors | Handler table | Notes |
| --- | --- | --- |
| 0-31 | `isr_stub_table` | CPU exceptions; vector 8 uses IST1 for `#DF`. |
| 32-47 | `irq_stub_table` | PIC IRQs; only IRQ0 is unmasked. |
| 48-53 | `sched_stub_table` | Scheduler software interrupts. |

Every gate is a present, DPL0, 64-bit interrupt gate (`type_attr = 0x8e`).
`idt.load()` executes `lidt`; the BSP fills the table, and APs only need to
load it because the table is shared.

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
3. reads `current_fpu_state`; if non-zero, executes `fxsave64` into that
   512-byte area;
4. aligns `RSP` to 16 bytes, passes the frame pointer and saved-register base to
   `isr_dispatch`, and calls it;
5. takes the returned saved-register base, restores the selected
   `current_fpu_state` with `fxrstor64`, pops the 15 registers, drops the vector
   and error code, and executes `iretq`.

The FPU save happens before the dispatcher can use SIMD registers. The restore
happens immediately before `iretq`, after the dispatcher has finished, so the
resumed task sees the state saved on its last interrupt. If
`current_fpu_state` is zero, both operations are skipped; this lets pre-scheduler
exceptions use the fault-test path before any task owns an FPU area.

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

1. **IRQ 32-47**: send EOI to the PIC. IRQ0 returns
   `sched.tick(saved_rsp)`; all other IRQs return `saved_rsp` unchanged.
2. **Scheduler vectors 48-53**: call the matching scheduler entry and return
   the saved-register base it selects.
3. **Other exceptions**: print vector number and name, error code, RIP, CS,
   RFLAGS, and (for user-mode frames) RSP/SS.
4. For vector 14 (`#PF`), read `CR2` and print it.
5. For vector 3 (`int3`), print `breakpoint handled, resuming` and return
   `saved_rsp`; this is the path the smoke test uses to prove the handler
   returns.
6. Any other exception is fatal: print `fatal exception, halting` and exit QEMU
   with the failure code.

The dispatcher uses the global console and global scheduler state. It does not
take a lock and has no per-CPU dispatch state. On an AP, an exception or NMI
would therefore use the BSP's `current_fpu_state` and global scheduler/console
variables. This is a known SMP safety gap; APs currently do not enter the
scheduler or take timer interrupts.

## PIC and PIT

### 8259 PIC

[`src/arch/x86_64/pic.zig`](../../src/arch/x86_64/pic.zig) remaps the PIC to
vectors 32-47 and starts with all lines masked. `remap(0x20, 0x28)` configures
the master at `0x20`, the slave at `0x28`, the cascade through master IRQ2, and
8086/88 mode. `mask`, `unmask`, and `sendEoi` operate on the master or slave
data ports as appropriate. Unmasking an IRQ 8-15 also unmasks the master
cascade line.

The kernel unmasks only IRQ0 for the PIT. There is no IOAPIC, MSI, APIC timer,
or other interrupt-routing support yet.

### 8253/8254 PIT

[`src/arch/x86_64/pit.zig`](../../src/arch/x86_64/pit.zig) programs PIT channel
0 as a square-wave generator (`mode 3`, lobyte/hibyte, binary) with
`base_frequency = 1_193_182` and a divisor clamped to `1..0xffff`. The kernel
uses 100 Hz. The PIT line remains masked until the caller explicitly unmasks
IRQ0.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| SSE/FPU enablement | **IMPLEMENTED** | BSP before Zig code; APs after GDT/IDT load. |
| GDT/TSS with per-CPU #DF IST | **IMPLEMENTED** | `max_cpus = 8`; 8 KiB #DF stacks. |
| IDT and exception dispatch | **IMPLEMENTED** | Vectors 0-31, CR2 reporting for #PF. |
| IRQ stubs and full GPR save | **IMPLEMENTED** | 15 GPRs; scheduler resumption via returned base. |
| Interrupt-time FPU save/restore | **IMPLEMENTED** | `fxsave64`/`fxrstor64` around the dispatcher. |
| PIC remap/mask/EOI | **IMPLEMENTED** | Only IRQ0 enabled. |
| PIT at 100 Hz | **IMPLEMENTED** | Channel 0, mode 3. |
| LAPIC/IOAPIC/APIC timer/IPI | **PLANNED** | No local APIC programming exists. |
| Per-CPU exception/NMI handling | **PLANNED** | AP exception path uses global BSP state. |
| User-mode interrupt frames | **PLANNED** | `from_user` reporting exists, but user mode is not implemented. |

## Related documentation

- [Overview](overview.md)
- [Boot and early bring-up](boot.md)
- [Scheduling](scheduling.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
