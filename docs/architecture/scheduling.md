# Scheduling

**Purpose:** describe the task model, per-CPU scheduler, task lifecycle
operations, priorities, the deadline queue, join, idle tasks, blocking
primitives, and FPU/SIMD context switching.

**Implementation status:** per-CPU scheduling, pinned task creation, AP idle
tasks, cross-CPU wakeups, per-CPU FPU context, timer-driven preemption on every
CPU, a per-CPU deadline heap, priority levels with ageing, and single-waiter
task join are **IMPLEMENTED**. CPU 0 and every AP use a periodic LAPIC timer;
CPU 0 keeps the PIT IRQ0 path as a fallback. Deadlines and tick counters are per
CPU. Task migration and load balancing remain **PLANNED** for M20. See
[technical debt](../development/technical-debt.md).

## Scope

The scheduler in [`src/sched.zig`](../../src/sched.zig) provides:

- preemptive per-CPU scheduling with round-robin tie-breaking: a periodic LAPIC
  timer on vector 242, with the 100 Hz PIT IRQ0 path as CPU 0's fallback;
- per-CPU tick counters, current task, idle task, scan cursor, and pending
  sleep/wait state;
- cooperative `yield` and `exit` software interrupts;
- timer-based sleep and indefinite block/wake;
- `sleepMs`/`sleepNs` helpers that round a duration up to scheduler ticks;
- a per-CPU min-heap of finite deadlines, replacing the full blocked-task scan;
- priority levels (`low`, `normal`, `high`) with wait-ageing starvation
  avoidance;
- single-waiter `join` with an exit status and a millisecond timeout, plus
  `detach` and `exitWith`;
- wait queues, mutexes, and condition variables that wake tasks across CPUs;
- one idle task per online CPU, each halting when no task is ready;
- reuse of finished task slots once joinable tasks are reaped or detached;
- per-task FPU/SIMD state saved with `fxsave64`/`fxrstor64`;
- reschedule IPIs and TLB-shootdown IPIs on the target CPU.

It does **not** provide task migration, load balancing, multiple joiners per
task, general PCI/MSI interrupt routing, or address-space switching. Tasks are
pinned to the CPU selected at creation. The monotonic clocksource itself is
documented in [CPU and interrupts](cpu-interrupts.md#timekeeping-and-the-tsc).

## Task model

`max_tasks = 32` and `max_cpus = 8`. A task is represented by `Task`:

| Field | Type | Purpose |
| --- | --- | --- |
| `name` | `[]const u8` | Diagnostic name. |
| `rsp` | `u64` | Saved stack pointer / saved-register frame base. |
| `pml4_phys` | `u64` | Address space installed while this task runs; the kernel root for kernel tasks. |
| `kernel_stack_top` | `u64` | TSS `RSP0` value installed before the task runs. |
| `is_user` | `bool` | True for a ring-3 task; its low half is private. |
| `state` | `TaskState` | `idle`, `ready`, `running`, `blocked`, or `finished`. |
| `ticks` | `u64` | Number of timer ticks this task has run. |
| `wake_tick` | `u64` | Deadline for sleep/timed wait; `~0` for indefinite block. |
| `wake_reason` | `WakeReason` | `none`, `signal`, or `timeout`. |
| `fpu_state` | `FpuState align(16)` | 512-byte FXSAVE area. |
| `priority` | `Priority` | `low`, `normal`, or `high`; biases selection. |
| `ready_tick` | `u64` | Tick at which the task last became ready; used for ageing. |
| `exit_status` | `i32` | Status published by `exitWith` for a joiner. |
| `joinable` | `bool` | Whether the slot is retained for `join`/`detach`. |
| `join_reaped` | `bool` | True once the exit status has been consumed or detached. |
| `join_waiter_id` | `u32` | Single joiner task ID, or `no_waiter`. |
| `id` | `u32` | Monotonic task ID used by wait queues and deadlines. |
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

A ring-3 task has two stacks: a 16 KiB kernel stack used by `int 0x80`,
interrupts, and the initial `iretq` frame, and a four-page user stack mapped in
the private low half. Kernel tasks use their caller-owned stack for both roles.

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
| `join_target` | Joinable task stored before `int $54`. |
| `exit_status` | Pending status copied into the task by `exitCurrent`. |

Each CPU also owns a `DeadlineQueue`, a binary min-heap of at most `max_tasks`
`(deadline, task_id)` entries ordered by deadline and then task ID. An entry
exists only while a task blocked on that CPU has a finite deadline; an
indefinite block or wait-queue block does not enter the heap. `sleep`,
`WaitQueue.waitTimeout`, and a timed `join` push an entry; expiry pops it, and an
explicit `wake` removes it early so the task is not woken twice. The heap holds
at most one entry per blocked task, so a stale entry cannot accumulate.
`deadlinePushCount()`, `deadlinePopCount()`, and `deadlineDepthOn(cpu)` are
diagnostic counters.

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
`sched.createOn(cpu, name, entry, stack)` pins it to an explicit CPU.
`createJoinable`/`createJoinableOn` retain the slot until `join` or `detach`, and
`createWithPriorityOn` selects a priority. All variants share `createLocked`:

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

### Creating a user task

`sched.createUser(name, entry, kernel_stack, pml4_phys, user_stack_top, arg,
options)` creates a ring-3 task pinned to the selected CPU (CPU 0 by default).
It validates that the address space and both entry points are in the low half,
then builds `initialFrameUser`, a 22-qword frame whose `iretq` target is
`CS = 0x1b`, `SS = 0x23`, `RIP = entry`, `RSP = user_stack_top`, and
`RDI = arg`. The frame itself lives on the supplied kernel stack, which is
shared through the high half of every address space.

The caller owns the address space, the mapped user pages, and the kernel stack.
`sched` does not copy or validate the ELF image. The M17 process layer
([`src/process.zig`](../../src/process.zig)) supplies those resources from the
general loader and a heap-allocated kernel stack, then keeps the finished task
slot and exit status until `reap`. The M16 fixture path still calls `createUser`
directly. Finished user tasks are torn down by the scheduler, not by `sched`'s
caller.

`switchTaskLocked` installs `next.pml4_phys` in `CR3`, writes
`next.kernel_stack_top` to the TSS `RSP0`, and then restores FPU state. Kernel
tasks store the kernel PML4, so switching to and from them is a no-op at the
page-table level.

### Slot reuse

`findSlotLocked` scans from slot 1 for a task in the `finished` state whose
exit status has been consumed or that was never joinable (`join_reaped`). A
finished joinable task that has not been joined or detached keeps its slot and
`*Task` pointer valid. If no reusable slot is found and the table is not full,
the next slot is `task_count`. A finished slot keeps its old stack pointer until
it is overwritten, but the caller must supply a valid stack to `create`.

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
3. increment this CPU's `cpu_ticks` entry and call `time.timerTick(cpu)` so the
   fallback clocksource advances from CPU 0 ticks;
4. pop every deadline at or before the new tick from this CPU's heap and wake
   those tasks (`wakeExpiredLocked`);
5. save the current task's `rsp` and increment its `ticks`;
6. if scheduling is disabled, return the saved frame;
7. find the next runnable task pinned to this CPU (`pickNextLocked`, highest
   effective priority score first);
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

`exitCurrent(saved_rsp)` marks the current task `finished`, copies the CPU's
pending `exit_status` into the task, increments `finished_counter`, and wakes a
single registered joiner with `WakeReason.signal`. It then switches to the next
runnable task. If none exists, it switches to this CPU's idle task. If an idle
task itself exits, the CPU halts forever. `sched.exit()` is declared `noreturn`
and halts if the software interrupt ever returns; `sched.exitWith(status)` sets
the status that `join` reports.

Ring-3 exits go through `sched.exitUser(saved_rsp, status)` or
`sched.exitUserFault(saved_rsp, status)`. `finishTaskLocked` detaches the
private PML4, switches `CR3` to the kernel root, and marks the task finished
while `task_lock` is held. The detached low half is destroyed by
`destroyReleasedAddressSpace` only after the lock is released, so teardown never
takes `pmm.lock` under `task_lock`. Because user address spaces are pinned to one
CPU, this teardown needs no remote TLB shootdown. A user exception is converted
to status `-(vector + 1)`; a user `#PF` therefore exits with `-15`. Kernel faults
still take the fatal path.

A non-joinable finished slot is immediately reusable. A joinable slot stays
allocated with its status until `join` consumes it or `detach` releases it, so a
`*Task` pointer passed to `join` cannot be recycled underneath the joiner.

### Join

`sched.createJoinable`/`createJoinableOn` create a task with
`joinable = true`. `sched.join(task, timeout_ms)`:

1. saves interrupts, acquires `task_lock`, and validates that the scheduler is
   enabled, the target is joinable, not already reaped, and not the caller;
2. if the target is already `finished`, marks it reaped and returns
   `already_finished` with its status;
3. rejects a second concurrent joiner with `invalid`;
4. records the caller in the target's single `join_waiter_id` slot, sets a
   finite deadline in the deadline heap (or an indefinite deadline when
   `timeout_ms == 0`), and executes `int $54` to block;
5. on wake, returns `joined` with the status if a signal arrived after the target
   finished, or `timeout` if the deadline expired first.

Only one joiner is supported per task. Calling `join` again after a successful
join returns `invalid` because the slot may have been reused by another task.
`sched.detach(task)` clears `joinable` and releases a finished slot without
waiting; the task pointer becomes unsafe as soon as that slot is reused.

### Priorities and starvation policy

`Priority` has three levels and a base score:

| Priority | Base score | Matches `normal` after |
| --- | --- | --- |
| `low` | 0 | 10 waiting ticks |
| `normal` | 10 | — |
| `high` | 20 | 20 waiting ticks |

`pickNextLocked` scans ready tasks pinned to this CPU and selects the highest
`base_score + waiting_age`, where waiting age is the current CPU tick minus
`ready_tick`. A low-priority task therefore catches up with a normal task after
10 ticks and with a high task after 20 ticks. Priorities bias latency but cannot
starve a runnable task: every ready task eventually becomes the highest score.
Ties fall back to the round-robin scan order. The M15 priority test creates one
task at each level and observes the order high, normal, low.

### Sleep

`sched.sleep(duration)` saves interrupts, stores a pending duration in the
current CPU's `sleep_request`, and executes `int $50`. `sleepCurrent` marks the
task `blocked`, sets `wake_tick = cpu_ticks[this_cpu] + duration`, pushes the
deadline into this CPU's heap, increments `blocked_counter`, and switches to the
next runnable task or the idle task. The owning CPU's timer tick pops the entry
and wakes the task with `WakeReason.timeout` once the deadline is reached. A
duration of zero is a no-op. The idle task cannot sleep.

`sched.sleepMs(ms)` and `sched.sleepNs(ns)` convert the duration with
`time.msToTicks`/`time.nsToTicks`, rounding up, and then call `sleep`. The
10 ms scheduler tick therefore bounds wakeup granularity: a request is satisfied
on the first tick at or after the converted deadline, not at an arbitrary
nanosecond.

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
switches tasks. `sched.resumeScheduling()` sets `enabled = true` again. The
selftest calls `stopTimer()` (which disables interrupts, masks IRQ0, stops the
LAPIC timer, and calls `sched.stop()`) before the BSP-only tests, then re-enables
scheduling before the M11 SMP tests. M14 restarts CPU 0's LAPIC timer when it
switches the BSP to the uniform timer path.

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
| `sched.onlineMask()` | Bit mask of online CPUs, used by TSC synchronization. |
| `sched.rescheduleCount()` | Reschedule IPIs handled. |
| `sched.tlbShootdownCount()` | TLB shootdown requests issued. |
| `sched.deadlinePushCount()` | Finite deadlines inserted into a CPU heap. |
| `sched.deadlinePopCount()` | Deadlines popped on expiry. |
| `sched.deadlineDepthOn(cpu)` | Current heap depth for one CPU. |
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

## Process lifecycle (M17)

The kernel-side process layer in [`src/process.zig`](../../src/process.zig)
wraps scheduler tasks. A process owns:

- one user address space, loaded and validated by `user.zig`;
- one 16 KiB kernel stack from the kernel heap;
- one joinable ring-3 scheduler task;
- a stored exit status and a generation-tagged handle.

`spawn` reserves a table slot, allocates the kernel stack, loads the image,
creates the task, and only then publishes the process as `running`. Every
failure before publish releases the slot, stack, and address space. A published
`Handle` consists of a one-based `pid` and a `generation`; the generation
increments when the slot is reused, so a stale handle cannot name a later
process.

`wait` does not consume the scheduler's single `join` slot. It snapshots
`sched.taskStatus(id)` and polls at tick granularity, sleeping for one tick
between checks. A finite timeout is measured in ticks and returns `timeout`
without discarding the process. When the task is `finished`, `wait` copies the
exit status into the process record and returns `exited`; later `wait` calls
keep returning the stored status.

`reap` requires a process that has exited. It marks the slot `reaping`,
detaches the finished scheduler task, frees the kernel stack, clears the
record, and makes the slot reusable. Because the scheduler destroyed the user
address space when the ring-3 task exited, `reap` performs no user-page
teardown. `process.stats()` reports slots, live processes, exited processes,
and cumulative spawn/reap counts for the selftest.

A ring-3 `#PF` (for example on the guard page or an NX leaf) takes the existing
scheduler fault path, which gives the task the status `-(vector + 1)` and
destroys only its address space.

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
| M14 IOAPIC delivery | ISA IRQ0 is resolved through its MADT ISO, programmed into the IOAPIC, observed on vector 242 with a LAPIC EOI, then masked. |
| M14 CPU 0 timer | CPU 0 starts its LAPIC timer, a sleeper wakes after five ticks, and two CPU-bound tasks are preempted by the local timer. |
| M15 deadline queue | A `sleepMs` worker pushes and pops a finite deadline; the observed sleep is at least 40 ms and spans at least five ticks. |
| M15 join | A worker exits with status 42 and is joined; an already-finished task returns status 7; a repeated join is `invalid`; a blocked task times out at 50 ms and is then woken and joined with status 9. |
| M15 priorities | Three tasks at `low`/`normal`/`high` run in the order high, normal, low. |
| M15 sleep helpers | `sleepMs(50)` is used on the BSP, every AP, and through the tick fallback; the elapsed nanosecond delta is bounded. |
| M16 user syscalls | The embedded ring-3 fixture writes to the serial console, sleeps, calls `getpid`/`yield`, and exits with status 42. |
| M16 user fault | Dereferencing NULL in ring 3 terminates only that task with `-15`; the BSP continues. |
| M16 isolation | Two address spaces map different physical pages at `0x500000`; a third task probes an extra page that exists only in another task and faults with `-15`. |
| M16 preemption | Two busy user tasks on CPU 0 both advance their private counters under the LAPIC timer with no syscalls. |
| M16 user pointers | An unmapped address and a non-canonical address are rejected by `copyFromUser` with `-EFAULT`; the task survives and exits 0. |
| M16 teardown | The nine address spaces created by the test are all destroyed before the check succeeds. |
| M17 argv/envp | The general loader reports `argv`/`envp` through the fixture, and the process exits 42. |
| M17 concurrency | Two processes are live at once; a fast one exits 42 and a sleeping one exits 43. |
| M17 wait timeout | A short finite wait times out while the process sleeps and a longer retry returns the stored status. |
| M17 generations | Reusing a reaped slot advances the generation and an old handle returns `invalid`. |
| M17 NX | Fetching from a RW+NX data page faults only that process with `-15`; a sibling exits 44. |
| M17 guard page | Writing to the unmapped stack guard faults only that process with `-15`; a sibling exits 44. |
| M17 rejected loads | A bad header, wrong machine, overlapping segments, and an oversized stack argument are rejected. |
| M17 reclaim | Created/destroyed address spaces and free pages match after the process run; the table ends empty. |

## Limitations

- **No migration or balancing:** every task is pinned at creation; migration is
  planned for M20.
- **Priorities bias, they do not partition:** there is no strict priority
  scheduling and no priority inheritance. The wait-age policy prevents
  starvation but allows a low-priority task to run ahead of an older normal task
  once its score catches up.
- **Single joiner:** a task has one `join_waiter_id`; concurrent `join` calls
  return `invalid`, and a `*Task` is only safe to retain while it is joinable and
  not yet reaped.
- **Tick-granularity sleep:** `sleepNs` is converted to ticks, so 10 ms is the
  smallest effective sleep and a wakeup can be up to one tick late.
- **Fixed task limit:** 32 slots total, including the boot task and one idle task
  per CPU. Unreaped joinable tasks hold their slots.
- **Static stacks:** tasks use caller-owned stacks for kernel tasks; user
  processes get a 16 KiB heap-allocated kernel stack from the process layer.
  Kernel tasks have no guard page. User processes have a fixed four-page user
  stack and one unmapped guard page, but no automatic stack growth.
- **Process API is kernel-side:** `spawn`/`wait`/`reap` are not exposed to ring
  3. There is no `exec`, no file-descriptor table, and the syscall ABI is
  unchanged.
- **Single-threaded processes:** a process owns exactly one scheduler task; there
  are no threads, `clone`, or shared address spaces.
- **Fixed process limit:** 16 process slots in addition to the 32 scheduler task
  slots. An unreaped process holds both.
- **Address spaces are pinned:** a user address space cannot migrate to another
  CPU, so its teardown avoids a remote TLB shootdown but migration remains
  impossible.
- **Tick-granular waits:** `process.wait` polls once per tick, so a finite
  timeout can be up to one tick late.
- **Idle cannot block**; blocking calls return immediately for idle tasks.
- **Fallback timer:** CPU 0 uses the PIT if LAPIC calibration fails or the
  `force_pit` image is built. Normal operation uses the same LAPIC mechanism as
  the APs, but the per-CPU counters are not phase-locked.
- **Fallback clocksource:** when the TSC is absent or non-invariant, `nowNs`
  advances from CPU 0's 100 Hz ticks, which has the same 10 ms granularity.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Per-CPU scheduler | **IMPLEMENTED** | Pinned tasks, per-CPU idle and current state; priority score with round-robin ties. |
| Per-CPU timer preemption | **IMPLEMENTED** | LAPIC vector 242 on CPU 0 and APs; PIT IRQ0 fallback on CPU 0. |
| Per-CPU tick counters | **IMPLEMENTED** | Independent `cpu_ticks` entries; `ticksOn(cpu)`. |
| Cooperative yield/exit | **IMPLEMENTED** | Vectors 48 and 49. |
| Sleep and explicit block/wake | **IMPLEMENTED** | Vectors 50 and 51; per-CPU deadline heap for finite sleeps. |
| `sleepMs`/`sleepNs` helpers | **IMPLEMENTED** | Converted to ticks, rounded up; 10 ms granularity. |
| Wait queues and timed waits | **IMPLEMENTED** | Vectors 52 and 53; SMP-aware task IDs and finite deadlines. |
| Mutex and condition variable | **IMPLEMENTED** | Ownership transfer; blocked-before-unlock. |
| Per-CPU idle tasks and slot reuse | **IMPLEMENTED** | 8 KiB idle stacks; task limit 32; joinable slots retained. |
| FPU/SIMD context switching | **IMPLEMENTED** | Per-task 512-byte FXSAVE area; `%gs:0` pointer. |
| Cross-CPU wakeups | **IMPLEMENTED** | Reschedule IPI 240. |
| TLB shootdown | **IMPLEMENTED** | Lock-free per-CPU mailboxes; IPI 241; waits for every acknowledgement. |
| AP timer preemption | **IMPLEMENTED** | Periodic LAPIC timer, vector 242, calibrated from the PIT. |
| CPU 0 LAPIC timer | **IMPLEMENTED** | Same vector and reload as the APs; PIT fallback retained. |
| Deadline queue | **IMPLEMENTED** | Per-CPU min-heap; finite deadlines only. |
| Priority levels and ageing | **IMPLEMENTED** | `low`/`normal`/`high`; no starvation; no inheritance. |
| Join with status and timeout | **IMPLEMENTED** | Single waiter; `already_finished`, `timeout`, and `invalid` outcomes. |
| Ring-3 user tasks | **IMPLEMENTED** | Per-task low-half PML4, 16 KiB kernel stack, `iretq` to DPL3. |
| CR3 and TSS switching | **IMPLEMENTED** | `switchTaskLocked` loads the task PML4 and rewrites TSS `RSP0`. |
| User exit/fault teardown | **IMPLEMENTED** | Kernel-root switch, low-half free, PML4 free; fault status `-(vector + 1)`. |
| General process creation/reaping | **IMPLEMENTED** | Process table, `spawn`/`wait`/`reap`, stored status, generation handles. |
| Process wait/timeout | **IMPLEMENTED** | Tick-granular polling; timeout is retryable; status survives until reaping. |
| Task migration and balancing | **PLANNED** | M20. |

## Related documentation

- [Overview](overview.md)
- [CPU and interrupts](cpu-interrupts.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Testing](../development/testing.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
