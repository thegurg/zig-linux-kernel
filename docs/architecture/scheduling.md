# Scheduling

**Purpose:** describe the task model, per-CPU round-robin scheduler, task
lifecycle operations, idle tasks, blocking primitives, and FPU/SIMD context
switching.

**Implementation status:** per-CPU scheduling, pinned task creation, AP idle
tasks, cross-CPU wakeups, per-CPU FPU context, and timer-driven preemption on
every CPU are **IMPLEMENTED**. CPU 0 uses the PIT; APs use their LAPIC timers.
Deadlines and tick counters are per CPU. See
[technical debt](../development/technical-debt.md).

## Scope

The scheduler in [`src/sched.zig`](../../src/sched.zig) provides:

- preemptive round-robin scheduling on every CPU: IRQ0 at 100 Hz on the BSP and
  a periodic LAPIC timer on each AP;
- per-CPU tick counters, current task, idle task, scan cursor, and pending
  sleep/wait state;
- cooperative `yield` and `exit` software interrupts;
- timer-based sleep and indefinite block/wake;
- wait queues, mutexes, and condition variables that wake tasks across CPUs;
- one idle task per online CPU, each halting when no task is ready;
- reuse of finished task slots;
- per-task FPU/SIMD state saved with `fxsave64`/`fxrstor64`;
- reschedule IPIs and TLB-shootdown IPIs on the target CPU.

It does **not** provide priorities, load balancing, task migration, an APIC
timer on CPU 0, IOAPIC routing, address-space switching, or task join. Tasks are
pinned to the CPU selected at creation.

## Task model

`max_tasks = 32` and `max_cpus = 8`. A task is represented by `Task`:

| Field | Type | Purpose |
| --- | --- | --- |
| `name` | `[]const u8` | Diagnostic name. |
| `rsp` | `u64` | Saved stack pointer / saved-register frame base. |
| `state` | `TaskState` | `idle`, `ready`, `running`, `blocked`, or `finished`. |
| `ticks` | `u64` | Number of timer ticks this task has run. |
| `wake_tick` | `u64` | Deadline for sleep/timed wait; `~0` for indefinite block. |
| `wake_reason` | `WakeReason` | `none`, `signal`, or `timeout`. |
| `fpu_state` | `FpuState align(16)` | 512-byte FXSAVE area. |
| `id` | `u32` | Monotonic task ID used by wait queues. |
| `index` | `usize` | Slot in the global task table. |
| `cpu` | `u32` | CPU this task is pinned to. |
| `is_idle` | `bool` | True for a per-CPU idle task. |

`FpuState` is `[512]u8`, the size of an FXSAVE area. `Entry` is
`*const fn () callconv(.c) void`.

### Task table and reserved slots

The scheduler keeps a global `tasks: [32]Task` array, a `task_count`, one
`CpuState` per CPU, and global counters. Slots are allocated from index 1
onward; slot 0 is permanently the boot context:

| Index | Task | ID | State after `init` |
| --- | --- | --- | --- |
| 0 | `boot` | 0 | `running` on CPU 0 |
| 1 | BSP `idle` | 1 | `idle` on CPU 0 |

Each AP calls `sched.initCpu` and receives its own idle task in the next free
slot. There is no fixed `idle_index`; `CpuState.idle` points at the per-CPU idle
task. Idle tasks are created with `ensureIdleLocked` on 8 KiB static stacks in
`sched.zig`. `next_id` starts at 2. `tasks[0].rsp` is 0 because the boot context
is already running on the kernel stack.

User tasks use caller-owned stacks; the selftests use static 16 KiB stacks in
[`src/main.zig`](../../src/main.zig) and
[`src/smp.zig`](../../src/smp.zig).

## Per-CPU state

`CpuState` contains:

| Field | Purpose |
| --- | --- |
| `current` | Task currently running on this CPU. |
| `idle` | This CPU's idle task. |
| `next_scan` | Round-robin scan cursor. |
| `sleep_request` | Pending duration stored before `int $50`. |
| `wait_request` | Pending `WaitQueue` stored before `int $52`. |
| `wait_timeout_request` | Pending queue/duration stored before `int $53`. |

The `cpu.PerCpu` block holds the FPU pointer at `%gs:0`, the CPU index at
`%gs:8`, and the LAPIC ID at `%gs:12`. See [SMP](smp.md) for the layout and GS
base setup.

`online_mask` has bit N set once CPU N has installed scheduler state. It is used
to decide whether a reschedule or TLB IPI can be sent to a CPU.

## Initialization

`sched.init()` runs on the BSP:

1. acquires `task_lock`;
2. builds the FPU template with `initFpuTemplate()`;
3. resets counters, IDs, per-CPU state, and the online mask;
4. creates the boot task in slot 0 and the BSP idle task;
5. sets `cpu_state[0].current = &tasks[0]`,
   `cpu_state[0].next_scan = 1`, and `%gs:0` to the boot task's FPU area;
6. sets `enabled = true` and `initialized = true`.

`initFpuTemplate()` saves the current FPU state, executes `fninit` and zeroes
XMM0-XMM15, saves that clean state as `fpu_template`, then restores the
original state. New tasks and idle tasks inherit this clean template.

## Creating a task

`sched.create(name, entry, stack)` pins the task to the calling CPU.
`sched.createOn(cpu, name, entry, stack)` pins it to an explicit CPU:

1. rejects calls before initialization or an out-of-range CPU;
2. acquires `task_lock` through its per-acquisition `IrqSpinLock` guard;
3. finds a finished slot above slot 0, or appends a new slot if
   `task_count < max_tasks`;
4. builds an initial interrupt frame at the top of the caller-owned stack with
   `initialFrame`;
5. assigns a fresh ID, writes the task entry, `cpu`, and `is_idle = false`, and
   marks it `ready`;
6. if the target CPU is not the caller, sends a reschedule IPI after the task is
   visible in the table.

`initialFrame` requires at least 512 bytes of stack and at least 256 bytes below
the aligned top. It sets the entry stack pointer to 8 bytes below the aligned
top, then builds an `initial_frame_qwords` frame
(`15 saved registers + 2 vector/error + 5 iret qwords = 22` qwords):

- the 15 register slots are zeroed;
- `frame[17]` is the entry address (RIP);
- `frame[18]` is the kernel code selector;
- `frame[19]` is `0x202` (interrupts enabled);
- `frame[20]` is the entry stack pointer;
- `frame[21]` is the kernel data selector.

The normal `isr_common` epilogue can therefore enter the task with `iretq`
without a separate task-start trampoline.

The 8-byte slot at the entry stack pointer is initialized to the address of
`taskReturn`, a naked trampoline that executes `int $49` (the scheduler exit
vector). A task entry that returns instead of calling `sched.exit()` therefore
exits cleanly instead of `ret`-ing into uninitialized stack memory. The
trampoline starts with `RSP % 16 == 0` rather than the usual callee alignment,
so it is assembly-only and does not call Zig code before entering the
scheduler.

### Slot reuse

`findSlotLocked` scans from slot 1 for a task in the `finished` state. If none is
found and the table is not full, it returns `task_count` as the next slot. A
finished slot keeps its old stack pointer until it is overwritten, but the caller
must supply a valid stack to `create`.

## Scheduling operations

### AP scheduler entry

`sched.initCpu(index, lapic_id)`:

1. refuses CPU 0, an uninitialized scheduler, or an out-of-range index;
2. creates the CPU's idle task with `ensureIdleLocked`;
3. sets `current` and `next_scan` to the idle task, marks it `running`;
4. sets the CPU's bit in `online_mask`;
5. points `%gs:0` at the idle task's FPU area.

The AP then starts its periodic LAPIC timer and calls `sched.enterScheduler()`,
which re-checks the idle task, leaves the AP's boot stack, and resumes the idle
initial frame through `sched_resume`. The frame enables interrupts on `iretq`,
and the idle entry executes `sti; hlt`. The pending LAPIC timer then fires on
vector 242.

### Timer ticks (per CPU)

`timerInterrupt(saved_rsp)` is called by IRQ0 on the BSP and by the LAPIC timer
on each AP:

1. if the scheduler is not initialized, return the saved frame;
2. acquire `task_lock`;
3. increment this CPU's `cpu_ticks` entry;
4. wake every blocked task pinned to this CPU whose deadline has passed
   (`wakeBlockedLocked`);
5. save the current task's `rsp` and increment its `ticks`;
6. if scheduling is disabled, return the saved frame;
7. find the next `ready` task pinned to this CPU (`pickNextLocked`);
8. if one exists, park the current task (`running` -> `ready`, except an idle
   task which becomes `idle`) and switch to the next task;
9. otherwise return the saved frame and continue the current task.

Deadlines are compared against the owning CPU's counter. A sleeper on an AP is
woken by that AP's LAPIC timer, so no cross-CPU IPI is needed. Explicit wakeups
from another CPU still send the reschedule IPI. CPU 0 continues to take IRQ0;
APs take vector 242 and never receive IRQ0.

### Reschedule IPI

`rescheduleInterrupt(saved_rsp)` runs on the target CPU for vector 240:

1. acquires `task_lock` and records the reschedule in `reschedule_count`;
2. saves the current task's `rsp`;
3. if scheduling is enabled, asks `pickNextLocked` for a ready task pinned to
   this CPU;
4. parks the idle current task or requeues a normal current task, then switches
   to the selected task.

This is how a task created on an AP, or woken on another CPU, starts running.

### TLB shootdown IPI

`sched.shootdownTlb(virt)` runs after the VMM has cleared a PTE and released its
page-table lock. It:

1. snapshots `online_mask` and excludes the current CPU (the local `invlpg` has
   already happened);
2. allocates a unique sequence number and, for every target, writes the virtual
   address and sequence into the shooter's mailbox row, then sends IPI 241;
3. waits until each target's acknowledgement column is at least that sequence.

`tlbInterrupt()` scans every shooter's mailbox, invalidates each sequence it has
not acknowledged, and writes the acknowledgement. The handler takes no locks, so
a CPU waiting for acknowledgements can still service a request from another CPU.
There is no timeout: a target with interrupts disabled keeps the IPI pending
until it enables interrupts. Callers must therefore run `unmapPage` with
interrupts enabled when other CPUs are online.

### Yield

`yieldCurrent(saved_rsp)` saves the current `rsp`, finds the next ready task on
the same CPU, and switches. If none exists, it returns the saved frame. It does
not run deadline wakeups; those are handled by the timer tick.

### Exit

`exitCurrent(saved_rsp)` marks the current task `finished`, increments
`finished_counter`, and switches to the next ready task. If none exists, it
switches to this CPU's idle task. If an idle task itself exits, the CPU halts
forever. `sched.exit()` is declared `noreturn` and halts if the software
interrupt ever returns.

### Sleep

`sched.sleep(duration)` saves interrupts, stores a pending duration in the
current CPU's `sleep_request`, and executes `int $50`. `sleepCurrent` marks the
task `blocked`, sets `wake_tick = cpu_ticks[this_cpu] + duration`, increments
`blocked_counter`, and switches to the next ready task or the idle task. The
owning CPU's timer tick wakes the task with `WakeReason.timeout` once the
deadline is reached. A duration of zero is a no-op. The idle task cannot sleep.

### Indefinite block and wake

`sched.block()` executes `int $51`. `blockCurrent` marks the task `blocked`,
sets `wake_tick = ~0`, increments `blocked_counter`, and switches away.
`sched.wake(task)` acquires `task_lock` and calls `wakeLocked(task, .signal)`,
which only succeeds if the task is still `blocked`; it then marks the task
`ready`, records the reason, decrements `blocked_counter`, and sends a
reschedule IPI when the task is pinned to another CPU.

`sched.blockedCount()` exposes the blocked counter for test handshakes.

### Wait queue operations

`WaitQueue.wait()` and `waitTimeout()` execute software interrupts 52 and 53
after disabling interrupts. The dispatcher enqueues the current task ID,
compacts stale entries, and blocks the task while holding `task_lock`. See
[synchronization](synchronization.md) for the wait-queue, mutex, and condition
semantics and the lost-wakeup rules.

### Stop and resume

`sched.stop()` acquires `task_lock` and sets `enabled = false`. Timer ticks
still increment the local CPU's counter and wake local blocked tasks, but no CPU
switches tasks. `sched.resumeScheduling()` sets `enabled = true` again. The selftest
calls `stopTimer()` (which disables interrupts, masks IRQ0, and calls
`sched.stop()`) before the BSP-only tests, then re-enables scheduling before the
M11 SMP tests.

## Idle tasks

Each CPU has its own idle task. Its entry is:

```zig
fn idleEntry() callconv(.c) void {
    while (true) {
        asm volatile ("sti; hlt");
    }
}
```

An idle task cannot block, sleep, or contend for a mutex; the blocking
primitives explicitly return without blocking when the current task is idle.
When every other task on a CPU is blocked or finished, the scheduler switches to
that CPU's idle task, which enables interrupts and halts until the next IRQ or
IPI.

## Counters and diagnostics

| API | Meaning |
| --- | --- |
| `sched.ticks()` | This CPU's tick counter. |
| `sched.ticksOn(cpu)` | Tick counter for a specific CPU. |
| `sched.finishedCount()` | Tasks that have exited. |
| `sched.blockedCount()` | Tasks currently blocked. |
| `sched.onlineCount()` | CPUs with scheduler state installed. |
| `sched.rescheduleCount()` | Reschedule IPIs handled. |
| `sched.tlbShootdownCount()` | TLB shootdown requests issued. |
| `sched.stats()` | Snapshot of ticks, task count, finished, blocked, current ID, enabled, and online CPUs. |

These are global counters read with atomic loads; most are not protected by a
lock, so they are diagnostics rather than synchronization primitives.

## FPU/SIMD context switching

Each task owns a 16-byte-aligned 512-byte `FpuState`. The assembly entry path
saves the interrupted task's state with `fxsave64` before calling the
dispatcher, and restores the selected task's state with `fxrstor64` before
`iretq` (see [CPU and interrupts](cpu-interrupts.md)).

The save/restore address comes from `%gs:0`, which is per-CPU. The scheduler
updates it in `switchTaskLocked` and in `initCpu`; `sched_resume` also restores
from it when an AP enters its first idle frame. The boot path points `%gs:0` at
a scratch FXSAVE area, so pre-scheduler exceptions have a valid destination.

The M9 selftest creates two tasks that load distinct XMM0 patterns, yield to each
other inside one inline-assembly block, and store XMM0 afterwards. The M11 AP
test does the same with XMM5 and an `int3` on CPU 1.

## Self-test coverage

The scheduler is exercised by the selftest image described in
[testing](../development/testing.md):

| Test | What it verifies |
| --- | --- |
| M2 timer/scheduler | 30 PIT ticks pass; two workers run, yield, and exit; finished count reaches 2. |
| M3 lifecycle | A third worker reuses a finished slot and exits. |
| M4 sleep | A worker sleeps for 5 ticks and wakes after its deadline. |
| M5 block/wake | A worker blocks; the boot task observes `blockedCount()` and wakes it explicitly. |
| M6 wait queue | A worker blocks on a wait queue and is woken with `wakeOne`. |
| M7 timed wait | A timed waiter times out without a signal, then a second waiter is signalled before its deadline. |
| M8 mutex/condition | Two mutex workers serialize a yield inside the critical section with zero overlap; a condition wait/signal handshake completes. |
| M9 FPU | Two tasks keep distinct XMM0 patterns across a cooperative yield and interleave. |
| M11 SMP workers | APs run pinned tasks; the shared counter reaches 400,000 with zero overlap. |
| M11 cross-CPU wake | A task blocked on CPU 1 is woken from the BSP through a reschedule IPI. |
| M11 AP exception/FPU | An AP task preserves XMM5 across `int3`. |
| M11 TLB shootdown | `unmapPage` after AP bring-up increments the shootdown counter. |
| M12 concurrent heap | Every CPU allocates, writes, verifies, and frees blocks concurrently with zero errors. |
| M12 IRQ-off TLB | A shootdown targeting a CPU that has interrupts disabled completes after that CPU enables them and services the pending IPI. |
| M12 concurrent TLB | Every AP maps and unmaps a private page concurrently; all shootdowns complete with zero errors. |
| M13 AP ticks/sleep | One sleeper per AP advances that AP's tick counter and wakes locally after `sched.sleep`. |
| M13 AP preemption | Two CPU-bound tasks pinned to CPU 1 each observe the other's counter while both are running, proving timer-driven preemption. |

## Limitations

- **No migration or balancing:** every task is pinned at creation.
- **No priorities:** round-robin over ready tasks per CPU.
- **Fixed task limit:** 32 slots total, including the boot task and one idle task
  per CPU.
- **Static stacks:** tasks use caller-owned stacks; there is no guard page or
  automatic stack allocation.
- **No join/wait-for-exit API**; tests poll `finishedCount()`.
- **No address-space switching**; all tasks share the kernel page tables.
- **Idle cannot block**; blocking calls return immediately for idle tasks.
- **BSP timer differs:** CPU 0 still uses the PIT; APs use LAPIC timers. The two
  sources are calibrated to the same nominal rate but are not phase-locked.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Per-CPU round-robin scheduler | **IMPLEMENTED** | Pinned tasks, per-CPU idle and current state. |
| BSP timer preemption | **IMPLEMENTED** | IRQ0 at 100 Hz, CPU 0 only. |
| Per-CPU tick counters | **IMPLEMENTED** | Independent `cpu_ticks` entries; `ticksOn(cpu)`. |
| Cooperative yield/exit | **IMPLEMENTED** | Vectors 48 and 49. |
| Sleep and explicit block/wake | **IMPLEMENTED** | Vectors 50 and 51; local deadline scanning. |
| Wait queues and timed waits | **IMPLEMENTED** | Vectors 52 and 53; SMP-aware task IDs. |
| Mutex and condition variable | **IMPLEMENTED** | Ownership transfer; blocked-before-unlock. |
| Per-CPU idle tasks and slot reuse | **IMPLEMENTED** | 8 KiB idle stacks; task limit 32. |
| FPU/SIMD context switching | **IMPLEMENTED** | Per-task 512-byte FXSAVE area; `%gs:0` pointer. |
| Cross-CPU wakeups | **IMPLEMENTED** | Reschedule IPI 240. |
| TLB shootdown | **IMPLEMENTED** | Lock-free per-CPU mailboxes; IPI 241; waits for every acknowledgement. |
| AP timer preemption | **IMPLEMENTED** | Periodic LAPIC timer, vector 242, calibrated from the PIT. |
| CPU 0 LAPIC timer / IOAPIC | **PLANNED** | CPU 0 still uses PIT IRQ0. |
| Priorities, migration, join | **PLANNED** | Not implemented. |

## Related documentation

- [Overview](overview.md)
- [CPU and interrupts](cpu-interrupts.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Testing](../development/testing.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
