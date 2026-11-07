# Synchronization

**Purpose:** document the spinlocks, interrupt-masking helpers, wait queues,
mutexes, and condition variables, including their current single-CPU
assumptions and known hazards.

**Implementation status:** `SpinLock`, `IrqSpinLock`, and `IrqLock` are
**IMPLEMENTED**. `IrqSpinLock` and `IrqLock` now return a per-acquisition guard
that carries the saved interrupt state on the caller's stack, so concurrent and
nested acquisitions cannot corrupt each other. Wait queues, mutexes, and
condition variables are **IMPLEMENTED** for the single-CPU scheduler only;
SMP-aware versions are **PLANNED** for M11.

## Primitives at a glance

| Primitive | Source | Scope | Status |
| --- | --- | --- | --- |
| `SpinLock` | [`src/sync.zig`](../../src/sync.zig) | Atomic lock shared across CPUs | **IMPLEMENTED** |
| `IrqSpinLock` | [`src/sync.zig`](../../src/sync.zig) | Atomic lock plus interrupt masking | **IMPLEMENTED** |
| `IrqLock` | [`src/sync.zig`](../../src/sync.zig) | Interrupt masking only | **IMPLEMENTED** (single-CPU; no cross-CPU serialization) |
| `irqSave` / `irqRestore` | [`src/sync.zig`](../../src/sync.zig) | Save/restore `RFLAGS` | **IMPLEMENTED** |
| `WaitQueue` | [`src/sched.zig`](../../src/sched.zig) | Task wait list | **PARTIAL** (single-CPU only) |
| `Mutex` | [`src/sched.zig`](../../src/sched.zig) | Blocking ownership lock | **PARTIAL** (single-CPU only) |
| `Condition` | [`src/sched.zig`](../../src/sched.zig) | Condition variable over `Mutex` | **PARTIAL** (single-CPU only) |

## `SpinLock`

`SpinLock` is a real SMP-safe atomic lock:

```zig
pub const SpinLock = struct {
    locked: u32 = 0,

    pub fn acquire(self: *SpinLock) void { ... }
    pub fn tryAcquire(self: *SpinLock) bool { ... }
    pub fn release(self: *SpinLock) void { ... }
};
```

- `acquire` uses `@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire)`. On
  failure it spins with `@atomicLoad(..., .monotonic)` and a `pause`
  instruction.
- `tryAcquire` performs one atomic exchange and returns whether it acquired the
  lock.
- `release` stores zero with `.release` ordering.

`SpinLock` does not disable interrupts. A lock shared with an interrupt handler
must use interrupt masking as well, which is the purpose of `IrqSpinLock`.

## `IrqSpinLock` and acquisition guards

`IrqSpinLock` wraps a `SpinLock` and disables interrupts while held. `acquire`
returns a guard by value; the saved `RFLAGS` value is a field of that guard, so
it lives in the caller's stack frame rather than in the shared lock object:

```zig
pub const IrqSpinLock = struct {
    lock: SpinLock = .{},

    pub const Guard = struct {
        owner: *IrqSpinLock,
        flags: u64,

        pub fn release(self: Guard) void {
            self.owner.lock.release();
            irqRestore(self.flags);
        }
    };

    pub fn acquire(self: *IrqSpinLock) Guard {
        const flags = irqSave();
        asm volatile ("cli");
        self.lock.acquire();
        return .{ .owner = self, .flags = flags };
    }
};
```

Callers bind the guard and release it with `defer`:

```zig
const guard = task_lock.acquire();
defer guard.release();
```

This fixes the pre-M11 shared-flags defect: two CPUs contending for the same
lock each retain their own saved interrupt state, and nesting different
`IrqSpinLock` objects restores state in the correct order. Guards must still be
released by the same CPU and in LIFO order. `IrqSpinLock` is **not reentrant**:
acquiring the same lock twice on one CPU deadlocks in the underlying
`SpinLock`.

`IrqLock` uses the same guard shape but contains no atomic lock. It disables
interrupts and restores the previous state, so it is only suitable for
single-CPU state or for callers that already serialize themselves. It does not
serialize against other CPUs; use `IrqSpinLock` for state shared across CPUs.

The scheduler's `task_lock` is an `IrqSpinLock`; all of its call sites use the
guard form. `smp.test_lock` remains a plain `SpinLock`, because the stress
workload does not need interrupt masking.

## Interrupt save/restore

`irqSave()` reads `RFLAGS` with `pushfq; popq`. `irqRestore(flags)` writes it
back with `pushq; popfq` and a memory clobber. These are raw helpers; they do not
nest by themselves. `IrqSpinLock` and `IrqLock` wrap them in guards. The
single-CPU wait/sleep/mutex/condition paths still keep a local `flags` variable
in the calling function, which is correct as long as those paths remain
single-CPU and are not re-entered.

## `WaitQueue`

`WaitQueue` stores up to `max_tasks` (8) waiter task IDs:

```zig
pub const WaitQueue = struct {
    waiters: [max_tasks]u32 = @splat(0),
    count: usize = 0,
    ...
};
```

Waiters are stored by task ID rather than by pointer so a reused task slot
cannot accidentally satisfy an old wakeup.

### Operations

| Operation | Behavior |
| --- | --- |
| `wait()` | Saves interrupts, disables them, records the queue in `wait_request`, executes `int $52`, then restores interrupts. |
| `waitTimeout(duration)` | Rejects `duration == 0`; clears the current task's `wake_reason`, records a timeout request, executes `int $53`, and returns `true` only if the wake reason is `.signal` (not `.timeout`). |
| `wakeOne()` | Acquires the task lock and wakes the first still-blocked waiter; returns whether one was woken. Prunes stale or ready entries while scanning. |
| `wakeAll()` | Acquires the task lock, wakes every still-blocked waiter, clears the queue, and returns the number woken. |

The dispatcher paths (`waitQueueCurrent`, `waitTimeoutCurrent`) call
`compactLocked()`, reject the request if the queue is full, append the current
task ID, and then block the task. A full queue therefore leaves the caller
running rather than blocking it.

`compactLocked()` keeps only entries whose task still exists and is `blocked`.
Timed-out task IDs remain in the queue until the next `wakeOne` or compaction
pass removes them.

### Single-CPU assumptions

`wait()` and `waitTimeout()` use `irqSave` plus `cli`, but no cross-CPU lock
around the pending request. `wakeOne`/`wakeAll` use `task_lock`, while the
condition-variable signal paths use only interrupt masking. These paths assume
the scheduler and all waiters are on one CPU. They are not safe once APs can
wake tasks.

## `Mutex`

`Mutex` is a single-CPU blocking mutex with direct ownership transfer:

```zig
pub const Mutex = struct {
    locked: bool = false,
    owner: ?*Task = null,
    waiters: WaitQueue = .{},
    ...
};
```

- `lock()` saves and disables interrupts.
- If there is no current task, it marks the mutex locked and returns.
- If the mutex is free, it records the current task as owner.
- If the current task is the idle task, it returns without blocking; the idle
  task must never contend for a mutex.
- Otherwise it enqueues the current task, executes `int $51`, and resumes after
  `unlockLocked` has transferred ownership to it.

`unlock()` calls `unlockLocked()`:

- if a waiter is woken, the mutex stays locked and ownership is assigned to the
  woken task;
- otherwise the mutex becomes unlocked and the owner is cleared.

The mutex is **not reentrant**. Locking it twice on the same task deadlocks.
Because ownership is transferred directly, the resumed `lock()` call already
owns the mutex; it does not re-check the `locked` flag.

## `Condition`

`Condition` is a condition variable used with a `Mutex`:

- `wait(mutex)` saves and disables interrupts; rejects a missing current task
  or the idle task; enqueues the current task on the condition's wait queue;
  calls `mutex.unlockLocked()`; executes `int $51` to block; restores
  interrupts; then calls `mutex.lock()` before returning.
- `signal()` disables interrupts and wakes one waiter.
- `broadcast()` disables interrupts and wakes all waiters.

Enqueueing the waiter and releasing the mutex are atomic with respect to
interrupts on the current CPU, so a signaller holding the same mutex cannot run
between the predicate check and the block. Callers must follow the usual
condition-variable discipline: change the predicate and signal while holding
the associated mutex. Signalling without holding the predicate's mutex can
still lose a wakeup.

Neither `Mutex` nor `Condition` is reentrant, and both rely on single-CPU
interrupt disabling rather than an SMP lock.

## Lock ordering

There is no documented or enforced lock ordering in the current code. The
scheduler uses `task_lock` for the task table, while several operations rely on
interrupt disabling alone. For example, `Mutex.lock`/`unlock` and
`Condition.signal`/`broadcast` do not take `task_lock`; they call the
`*Locked` helpers with interrupts disabled.

The per-acquisition guard fix has landed, so cross-CPU interrupt-state
restoration is no longer the blocker. For M11, an explicit order still needs to
be defined before APs take scheduler locks, for example: task/run-queue lock
before wait-queue lock before any allocator or console lock. That ordering is
**PLANNED**, not implemented.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Atomic `SpinLock` | **IMPLEMENTED** | Acquire/release ordering and `pause` spin. |
| `IrqSpinLock` | **IMPLEMENTED** | Per-acquisition guard; safe under contention and nested use of distinct locks. |
| `IrqLock` | **IMPLEMENTED** | Per-acquisition guard; single-CPU interrupt masking only. |
| Wait queue with signal/timeout | **IMPLEMENTED** | Task-ID based; single-CPU. |
| Blocking mutex with ownership transfer | **IMPLEMENTED** | Not reentrant; idle cannot block. |
| Condition variable | **IMPLEMENTED** | Requires predicate mutex discipline. |
| Explicit lock ordering | **PLANNED** | Recommended before M11. |
| SMP-aware wait queues/mutex/condition | **PLANNED** | M11. |

## Related documentation

- [Overview](overview.md)
- [Scheduling](scheduling.md)
- [CPU and interrupts](cpu-interrupts.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
- [Testing](../development/testing.md)
