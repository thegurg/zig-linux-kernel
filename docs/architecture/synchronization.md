# Synchronization

**Purpose:** document the spinlocks, interrupt-masking helpers, wait queues,
mutexes, and condition variables, including their current single-CPU
assumptions and known hazards.

**Implementation status:** `SpinLock` is **IMPLEMENTED** and SMP-safe.
`IrqSpinLock` and `IrqLock` are **IMPLEMENTED** but have a shared-flags defect
that makes them unsafe for multiple concurrent users. Wait queues, mutexes, and
condition variables are **IMPLEMENTED** for the single-CPU scheduler only.
SMP-aware versions are **PLANNED** for M11.

## Primitives at a glance

| Primitive | Source | Scope | Status |
| --- | --- | --- | --- |
| `SpinLock` | [`src/sync.zig`](../../src/sync.zig) | Atomic lock shared across CPUs | **IMPLEMENTED** |
| `IrqSpinLock` | [`src/sync.zig`](../../src/sync.zig) | Atomic lock plus interrupt masking | **PARTIAL** (shared-flags defect) |
| `IrqLock` | [`src/sync.zig`](../../src/sync.zig) | Interrupt masking only | **PARTIAL** (single-CPU helper, shared flags) |
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

## `IrqSpinLock` and the shared-flags defect

`IrqSpinLock` wraps a `SpinLock` and disables interrupts while held:

```zig
pub const IrqSpinLock = struct {
    lock: SpinLock = .{},
    flags: u64 = 0,

    pub fn acquire(self: *IrqSpinLock) void {
        self.flags = irqSave();
        asm volatile ("cli");
        self.lock.acquire();
    }

    pub fn release(self: *IrqSpinLock) void {
        self.lock.release();
        irqRestore(self.flags);
    }
};
```

**Known defect (critical):** the saved `RFLAGS` value lives in the lock object,
not in a per-acquisition guard. If two CPUs contend for the same lock, the
second CPU overwrites `self.flags` before it acquires the lock. When the first
CPU releases, it restores the second CPU's flags instead of its own. Nested
acquisition has the same problem. The lock is also not reentrant: acquiring it
twice on one CPU deadlocks before the flags issue is reached.

The defect is currently latent because:

- the scheduler's `task_lock` is the main `IrqSpinLock` user;
- the scheduler runs only on the BSP;
- APs never take scheduler locks and do not enter the scheduler.

It must be fixed before M11 allows APs to take scheduler or wait-queue locks.
The intended fix is an acquisition-local guard (save `RFLAGS` in a local or
returned token and pass it to release) rather than storing it in the shared lock
object. This fix is **PLANNED**, not implemented.

`IrqLock` has the same shared `flags` field and is explicitly an older
single-CPU helper: it disables interrupts and restores the previous state but
does not serialize against other CPUs. It should not be used for locks shared
across CPUs.

## Interrupt save/restore

`irqSave()` reads `RFLAGS` with `pushfq; popq`. `irqRestore(flags)` writes it
back with `pushq; popfq` and a memory clobber. These are raw helpers; they do not
nest by themselves. Callers must keep the saved value local to the acquisition
or use a guard object.

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

For M11, the audit recommends defining an explicit order before APs take
scheduler locks, for example: task/run-queue lock before wait-queue lock before
any allocator or console lock. That ordering is **PLANNED**, not implemented.
The `IrqSpinLock` fix should land first, because the current shared-flags
behavior makes any cross-CPU lock ordering unreliable.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Atomic `SpinLock` | **IMPLEMENTED** | Acquire/release ordering and `pause` spin. |
| `IrqSpinLock` | **PARTIAL** | Shared saved-flags field; unsafe under contention/nesting. |
| `IrqLock` | **PARTIAL** | Single-CPU interrupt masking only. |
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
