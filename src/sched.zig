//! Per-CPU round-robin kernel task scheduler.
//!
//! CPU 0 is the bootstrap processor; every CPU owns a `CpuState` with its
//! current task, idle task, and pending sleep/wait request. Tasks are assigned
//! to a CPU at creation time and run only on that CPU. A single global
//! `task_lock` protects the task table, wait queues, and scheduling decisions;
//! it never covers task execution, so CPUs run tasks in parallel.
//!
//! Every CPU has its own tick counter. CPU 0 uses the PIT (IRQ0); application
//! processors use a periodic LAPIC timer on `timer_vector` (242). A timer tick
//! wakes timed sleepers pinned to that CPU and may preempt its current task.
//! Cross-CPU wakeups use LAPIC IPIs: `reschedule_vector` (240) makes the target
//! CPU re-evaluate its run queue and `tlb_vector` (241) invalidates a page that
//! another CPU just unmapped.
//!
//! The interrupt entry stub saves x87/SSE state to the address in `%gs:0`. The
//! scheduler updates that per-CPU pointer in `switchTaskLocked`, so no global
//! FPU pointer is shared between CPUs.

const gdt = @import("arch/x86_64/gdt.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const sync = @import("sync.zig");

pub const max_tasks = 32;
pub const max_cpus = cpu.max_cpus;

pub const reschedule_vector: u8 = 240;
pub const tlb_vector: u8 = 241;
pub const timer_vector: u8 = 242;

pub const yield_vector: u8 = 48;
pub const exit_vector: u8 = 49;
pub const sleep_vector: u8 = 50;
pub const block_vector: u8 = 51;
pub const wait_vector: u8 = 52;
pub const wait_timeout_vector: u8 = 53;

pub const Entry = *const fn () callconv(.c) void;

pub const TaskState = enum { idle, ready, running, blocked, finished };
pub const WakeReason = enum { none, signal, timeout };
pub const FpuState = [512]u8;

pub const Task = struct {
    name: []const u8,
    rsp: u64,
    state: TaskState,
    ticks: u64,
    wake_tick: u64,
    wake_reason: WakeReason,
    fpu_state: FpuState align(16),
    id: u32,
    index: usize,
    cpu: u32,
    is_idle: bool,
};

const WaitTimeoutRequest = struct {
    queue: *WaitQueue,
    ticks: u64,
};

const CpuState = struct {
    current: ?*Task = null,
    idle: ?*Task = null,
    next_scan: usize = 0,
    sleep_request: u64 = 0,
    wait_request: ?*WaitQueue = null,
    wait_timeout_request: ?WaitTimeoutRequest = null,
};

pub const WaitQueue = struct {
    waiters: [max_tasks]u32 = @splat(0),
    count: usize = 0,

    /// Block the current task on this queue. The queue insertion and the
    /// transition to `blocked` happen atomically in `waitQueueCurrent`.
    pub fn wait(self: *WaitQueue) void {
        const flags = sync.irqSave();
        asm volatile ("cli");
        cpu_state[cpu.currentIndex()].wait_request = self;
        asm volatile ("int $52" ::: .{ .memory = true });
        sync.irqRestore(flags);
    }

    /// Block until signalled or until `duration` ticks have elapsed. Returns
    /// true only for a signal; a timeout returns false.
    pub fn waitTimeout(self: *WaitQueue, duration: u64) bool {
        if (duration == 0) return false;

        const flags = sync.irqSave();
        asm volatile ("cli");
        const index = cpu.currentIndex();
        if (cpu_state[index].current) |task| task.wake_reason = .none;
        cpu_state[index].wait_timeout_request = .{ .queue = self, .ticks = duration };
        asm volatile ("int $53" ::: .{ .memory = true });

        const current_task = cpu_state[index].current orelse {
            sync.irqRestore(flags);
            return false;
        };
        const signaled = current_task.wake_reason == .signal;
        sync.irqRestore(flags);
        return signaled;
    }

    pub fn wakeOne(self: *WaitQueue) bool {
        const guard = task_lock.acquire();
        defer guard.release();
        return self.wakeOneTaskLocked() != null;
    }

    pub fn wakeAll(self: *WaitQueue) usize {
        const guard = task_lock.acquire();
        defer guard.release();
        return self.wakeAllLocked();
    }

    // The helpers below require `task_lock` (which also disables interrupts on
    // the calling CPU).
    fn enqueueCurrentLocked(self: *WaitQueue) bool {
        const current_task = currentTask() orelse return false;
        self.compactLocked();
        if (self.count >= self.waiters.len) return false;
        self.waiters[self.count] = current_task.id;
        self.count += 1;
        return true;
    }

    fn wakeOneTaskLocked(self: *WaitQueue) ?*Task {
        while (self.count > 0) {
            const id = self.waiters[0];
            self.removeAt(0);
            if (findTaskById(id)) |task| {
                if (wakeLocked(task, .signal)) return task;
            }
        }
        return null;
    }

    fn wakeAllLocked(self: *WaitQueue) usize {
        var woken: usize = 0;
        for (self.waiters[0..self.count]) |id| {
            if (findTaskById(id)) |task| {
                if (wakeLocked(task, .signal)) woken += 1;
            }
        }
        self.count = 0;
        return woken;
    }

    fn compactLocked(self: *WaitQueue) void {
        var write: usize = 0;
        for (self.waiters[0..self.count]) |id| {
            if (findTaskById(id)) |task| {
                if (task.state == .blocked) {
                    self.waiters[write] = id;
                    write += 1;
                }
            }
        }
        self.count = write;
    }

    fn removeAt(self: *WaitQueue, index: usize) void {
        var cursor = index;
        while (cursor + 1 < self.count) : (cursor += 1) {
            self.waiters[cursor] = self.waiters[cursor + 1];
        }
        self.count -= 1;
    }
};

/// Blocking mutex. Ownership is transferred directly to a waiter on unlock,
/// and the waiter resumes from `lock` already owning the mutex.
pub const Mutex = struct {
    locked: bool = false,
    owner: ?*Task = null,
    waiters: WaitQueue = .{},

    pub fn lock(self: *Mutex) void {
        // Keep interrupts disabled across the enqueue-and-block sequence so a
        // preemptive reschedule cannot run between the two steps.
        const flags = sync.irqSave();
        asm volatile ("cli");
        const guard = task_lock.acquire();

        const current_task = currentTask() orelse {
            self.locked = true;
            guard.release();
            sync.irqRestore(flags);
            return;
        };

        if (!self.locked) {
            self.locked = true;
            self.owner = current_task;
            guard.release();
            sync.irqRestore(flags);
            return;
        }

        if (current_task.is_idle or !self.waiters.enqueueCurrentLocked()) {
            guard.release();
            sync.irqRestore(flags);
            return;
        }

        // Mark the task blocked before releasing the scheduler lock: another
        // CPU's unlock can now wake it without losing the wakeup. The block
        // handler notices the pre-marked state and only switches stacks.
        blockCurrentLocked(current_task, ~@as(u64, 0));
        guard.release();
        asm volatile ("int $51" ::: .{ .memory = true });
        sync.irqRestore(flags);
    }

    pub fn unlock(self: *Mutex) void {
        const guard = task_lock.acquire();
        defer guard.release();
        self.unlockLocked();
    }

    fn unlockLocked(self: *Mutex) void {
        if (self.waiters.wakeOneTaskLocked()) |task| {
            self.locked = true;
            self.owner = task;
        } else {
            self.locked = false;
            self.owner = null;
        }
    }
};

/// Condition variable used with `Mutex`. Predicates must be changed and
/// signalled while the associated mutex is held.
pub const Condition = struct {
    waiters: WaitQueue = .{},

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const flags = sync.irqSave();
        asm volatile ("cli");
        const guard = task_lock.acquire();

        const current_task = currentTask() orelse {
            guard.release();
            sync.irqRestore(flags);
            return;
        };
        if (current_task.is_idle or !self.waiters.enqueueCurrentLocked()) {
            guard.release();
            sync.irqRestore(flags);
            return;
        }

        // Enqueue, pre-mark blocked, and release the mutex under the same
        // scheduler lock so no signaller can run ahead of the enqueue.
        blockCurrentLocked(current_task, ~@as(u64, 0));
        mutex.unlockLocked();
        guard.release();
        asm volatile ("int $51" ::: .{ .memory = true });
        sync.irqRestore(flags);
        mutex.lock();
    }

    pub fn signal(self: *Condition) bool {
        const guard = task_lock.acquire();
        defer guard.release();
        return self.waiters.wakeOneTaskLocked() != null;
    }

    pub fn broadcast(self: *Condition) usize {
        const guard = task_lock.acquire();
        defer guard.release();
        return self.waiters.wakeAllLocked();
    }
};

pub const Stats = struct {
    ticks: u64,
    tasks: usize,
    finished: u64,
    blocked: u64,
    current_id: u32,
    enabled: bool,
    online_cpus: u64,
};

const saved_registers = 15;
const iret_frame_qwords = 5;
const initial_frame_qwords = saved_registers + 2 + iret_frame_qwords;
const idle_stack_size = 8 * 1024;

var tasks: [max_tasks]Task = undefined;
var task_count: usize = 0;
var cpu_ticks: [max_cpus]u64 = @splat(0);
var finished_counter: u64 = 0;
var blocked_counter: u64 = 0;
var next_id: u32 = 0;
var enabled = false;
var initialized = false;

var cpu_state: [max_cpus]CpuState = @splat(.{});
var idle_stacks: [max_cpus][idle_stack_size]u8 align(16) = undefined;

var fpu_template: FpuState align(16) = @splat(0);

var task_lock: sync.IrqSpinLock = .{};

/// Bit N is set once CPU N has reached its scheduler idle loop.
var online_mask: u64 = 0;

/// Per-CPU TLB shootdown mailboxes. A shooter writes row `[shooter][target]`;
/// the target acknowledges through `tlb_ack_seq[target][shooter]`. Each cell has
/// a single writer, so the protocol is lock-free. Sequence numbers prevent a
/// stale request from being mistaken for a new one.
///
/// `shootdownTlb` must run with interrupts enabled when other CPUs are online.
/// The waiting CPU has to take their shootdown IPIs; a caller that disables
/// interrupts and then waits can deadlock against another CPU doing the same.
var tlb_virt: [max_cpus][max_cpus]u64 = @splat(@splat(0));
var tlb_request_seq: [max_cpus][max_cpus]u64 = @splat(@splat(0));
var tlb_ack_seq: [max_cpus][max_cpus]u64 = @splat(@splat(0));
var tlb_next_seq: u64 = 0;
var tlb_requests: u64 = 0;
var reschedule_count: u64 = 0;

extern fn sched_resume(rsp: u64) callconv(.c) noreturn;

pub fn init() void {
    const guard = task_lock.acquire();
    defer guard.release();

    initFpuTemplate();

    task_count = 0;
    cpu_ticks = @splat(0);
    finished_counter = 0;
    blocked_counter = 0;
    next_id = 2;
    enabled = true;
    initialized = true;
    cpu_state = @splat(.{});
    online_mask = 0;
    tlb_virt = @splat(@splat(0));
    tlb_request_seq = @splat(@splat(0));
    tlb_ack_seq = @splat(@splat(0));
    tlb_next_seq = 0;
    tlb_requests = 0;

    tasks[0] = .{
        .name = "boot",
        .rsp = 0,
        .state = .running,
        .ticks = 0,
        .wake_tick = 0,
        .wake_reason = .none,
        .fpu_state = fpu_template,
        .id = 0,
        .index = 0,
        .cpu = 0,
        .is_idle = false,
    };
    task_count = 1;
    cpu_state[0] = .{ .current = &tasks[0] };
    _ = @atomicRmw(u64, &online_mask, .Or, 1, .release);

    _ = ensureIdleLocked(0) orelse unreachable;
    cpu_state[0].next_scan = 1;
    cpu.setFpuState(@intFromPtr(&tasks[0].fpu_state));
}

pub fn create(name: []const u8, entry: Entry, stack: []u8) ?*Task {
    return createOn(cpu.currentIndex(), name, entry, stack);
}

/// Create a task pinned to `target_cpu`. A remote target receives a
/// reschedule IPI so it enters its run queue promptly.
pub fn createOn(target_cpu: u32, name: []const u8, entry: Entry, stack: []u8) ?*Task {
    if (!initialized or target_cpu >= max_cpus) return null;

    const guard = task_lock.acquire();
    defer guard.release();
    return createLocked(target_cpu, name, entry, stack);
}

fn createLocked(target_cpu: u32, name: []const u8, entry: Entry, stack: []u8) ?*Task {
    const index = findSlotLocked() orelse return null;
    const rsp = initialFrame(stack, entry) orelse return null;
    const id = next_id;
    next_id +%= 1;

    tasks[index] = .{
        .name = name,
        .rsp = rsp,
        .state = .ready,
        .ticks = 0,
        .wake_tick = 0,
        .wake_reason = .none,
        .fpu_state = fpu_template,
        .id = id,
        .index = index,
        .cpu = target_cpu,
        .is_idle = false,
    };
    if (index == task_count) task_count += 1;

    if (target_cpu != cpu.currentIndex()) sendRescheduleLocked(target_cpu);
    return &tasks[index];
}

/// Install scheduler state for an application processor and mark it online.
/// The caller then invokes `enterScheduler`, which switches to the idle frame.
pub fn initCpu(index: u32, lapic_id: u32) bool {
    _ = lapic_id;
    if (!initialized or index == 0 or index >= max_cpus) return false;

    const guard = task_lock.acquire();
    defer guard.release();

    const idle = ensureIdleLocked(index) orelse return false;
    cpu_state[index].current = idle;
    cpu_state[index].next_scan = idle.index;
    idle.state = .running;
    _ = @atomicRmw(u64, &online_mask, .Or, @as(u64, 1) << @intCast(index), .release);
    cpu.setFpuState(@intFromPtr(&idle.fpu_state));
    return true;
}

/// Leave the AP's boot stack and resume the idle task's initial frame. Called
/// with interrupts disabled; the idle frame enables them on `iretq`.
pub fn enterScheduler() noreturn {
    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    const state = &cpu_state[index];
    const idle = state.idle orelse {
        guard.release();
        haltForever();
    };
    state.current = idle;
    idle.state = .running;
    const rsp = idle.rsp;
    cpu.setFpuState(@intFromPtr(&idle.fpu_state));
    guard.release();
    sched_resume(rsp);
}

/// Timer interrupt entry shared by PIT IRQ0 on the BSP and the LAPIC timer on
/// application processors. Only the local CPU's tick counter advances, and only
/// that CPU's timed sleepers are woken. Preemption stays per-CPU.
pub fn timerInterrupt(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const now = @atomicRmw(u64, &cpu_ticks[index], .Add, 1, .monotonic) + 1;
    wakeBlockedLocked(index, now);

    const current_task = cpu_state[index].current orelse return saved_rsp;
    current_task.rsp = saved_rsp;
    current_task.ticks +%= 1;
    if (!enabled) return saved_rsp;

    if (current_task.state == .ready) current_task.state = .running;
    if (current_task.state != .running) return saved_rsp;

    if (pickNextLocked(index)) |next| {
        if (current_task.is_idle) {
            current_task.state = .idle;
        } else {
            current_task.state = .ready;
        }
        return switchTaskLocked(index, next);
    }
    return saved_rsp;
}

/// IPI handler: another CPU queued a task for this one, or a blocked task was
/// made ready. Re-evaluate the run queue without advancing the tick counter.
pub fn rescheduleInterrupt(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    _ = @atomicRmw(u64, &reschedule_count, .Add, 1, .monotonic);
    const current_task = cpu_state[index].current orelse return saved_rsp;
    if (current_task.state == .ready) current_task.state = .running;
    current_task.rsp = saved_rsp;
    if (!enabled) return saved_rsp;

    if (pickNextLocked(index)) |next| {
        if (current_task.is_idle) {
            current_task.state = .idle;
        } else {
            current_task.state = .ready;
        }
        return switchTaskLocked(index, next);
    }
    return saved_rsp;
}

pub fn yieldCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const current_task = cpu_state[index].current orelse return saved_rsp;
    if (current_task.is_idle) return saved_rsp;
    if (current_task.state == .ready) current_task.state = .running;
    current_task.rsp = saved_rsp;
    if (!enabled) return saved_rsp;

    if (pickNextLocked(index)) |next| {
        current_task.state = .ready;
        return switchTaskLocked(index, next);
    }
    return saved_rsp;
}

pub fn exitCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const current_task = cpu_state[index].current orelse return saved_rsp;
    current_task.rsp = saved_rsp;
    if (current_task.is_idle) haltForever();

    current_task.state = .finished;
    _ = @atomicRmw(u64, &finished_counter, .Add, 1, .monotonic);

    if (pickNextLocked(index)) |next| return switchTaskLocked(index, next);
    const idle = cpu_state[index].idle orelse haltForever();
    return switchTaskLocked(index, idle);
}

pub fn sleep(duration: u64) void {
    if (duration == 0) return;

    const flags = sync.irqSave();
    asm volatile ("cli");
    cpu_state[cpu.currentIndex()].sleep_request = duration;
    asm volatile ("int $50" ::: .{ .memory = true });
    sync.irqRestore(flags);
}

pub fn sleepCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const current_task = cpu_state[index].current orelse return saved_rsp;
    const duration = cpu_state[index].sleep_request;
    cpu_state[index].sleep_request = 0;
    if (current_task.is_idle or duration == 0 or !enabled) return saved_rsp;

    current_task.rsp = saved_rsp;
    const now = @atomicLoad(u64, &cpu_ticks[index], .monotonic);
    blockCurrentLocked(current_task, now +% duration);
    return switchBlockedLocked(index, current_task);
}

pub fn block() void {
    const flags = sync.irqSave();
    asm volatile ("cli");
    asm volatile ("int $51" ::: .{ .memory = true });
    sync.irqRestore(flags);
}

pub fn blockCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const current_task = cpu_state[index].current orelse return saved_rsp;
    if (current_task.is_idle or !enabled) return saved_rsp;

    // A remote wake may have marked us ready between enqueueing and entering
    // this handler. In that case the wakeup must not be lost.
    if (current_task.state == .ready) {
        current_task.state = .running;
        return saved_rsp;
    }
    if (current_task.state != .blocked) {
        blockCurrentLocked(current_task, ~@as(u64, 0));
    }

    current_task.rsp = saved_rsp;
    return switchBlockedLocked(index, current_task);
}

pub fn waitQueueCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const queue = cpu_state[index].wait_request orelse return saved_rsp;
    cpu_state[index].wait_request = null;

    const current_task = cpu_state[index].current orelse return saved_rsp;
    if (current_task.is_idle or !enabled) return saved_rsp;

    queue.compactLocked();
    if (queue.count >= queue.waiters.len) return saved_rsp;
    queue.waiters[queue.count] = current_task.id;
    queue.count += 1;

    if (current_task.state != .blocked) blockCurrentLocked(current_task, ~@as(u64, 0));
    current_task.rsp = saved_rsp;
    return switchBlockedLocked(index, current_task);
}

pub fn waitTimeoutCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;

    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();

    const request = cpu_state[index].wait_timeout_request orelse return saved_rsp;
    cpu_state[index].wait_timeout_request = null;

    const current_task = cpu_state[index].current orelse return saved_rsp;
    if (current_task.is_idle or !enabled) return saved_rsp;

    request.queue.compactLocked();
    if (request.queue.count >= request.queue.waiters.len) return saved_rsp;
    request.queue.waiters[request.queue.count] = current_task.id;
    request.queue.count += 1;

    current_task.rsp = saved_rsp;
    const now = @atomicLoad(u64, &cpu_ticks[index], .monotonic);
    blockCurrentLocked(current_task, now +% request.ticks);
    return switchBlockedLocked(index, current_task);
}

pub fn wake(task: *Task) bool {
    if (!initialized) return false;
    const guard = task_lock.acquire();
    defer guard.release();
    return wakeLocked(task, .signal);
}

fn wakeLocked(task: *Task, reason: WakeReason) bool {
    if (task.state != .blocked) return false;
    task.state = .ready;
    task.wake_reason = reason;
    _ = @atomicRmw(u64, &blocked_counter, .Sub, 1, .monotonic);
    if (task.cpu != cpu.currentIndex()) sendRescheduleLocked(task.cpu);
    return true;
}

pub fn yield() void {
    asm volatile ("int $48" ::: .{ .memory = true });
}

pub fn exit() noreturn {
    asm volatile ("int $49" ::: .{ .memory = true });
    haltForever();
}

pub fn stop() void {
    const guard = task_lock.acquire();
    defer guard.release();
    enabled = false;
}

pub fn resumeScheduling() void {
    const guard = task_lock.acquire();
    defer guard.release();
    enabled = true;
}

pub fn ticks() u64 {
    return ticksOn(cpu.currentIndex());
}

/// Tick counter for one CPU. Counters start at zero and advance independently.
pub fn ticksOn(index: u32) u64 {
    if (index >= max_cpus) return 0;
    return @atomicLoad(u64, &cpu_ticks[index], .monotonic);
}

pub fn finishedCount() u64 {
    return @atomicLoad(u64, &finished_counter, .monotonic);
}

pub fn blockedCount() u64 {
    return @atomicLoad(u64, &blocked_counter, .monotonic);
}

pub fn onlineCount() u64 {
    return @popCount(@atomicLoad(u64, &online_mask, .acquire));
}

pub fn tlbShootdownCount() u64 {
    return @atomicLoad(u64, &tlb_requests, .monotonic);
}

pub fn rescheduleCount() u64 {
    return @atomicLoad(u64, &reschedule_count, .monotonic);
}

pub fn stats() Stats {
    const index = cpu.currentIndex();
    const guard = task_lock.acquire();
    defer guard.release();
    return .{
        .ticks = ticks(),
        .tasks = task_count,
        .finished = finishedCount(),
        .blocked = blockedCount(),
        .current_id = if (cpu_state[index].current) |task| task.id else 0,
        .enabled = enabled,
        .online_cpus = @popCount(@atomicLoad(u64, &online_mask, .acquire)),
    };
}

/// Invalidate `virt` on every other online CPU. Called by the VMM after
/// releasing its page-table lock. The local CPU has already executed `invlpg`.
///
/// The request is published in this CPU's mailbox row before each IPI. The
/// shooter then waits until every target has acknowledged its sequence number.
/// There is no timeout: a target that runs with interrupts disabled keeps the
/// request pending in its LAPIC until it enables interrupts, at which point the
/// handler invalidates the page and acknowledges. Callers must therefore not
/// call `unmapPage` with interrupts disabled when other CPUs are online.
pub fn shootdownTlb(virt: u64) void {
    const me: usize = @intCast(cpu.currentIndex());
    const targets = @atomicLoad(u64, &online_mask, .acquire) & ~(@as(u64, 1) << @intCast(me));

    _ = @atomicRmw(u64, &tlb_requests, .Add, 1, .monotonic);
    if (targets == 0) return;

    const seq = @atomicRmw(u64, &tlb_next_seq, .Add, 1, .monotonic) + 1;

    var index: usize = 0;
    while (index < max_cpus) : (index += 1) {
        if ((targets & (@as(u64, 1) << @intCast(index))) == 0) continue;
        @atomicStore(u64, &tlb_virt[me][index], virt, .monotonic);
        @atomicStore(u64, &tlb_request_seq[me][index], seq, .release);
        lapic.sendIpi(cpu.per_cpu[index].lapic_id, tlb_vector);
    }

    index = 0;
    while (index < max_cpus) : (index += 1) {
        if ((targets & (@as(u64, 1) << @intCast(index))) == 0) continue;
        while (@atomicLoad(u64, &tlb_ack_seq[index][me], .acquire) < seq) {
            asm volatile ("pause");
        }
    }
}

/// IPI handler: scan every shooter's mailbox, invalidate new requests, and
/// acknowledge. No locks are taken, so a CPU spinning in `shootdownTlb` can
/// still service a request from another CPU.
pub fn tlbInterrupt() void {
    const me: usize = @intCast(cpu.currentIndex());
    var shooter: usize = 0;
    while (shooter < max_cpus) : (shooter += 1) {
        const seq = @atomicLoad(u64, &tlb_request_seq[shooter][me], .acquire);
        if (seq == 0) continue;
        if (seq <= @atomicLoad(u64, &tlb_ack_seq[me][shooter], .acquire)) continue;

        const virt = @atomicLoad(u64, &tlb_virt[shooter][me], .acquire);
        asm volatile ("invlpg (%[virt])"
            :
            : [virt] "r" (virt),
            : .{ .memory = true });
        @atomicStore(u64, &tlb_ack_seq[me][shooter], seq, .release);
    }
}

fn currentTask() ?*Task {
    return cpu_state[cpu.currentIndex()].current;
}

fn blockCurrentLocked(task: *Task, wake_tick: u64) void {
    task.state = .blocked;
    task.wake_tick = wake_tick;
    task.wake_reason = .none;
    _ = @atomicRmw(u64, &blocked_counter, .Add, 1, .monotonic);
}

/// Switch away from a task that has just been marked blocked or finished.
fn switchBlockedLocked(index: u32, task: *Task) u64 {
    if (tasksBlockedNext(index)) |next| return switchTaskLocked(index, next);
    const idle = cpu_state[index].idle orelse return task.rsp;
    if (idle == task) return task.rsp;
    return switchTaskLocked(index, idle);
}

fn tasksBlockedNext(index: u32) ?*Task {
    return pickNextLocked(index);
}

fn pickNextLocked(index: u32) ?*Task {
    if (task_count == 0) return null;
    var start = cpu_state[index].next_scan;
    if (start >= task_count) start = 0;

    var offset: usize = 0;
    while (offset < task_count) : (offset += 1) {
        const slot = (start + offset) % task_count;
        const task = &tasks[slot];
        if (task.state == .ready and task.cpu == index and !task.is_idle) {
            cpu_state[index].next_scan = (slot + 1) % task_count;
            return task;
        }
    }
    return null;
}

fn switchTaskLocked(index: u32, next: *Task) u64 {
    next.state = .running;
    cpu_state[index].current = next;
    cpu.setFpuState(@intFromPtr(&next.fpu_state));
    return next.rsp;
}

fn ensureIdleLocked(index: u32) ?*Task {
    if (cpu_state[index].idle) |idle| return idle;

    const slot = findSlotLocked() orelse return null;
    const rsp = initialFrame(idle_stacks[index][0..], idleEntry) orelse return null;
    const id = next_id;
    next_id +%= 1;

    tasks[slot] = .{
        .name = "idle",
        .rsp = rsp,
        .state = .idle,
        .ticks = 0,
        .wake_tick = 0,
        .wake_reason = .none,
        .fpu_state = fpu_template,
        .id = id,
        .index = slot,
        .cpu = index,
        .is_idle = true,
    };
    if (slot == task_count) task_count += 1;

    const idle = &tasks[slot];
    cpu_state[index].idle = idle;
    return idle;
}

fn wakeBlockedLocked(index: u32, now: u64) void {
    var task_index: usize = 0;
    while (task_index < task_count) : (task_index += 1) {
        const task = &tasks[task_index];
        if (task.cpu == index and task.state == .blocked and now >= task.wake_tick) {
            _ = wakeLocked(task, .timeout);
        }
    }
}

fn findTaskById(id: u32) ?*Task {
    var index: usize = 0;
    while (index < task_count) : (index += 1) {
        if (tasks[index].id == id) return &tasks[index];
    }
    return null;
}

fn findSlotLocked() ?usize {
    var index: usize = 1;
    while (index < task_count) : (index += 1) {
        if (tasks[index].state == .finished) return index;
    }
    if (task_count < max_tasks) return task_count;
    return null;
}

fn sendRescheduleLocked(target_cpu: u32) void {
    if (target_cpu >= max_cpus) return;
    const bit = @as(u64, 1) << @intCast(target_cpu);
    if ((@atomicLoad(u64, &online_mask, .acquire) & bit) == 0) return;
    lapic.sendIpi(cpu.per_cpu[target_cpu].lapic_id, reschedule_vector);
}

fn idleEntry() callconv(.c) void {
    while (true) {
        asm volatile ("sti; hlt");
    }
}

/// Return trampoline for task entries. Reached by `ret` when an entry returns
/// instead of calling `sched.exit()`.
fn taskReturn() callconv(.naked) noreturn {
    asm volatile (
        \\int $49
        \\1: cli
        \\hlt
        \\jmp 1b
    );
}

fn haltForever() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

fn initFpuTemplate() void {
    var saved: FpuState align(16) = undefined;
    saveFpu(&saved);
    asm volatile (
        \\fninit
        \\xorps %%xmm0, %%xmm0
        \\xorps %%xmm1, %%xmm1
        \\xorps %%xmm2, %%xmm2
        \\xorps %%xmm3, %%xmm3
        \\xorps %%xmm4, %%xmm4
        \\xorps %%xmm5, %%xmm5
        \\xorps %%xmm6, %%xmm6
        \\xorps %%xmm7, %%xmm7
        \\xorps %%xmm8, %%xmm8
        \\xorps %%xmm9, %%xmm9
        \\xorps %%xmm10, %%xmm10
        \\xorps %%xmm11, %%xmm11
        \\xorps %%xmm12, %%xmm12
        \\xorps %%xmm13, %%xmm13
        \\xorps %%xmm14, %%xmm14
        \\xorps %%xmm15, %%xmm15
        ::: .{
            .xmm0 = true,
            .xmm1 = true,
            .xmm2 = true,
            .xmm3 = true,
            .xmm4 = true,
            .xmm5 = true,
            .xmm6 = true,
            .xmm7 = true,
            .xmm8 = true,
            .xmm9 = true,
            .xmm10 = true,
            .xmm11 = true,
            .xmm12 = true,
            .xmm13 = true,
            .xmm14 = true,
            .xmm15 = true,
            .memory = true,
        });
    saveFpu(&fpu_template);
    restoreFpu(&saved);
}

fn saveFpu(state: *FpuState) void {
    asm volatile ("fxsave64 (%[state])"
        :
        : [state] "r" (state),
        : .{ .memory = true });
}

fn restoreFpu(state: *FpuState) void {
    asm volatile ("fxrstor64 (%[state])"
        :
        : [state] "r" (state),
        : .{
          .xmm0 = true,
          .xmm1 = true,
          .xmm2 = true,
          .xmm3 = true,
          .xmm4 = true,
          .xmm5 = true,
          .xmm6 = true,
          .xmm7 = true,
          .xmm8 = true,
          .xmm9 = true,
          .xmm10 = true,
          .xmm11 = true,
          .xmm12 = true,
          .xmm13 = true,
          .xmm14 = true,
          .xmm15 = true,
          .memory = true,
        });
}

fn initialFrame(stack: []u8, entry: Entry) ?u64 {
    if (stack.len < 512) return null;

    const start = @intFromPtr(stack.ptr);
    const top = (start + stack.len) & ~@as(usize, 15);
    if (top < start + 256) return null;

    const entry_rsp = top - 8;
    const base = entry_rsp - initial_frame_qwords * @sizeOf(u64);
    const frame: [*]u64 = @ptrFromInt(base);
    @memset(frame[0..initial_frame_qwords], 0);

    const return_slot: *u64 = @ptrFromInt(entry_rsp);
    return_slot.* = @intFromPtr(&taskReturn);

    frame[saved_registers + 2] = @intCast(@intFromPtr(entry));
    frame[saved_registers + 3] = @as(u64, gdt.kernel_code_selector);
    frame[saved_registers + 4] = 0x202;
    frame[saved_registers + 5] = entry_rsp;
    frame[saved_registers + 6] = @as(u64, gdt.kernel_data_selector);
    return base;
}
