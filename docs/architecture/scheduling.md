# Scheduling

**Purpose:** describe the task model, the round-robin scheduler, task lifecycle
operations, the idle task, and FPU/SIMD context switching.

**Implementation status:** the scheduler and FPU context switching are
**IMPLEMENTED**, but only on the bootstrap processor. Per-CPU run queues and
cross-CPU scheduling are **PLANNED** for M11.

## Scope

The scheduler in [`src/sched.zig`](../../src/sched.zig) provides:

- preemptive round-robin scheduling driven by IRQ0 at 100 Hz;
- cooperative `yield` and `exit` software interrupts;
- timer-based sleep and indefinite block/wake;
- wait queues, mutexes, and condition variables;
- an idle task that halts when no other task is ready;
- reuse of finished task slots;
- per-task FPU/SIMD state saved with `fxsave64`/`fxrstor64`.

It does **not** provide priorities, per-CPU run queues, task migration,
cross-CPU wakeups, address-space switching, or SMP-safe wait queues. APs run
the SMP stress workload or park; they never enter this scheduler.

## Task model

`max_tasks = 8`. A task is represented by `Task`:

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

`FpuState` is `[512]u8`, the size of an FXSAVE area. `Entry` is
`*const fn () callconv(.c) void`.

### Task table and reserved slots

The scheduler keeps a global `tasks: [8]Task` array, a `task_count`, a `current`
pointer, and global counters. The first two slots are reserved:

| Index | Task | ID | State after `init` |
| --- | --- | --- | --- |
| 0 | `boot` | 0 | `running` |
| 1 | `idle` | 1 | `idle` |

`idle_index = 1`. `task_count` starts at 2, and `next_id` starts at 2.
`tasks[0].rsp` is 0 because the boot context is already running on the kernel
stack; the idle task gets an initial frame on a dedicated 8 KiB static stack.
User tasks use caller-owned stacks; the selftests use static 16 KiB stacks in
[`src/main.zig`](../../src/main.zig).

## Initialization

`sched.init()`:

1. acquires the task lock;
2. builds the FPU template with `initFpuTemplate()`;
3. initializes the boot task and the idle task;
4. sets `task_count = 2`, `current = &tasks[0]`, and
   `current_fpu_state` to the boot task's FPU area;
5. clears the tick, finished, and blocked counters, pending requests, and
   `next_id`;
6. sets `enabled = true` and `initialized = true`.

`initFpuTemplate()` saves the current FPU state, executes `fninit` and zeroes
XMM0-XMM15, saves that clean state as `fpu_template`, then restores the
original state. New tasks and the idle task inherit this clean template.

## Creating a task

`sched.create(name, entry, stack)`:

1. rejects calls before initialization;
2. acquires the task lock;
3. finds a finished slot above `idle_index`, or appends a new slot if
   `task_count < max_tasks`;
4. builds an initial interrupt frame at the top of the caller-owned stack with
   `initialFrame`;
5. assigns a fresh ID, writes the task entry, and marks it `ready`.

`initialFrame` requires at least 512 bytes of stack and at least 256 bytes below
the aligned top. It sets the entry stack pointer to 8 bytes below the aligned
top, leaving an 8-byte slot, then builds an `initial_frame_qwords` frame
(`15 saved registers + 2 vector/error + 5 iret qwords = 22` qwords):

- the 15 register slots are zeroed;
- `frame[17]` is the entry address (RIP);
- `frame[18]` is the kernel code selector;
- `frame[19]` is `0x202` (interrupts enabled);
- `frame[20]` is the aligned entry stack pointer;
- `frame[21]` is the kernel data selector.

The normal `isr_common` epilogue can therefore enter the task with `iretq`
without a separate task-start trampoline.

### Slot reuse

`findSlot()` scans from `idle_index + 1` for a task in the `finished` state. If
none is found and the table is not full, it returns `task_count` as the next
slot. A finished slot keeps its old stack pointer until it is overwritten, but
the caller must supply a valid stack to `create`.

## Scheduling operations

### Timer tick

`tick(saved_rsp)` is called by IRQ0:

1. increment the global `tick_counter`;
2. if not initialized, return the saved frame;
3. wake blocked tasks whose deadline has passed (`wakeBlocked`);
4. save the current task's `rsp` and increment its `ticks`;
5. if scheduling is disabled, return the saved frame;
6. find the next `ready` task after the current index
   (`nextOtherReady`);
7. if one exists, park the current task (`running` -> `ready`, except the idle
   task which becomes `idle`), and switch to the next task;
8. otherwise return the saved frame and continue the current task.

`nextOtherReady` scans the table round-robin and only returns tasks in the
`ready` state. It never selects the idle task directly; the idle task is used
only when an operation has no other ready task.

### Yield

`yieldCurrent(saved_rsp)` saves the current `rsp`, finds the next ready task,
and switches. If none exists, it returns the saved frame. It does not run
deadline wakeups; those are handled by the timer tick.

### Exit

`exitCurrent(saved_rsp)` marks the current task `finished`, increments
`finished_counter`, and switches to the next ready task. If none exists, it
switches to the idle task. If the idle task itself exits, the CPU halts
forever. `sched.exit()` is declared `noreturn` and halts if the software
interrupt ever returns.

### Sleep

`sched.sleep(duration)` saves interrupts, stores a pending duration, and
executes `int $50`. `sleepCurrent` marks the task `blocked`, sets
`wake_tick = tick_counter + duration`, increments `blocked_counter`, and
switches to the next ready task or the idle task. The timer tick wakes the task
with `WakeReason.timeout` once the deadline is reached. A duration of zero is a
no-op. The idle task cannot sleep.

### Indefinite block and wake

`sched.block()` executes `int $51`. `blockCurrent` marks the task `blocked`,
sets `wake_tick = ~0`, increments `blocked_counter`, and switches away.
`sched.wake(task)` acquires the task lock and calls `wakeLocked(task, .signal)`,
which only succeeds if the task is still `blocked`; it then marks the task
`ready`, records the reason, and decrements `blocked_counter`.

`sched.blockedCount()` exposes the blocked counter for test handshakes.

### Wait queue operations

`WaitQueue.wait()` and `waitTimeout()` execute software interrupts 52 and 53
after disabling interrupts. The dispatcher enqueues the current task ID,
compacts stale entries, and blocks the task. See
[synchronization](synchronization.md) for the wait-queue, mutex, and condition
semantics.

### Stop

`sched.stop()` acquires the task lock and sets `enabled = false`. The timer
tick still increments `tick_counter` and wakes blocked tasks, but it no longer
switches tasks. The selftest calls `stopTimer()` (which disables interrupts,
masks IRQ0, and calls `sched.stop()`) before running the SMP test.

## Idle task

The idle task is `tasks[1]` with an 8 KiB static stack. Its entry is
`idleEntry`:

```zig
fn idleEntry() callconv(.c) void {
    while (true) {
        asm volatile ("sti; hlt");
    }
}
```

The idle task cannot block, sleep, or contend for a mutex; the blocking
primitives explicitly return without blocking when the current task is the idle
task. When every other task is blocked, the scheduler switches to idle, which
enables interrupts and halts until the next interrupt.

## Counters and diagnostics

| API | Meaning |
| --- | --- |
| `sched.ticks()` | Global PIT tick counter. |
| `sched.finishedCount()` | Tasks that have exited. |
| `sched.blockedCount()` | Tasks currently blocked. |
| `sched.stats()` | Snapshot of ticks, task count, finished, blocked, current ID, and enabled. |

These are global, non-per-CPU counters. They are read with volatile accesses in
the tests and are not protected by a lock.

## FPU/SIMD context switching (M9)

Each task owns a 16-byte-aligned 512-byte `FpuState`. The assembly entry path
saves the interrupted task's state with `fxsave64` before calling the
dispatcher, and restores the selected task's state with `fxrstor64` before
`iretq` (see [CPU and interrupts](cpu-interrupts.md)).

`current_fpu_state` is an exported `u64` holding the address of the active
task's FPU area. `switchTask(next)` updates it whenever the scheduler changes
tasks, so the assembly restore targets the next task. `sched.init()` points it
at the boot task's area; a value of zero disables both the save and the restore,
which is why pre-scheduler exceptions still follow the normal fault path.

The selftest creates two tasks that load distinct XMM0 patterns, yield to each
other inside one inline-assembly block, and store XMM0 afterwards. It also
checks that both tasks actually interleaved. A correct save/restore preserves
each pattern; a missing switch would let one task read the other's pattern.

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

## Limitations

- **BSP-only:** `current`, the task table, counters, and wait queues are global
  and are driven only by the BSP timer.
- **No per-CPU state:** there are no per-CPU run queues or idle tasks.
- **No cross-CPU wakeups:** waking a task does not notify another CPU.
- **No priorities or fairness policy** beyond round-robin over ready tasks.
- **Fixed task limit:** eight slots total, including boot and idle.
- **Static stacks:** tasks use caller-owned stacks; there is no guard page or
  automatic stack allocation.
- **No join/wait-for-exit API**; tests poll `finishedCount()`.
- **No address-space switching**; all tasks share the kernel page tables.
- **Idle cannot block**; blocking calls return immediately for the idle task.
- **Wait queues and mutex/condition are single-CPU designs**; see
  [synchronization](synchronization.md) and
  [technical debt](../development/technical-debt.md).

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Preemptive round-robin scheduler | **IMPLEMENTED** | IRQ0 at 100 Hz, BSP only. |
| Cooperative yield/exit | **IMPLEMENTED** | Vectors 48 and 49. |
| Sleep and explicit block/wake | **IMPLEMENTED** | Vectors 50 and 51. |
| Wait queues and timed waits | **IMPLEMENTED** | Vectors 52 and 53; single-CPU semantics. |
| Mutex and condition variable | **IMPLEMENTED** | Ownership transfer; not reentrant. |
| Idle task and finished-slot reuse | **IMPLEMENTED** | Idle stack 8 KiB; task limit 8. |
| FPU/SIMD context switching | **IMPLEMENTED** | 512-byte FXSAVE area per task. |
| Per-CPU scheduler and run queues | **PLANNED** | M11. |
| SMP-aware wait queues and cross-CPU wakeups | **PLANNED** | Requires LAPIC/IPI support. |
| Priorities, migration, task join | **PLANNED** | Not implemented. |

## Related documentation

- [Overview](overview.md)
- [CPU and interrupts](cpu-interrupts.md)
- [Synchronization](synchronization.md)
- [SMP bring-up](smp.md)
- [Testing](../development/testing.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
