# Synchronization

**Purpose:** document the spinlocks, interrupt-masking helpers, wait queues,
mutexes, condition variables, cross-CPU wakeups, and the lock ordering used by
the M11 scheduler and memory subsystems.

**Implementation status:** `SpinLock`, `IrqSpinLock`, `IrqLock`, wait queues,
mutexes, and condition variables are **IMPLEMENTED** and work across CPUs. The
PMM, VMM, console, and serial paths have IRQ-safe locks. The heap is **PARTIAL**:
its free list remains unsynchronized. See
[technical debt](../development/technical-debt.md).

## Primitives at a glance

| Primitive | Source | Scope | Status |
| --- | --- | --- | --- |
| `SpinLock` | [`src/sync.zig`](../../src/sync.zig) | Atomic lock shared across CPUs | **IMPLEMENTED** |
| `IrqSpinLock` | [`src/sync.zig`](../../src/sync.zig) | Atomic lock plus interrupt masking | **IMPLEMENTED** |
| `IrqLock` | [`src/sync.zig`](../../src/sync.zig) | Interrupt masking only | **IMPLEMENTED** (no cross-CPU serialization) |
| `irqSave` / `irqRestore` | [`src/sync.zig`](../../src/sync.zig) | Save/restore `RFLAGS` | **IMPLEMENTED** |
| `WaitQueue` | [`src/sched.zig`](../../src/sched.zig) | Task wait list | **IMPLEMENTED** (SMP-aware) |
| `Mutex` | [`src/sched.zig`](../../src/sched.zig) | Blocking ownership lock | **IMPLEMENTED** (SMP-aware) |
| `Condition` | [`src/sched.zig`](../../src/sched.zig) | Condition variable over `Mutex` | **IMPLEMENTED** (SMP-aware) |

## `SpinLock`

`SpinLock` is an SMP-safe atomic lock:

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

`SpinLock` does not disable interrupts. It is used directly only by the TLB
shootdown path, where a CPU waiting for the lock must still be able to take the
remote shootdown IPI. Every other shared lock that can also be taken from an
interrupt handler uses `IrqSpinLock`.

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

Guards must be released by the same CPU and in LIFO order. `IrqSpinLock` is
**not reentrant**: acquiring the same lock twice on one CPU deadlocks in the
underlying `SpinLock`.

`IrqLock` uses the same guard shape but contains no atomic lock. It disables
interrupts and restores the previous state, so it is only suitable for
single-CPU state or for callers that already serialize themselves. It does not
serialize against other CPUs.

## Interrupt save/restore

`irqSave()` reads `RFLAGS` with `pushfq; popq`. `irqRestore(flags)` writes it
back with `pushq; popfq` and a memory clobber. `IrqSpinLock` and `IrqLock` wrap
these in guards. The blocking primitives additionally keep a local `flags`
variable because they must disable interrupts across a software interrupt and a
lock release:

```zig
const flags = sync.irqSave();
asm volatile ("cli");
...
sync.irqRestore(flags);
```

The saved flags live on the calling task's stack, so each task and each CPU has
its own copy.

## `WaitQueue`

`WaitQueue` stores up to `max_tasks` (32) waiter task IDs:

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
| `wait()` | Saves interrupts, disables them, records the queue in the current CPU's `wait_request`, executes `int $52`, then restores interrupts. |
| `waitTimeout(duration)` | Rejects `duration == 0`; records a queue/duration request, executes `int $53`, and returns `true` only if the wake reason is `.signal` (not `.timeout`). |
| `wakeOne()` | Acquires `task_lock`, wakes the first still-blocked waiter, and returns whether one was woken. Prunes stale entries while scanning. |
| `wakeAll()` | Acquires `task_lock`, wakes every still-blocked waiter, clears the queue, and returns the number woken. |

The dispatcher paths (`waitQueueCurrent`, `waitTimeoutCurrent`) acquire
`task_lock`, call `compactLocked()`, reject the request if the queue is full,
append the current task ID, mark the task blocked, and switch away. A full queue
leaves the caller running rather than blocking it.

`compactLocked()` keeps only entries whose task still exists and is `blocked`.
Timed-out task IDs remain in the queue until the next `wakeOne` or compaction
pass removes them.

### Cross-CPU wakeups

`wakeLocked` marks a blocked task `ready` and, when the task is pinned to a
different CPU, sends a reschedule IPI (vector 240) to that CPU. The target's
`rescheduleInterrupt` then selects the task from its run queue. No waiter state
is CPU-local after enqueueing, so a wakeup may originate from any CPU.

`WaitQueue.wait()` has the usual condition-variable race: a signal that arrives
before the task has enqueued itself is not remembered. Callers must protect the
predicate with a mutex or another protocol. `Mutex` and `Condition` avoid that
race for their own enqueue paths (see below).

## `Mutex`

`Mutex` is a blocking mutex with direct ownership transfer:

```zig
pub const Mutex = struct {
    locked: bool = false,
    owner: ?*Task = null,
    waiters: WaitQueue = .{},
    ...
};
```

`lock()`:

1. saves and disables interrupts;
2. acquires `task_lock`;
3. if there is no current task, marks the mutex locked and returns;
4. if the mutex is free, records the current task as owner and returns;
5. if the current task is idle or the wait queue is full, returns without
   blocking (idle must never contend);
6. otherwise enqueues the current task and **pre-marks it blocked** while still
   holding `task_lock`;
7. releases `task_lock`, executes `int $51`, and restores interrupts.

Pre-marking is the key to cross-CPU correctness. Once the waiter is in the
queue and marked `blocked` under `task_lock`, another CPU's `unlock` can transfer
ownership and send the reschedule IPI. If the wakeup arrives before
`blockCurrent` runs, `blockCurrent` sees `.ready` and simply returns without
switching, so the wakeup is not lost.

`unlock()` acquires `task_lock` and calls `unlockLocked()`:

- if a waiter is woken, the mutex stays locked and ownership is assigned to the
  woken task;
- otherwise the mutex becomes unlocked and the owner is cleared.

The mutex is **not reentrant**. Locking it twice on the same task deadlocks.
Because ownership is transferred directly, the resumed `lock()` call already
owns the mutex; it does not re-check the `locked` flag.

## `Condition`

`Condition` is used with a `Mutex`:

- `wait(mutex)` saves and disables interrupts, acquires `task_lock`, rejects a
  missing current task or the idle task, enqueues the current task on the
  condition's wait queue, pre-marks it blocked, releases the mutex with
  `unlockLocked()`, releases `task_lock`, executes `int $51`, restores
  interrupts, and then calls `mutex.lock()` before returning.
- `signal()` acquires `task_lock` and wakes one waiter.
- `broadcast()` acquires `task_lock` and wakes all waiters.

Enqueueing, marking blocked, and releasing the mutex are atomic with respect to
`task_lock`, so a signaller holding the same mutex cannot run between the
predicate check and the block. Callers must follow the usual
condition-variable discipline: change the predicate and signal while holding the
associated mutex. Signalling without holding the predicate's mutex can still lose
a wakeup.

Neither `Mutex` nor `Condition` is reentrant.

## Lock ordering

The following order is used. A lock at a lower level may be acquired while
holding a higher-level lock; the reverse is forbidden.

| Order | Lock | Protects |
| --- | --- | --- |
| 1 | `vmm.table_lock` (`IrqSpinLock`) | Page tables and VMM mapping mutation. |
| 2 | `pmm.lock` (`IrqSpinLock`) | PMM bitmaps and counters. The VMM may allocate a table page while holding `table_lock`, so `table_lock` is acquired before `pmm.lock`. |
| 3 | `task_lock` (`IrqSpinLock`) | Task table, per-CPU run state, wait queues, mutex/condition state. Never held while taking a memory or console lock, and no console output occurs while it is held. |
| 4 | `console.lock` (`IrqSpinLock`) | Framebuffer grid and cursor. `console.write` then calls `serial.write`, so `console.lock` is acquired before `serial.lock`. |
| 5 | `serial.lock` (`IrqSpinLock`) | Complete serial messages. |
| — | `tlb_lock` (`SpinLock`) | TLB shootdown request/ack state. Independent of the others: it is taken only after `vmm.table_lock` has been released, and no other lock is taken while holding it. It is deliberately not IRQ-safe so a CPU waiting for it can still acknowledge a remote shootdown IPI. |

The heap has no lock. `heap.alloc`/`free` may call into the PMM and VMM, so any
future heap lock must be ordered above `vmm.table_lock`/`pmm.lock` and must not
be taken together with `task_lock`.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Atomic `SpinLock` | **IMPLEMENTED** | Acquire/release ordering and `pause` spin. |
| `IrqSpinLock` | **IMPLEMENTED** | Per-acquisition guard; safe under contention and nested use of distinct locks. |
| `IrqLock` | **IMPLEMENTED** | Per-acquisition guard; single-CPU interrupt masking only. |
| Wait queue with signal/timeout | **IMPLEMENTED** | Task-ID based; SMP-aware wake IPI. |
| Blocking mutex with ownership transfer | **IMPLEMENTED** | Not reentrant; idle cannot block; pre-marked blocked. |
| Condition variable | **IMPLEMENTED** | Requires predicate mutex discipline. |
| Cross-CPU wakeups | **IMPLEMENTED** | Reschedule IPI vector 240. |
| Explicit lock ordering | **IMPLEMENTED** | Table above; heap lock still deferred. |
| PMM/VMM locking | **IMPLEMENTED** | IRQ-safe locks; VMM callback after unlock. |
| Console/serial locking | **IMPLEMENTED** | IRQ-safe message locks. |
| Heap locking | **PLANNED** | Free list remains single-CPU. |

## Related documentation

- [Overview](overview.md)
- [Scheduling](scheduling.md)
- [CPU and interrupts](cpu-interrupts.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
- [Roadmap](../development/roadmap.md)
- [Testing](../development/testing.md)
