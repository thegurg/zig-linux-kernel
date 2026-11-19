//! Process table, spawn/wait/reap, and generation-tagged handles.
//!
//! A process owns a user address space, a kernel stack, and one joinable
//! scheduler task. The scheduler keeps a finished joinable task slot until
//! `reap` detaches it, so a process handle stays valid after exit and its task
//! ID cannot alias a newly created task.
//!
//! `wait` polls the task state at tick granularity instead of using the
//! scheduler's single-waiter `join`. This keeps the exit status available until
//! `reap` and avoids consuming the join slot. `wait` with a non-zero timeout
//! sleeps for one tick between checks; zero means wait indefinitely.
//!
//! `process_lock` protects only the table. It is never held while allocating,
//! loading an image, blocking, or calling the scheduler, so it does not add a
//! new edge to the documented lock order.

const heap = @import("memory/heap.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const time = @import("time.zig");
const user = @import("user.zig");

pub const max_processes = 16;
pub const kernel_stack_size = 16 * 1024;
const max_name = 24;

const State = enum { unused, starting, running, exited, reaping };

const Process = struct {
    state: State = .unused,
    generation: u32 = 0,
    task: ?*sched.Task = null,
    task_id: u32 = 0,
    exit_status: i32 = 0,
    kernel_stack: ?[*]u8 = null,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,
};

pub const Handle = struct {
    /// One-based process slot; zero is never a valid handle.
    pid: u32,
    generation: u32,
};

pub const SpawnOptions = struct {
    cpu: ?u32 = null,
    priority: sched.Priority = .normal,
    name: []const u8 = "user",
    argv: []const []const u8 = &.{},
    envp: []const []const u8 = &.{},
};

pub const SpawnError = user.LoadError || error{
    NotInitialized,
    TableFull,
    OutOfMemory,
    TaskCreationFailed,
};

pub const WaitOutcome = enum { exited, timeout, invalid };

pub const WaitResult = struct {
    outcome: WaitOutcome,
    status: i32,
};

pub const ReapOutcome = enum { reaped, not_exited, invalid };

pub const ReapResult = struct {
    outcome: ReapOutcome,
    status: i32,
};

pub const Stats = struct {
    slots: usize,
    live: usize,
    exited: usize,
    spawned: u64,
    reaped: u64,
};

const Reservation = struct {
    index: usize,
    pid: u32,
    generation: u32,
};

const Snapshot = struct {
    state: State,
    task_id: u32,
    exit_status: i32,
};

var processes: [max_processes]Process = @splat(.{});
var process_lock: sync.IrqSpinLock = .{};
var initialized = false;
var spawned_count: u64 = 0;
var reaped_count: u64 = 0;

pub fn init() void {
    const guard = process_lock.acquire();
    defer guard.release();

    processes = @splat(.{});
    spawned_count = 0;
    reaped_count = 0;
    initialized = true;
}

/// Load an ELF image, create a ring-3 task, and publish a generation-tagged
/// process handle. All failure paths release the address space, kernel stack,
/// and reserved table slot.
pub fn spawn(bytes: []const u8, options: SpawnOptions) SpawnError!Handle {
    if (!initialized) return error.NotInitialized;

    const reservation = try reserve();
    errdefer releaseReservation(reservation);

    const stack = heap.alloc(kernel_stack_size, 16) orelse return error.OutOfMemory;
    errdefer heap.free(stack, kernel_stack_size);

    const image = try user.loadProcessWith(bytes, options.argv, options.envp, .{});
    errdefer user.destroy(image.root);

    const task = sched.createUser(
        options.name,
        image.entry,
        stack[0..kernel_stack_size],
        image.root,
        image.stack_rsp,
        0,
        .{ .cpu = options.cpu, .priority = options.priority, .joinable = true },
    ) orelse return error.TaskCreationFailed;

    publish(reservation, task, stack, options.name);
    return .{ .pid = reservation.pid, .generation = reservation.generation };
}

/// Wait for a process to exit. The status stays available until `reap`.
/// A zero timeout waits indefinitely; a finite timeout is measured in scheduler
/// ticks and checked between one-tick sleeps.
pub fn wait(handle: Handle, timeout_ms: u64) WaitResult {
    if (!initialized) return .{ .outcome = .invalid, .status = 0 };

    const start = sched.ticks();
    const timeout_ticks = if (timeout_ms == 0) 0 else @max(time.msToTicks(timeout_ms), 1);

    while (true) {
        const snapshot = lookup(handle) orelse return .{ .outcome = .invalid, .status = 0 };
        if (snapshot.state == .exited) {
            return .{ .outcome = .exited, .status = snapshot.exit_status };
        }
        if (snapshot.state != .running) return .{ .outcome = .invalid, .status = 0 };

        if (sched.taskStatus(snapshot.task_id)) |status| {
            if (status.state == .finished) {
                if (!markExited(handle, status.exit_status)) {
                    return .{ .outcome = .invalid, .status = 0 };
                }
                return .{ .outcome = .exited, .status = status.exit_status };
            }
        } else {
            return .{ .outcome = .invalid, .status = 0 };
        }

        if (timeout_ms != 0 and sched.ticks() - start >= timeout_ticks) {
            return .{ .outcome = .timeout, .status = 0 };
        }

        if (timeout_ms == 0) {
            sched.yield();
        } else {
            sched.sleepMs(1);
        }
    }
}

/// Release a process's task slot and kernel stack. The user address space was
/// already destroyed by the scheduler when the ring-3 task exited. A process
/// must have exited before it can be reaped.
pub fn reap(handle: Handle) ReapResult {
    if (!initialized) return .{ .outcome = .invalid, .status = 0 };

    const snapshot = lookup(handle) orelse return .{ .outcome = .invalid, .status = 0 };
    if (snapshot.state == .running) {
        const status = sched.taskStatus(snapshot.task_id) orelse {
            return .{ .outcome = .invalid, .status = 0 };
        };
        if (status.state != .finished) return .{ .outcome = .not_exited, .status = 0 };
        if (!markExited(handle, status.exit_status)) {
            return .{ .outcome = .invalid, .status = 0 };
        }
    }

    const guard = process_lock.acquire();
    if (!validLocked(handle)) {
        guard.release();
        return .{ .outcome = .invalid, .status = 0 };
    }

    const process = &processes[handle.pid - 1];
    if (process.state != .exited) {
        guard.release();
        return .{ .outcome = .invalid, .status = 0 };
    }

    process.state = .reaping;
    const task = process.task;
    const stack = process.kernel_stack;
    const status = process.exit_status;
    guard.release();

    if (task) |finished| sched.detach(finished);
    if (stack) |base| heap.free(base, kernel_stack_size);

    const final = process_lock.acquire();
    process.state = .unused;
    process.task = null;
    process.task_id = 0;
    process.kernel_stack = null;
    process.exit_status = 0;
    process.name_len = 0;
    _ = @atomicRmw(u64, &reaped_count, .Add, 1, .monotonic);
    final.release();

    return .{ .outcome = .reaped, .status = status };
}

pub fn stats() Stats {
    const guard = process_lock.acquire();
    defer guard.release();

    var slots: usize = 0;
    var live: usize = 0;
    var exited: usize = 0;
    for (&processes) |*process| {
        switch (process.state) {
            .unused => {},
            .starting, .reaping => slots += 1,
            .running => {
                slots += 1;
                live += 1;
            },
            .exited => {
                slots += 1;
                exited += 1;
            },
        }
    }

    return .{
        .slots = slots,
        .live = live,
        .exited = exited,
        .spawned = @atomicLoad(u64, &spawned_count, .monotonic),
        .reaped = @atomicLoad(u64, &reaped_count, .monotonic),
    };
}

fn reserve() SpawnError!Reservation {
    const guard = process_lock.acquire();
    defer guard.release();

    for (&processes, 0..) |*process, index| {
        if (process.state != .unused) continue;

        process.generation +%= 1;
        if (process.generation == 0) process.generation = 1;
        process.state = .starting;
        process.task = null;
        process.task_id = 0;
        process.exit_status = 0;
        process.kernel_stack = null;
        process.name_len = 0;

        return .{
            .index = index,
            .pid = @intCast(index + 1),
            .generation = process.generation,
        };
    }

    return error.TableFull;
}

fn releaseReservation(reservation: Reservation) void {
    const guard = process_lock.acquire();
    defer guard.release();

    const process = &processes[reservation.index];
    if (process.state == .starting and process.generation == reservation.generation) {
        process.state = .unused;
    }
}

fn publish(reservation: Reservation, task: *sched.Task, stack: [*]u8, name: []const u8) void {
    const guard = process_lock.acquire();
    defer guard.release();

    const process = &processes[reservation.index];
    process.state = .running;
    process.task = task;
    process.task_id = task.id;
    process.kernel_stack = stack;

    const length = @min(name.len, max_name - 1);
    @memcpy(process.name[0..length], name[0..length]);
    process.name[length] = 0;
    process.name_len = length;
    _ = @atomicRmw(u64, &spawned_count, .Add, 1, .monotonic);
}

fn lookup(handle: Handle) ?Snapshot {
    const guard = process_lock.acquire();
    defer guard.release();
    return lookupLocked(handle);
}

fn lookupLocked(handle: Handle) ?Snapshot {
    if (!validLocked(handle)) return null;
    const process = &processes[handle.pid - 1];
    return .{
        .state = process.state,
        .task_id = process.task_id,
        .exit_status = process.exit_status,
    };
}

fn validLocked(handle: Handle) bool {
    if (handle.pid == 0 or handle.pid > max_processes) return false;
    const process = &processes[handle.pid - 1];
    if (process.generation != handle.generation) return false;
    return process.state == .running or process.state == .exited;
}

fn markExited(handle: Handle, status: i32) bool {
    const guard = process_lock.acquire();
    defer guard.release();

    if (!validLocked(handle)) return false;
    const process = &processes[handle.pid - 1];
    if (process.state == .running) {
        process.state = .exited;
        process.exit_status = status;
    }
    return process.state == .exited;
}
