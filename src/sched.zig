//! Round-robin kernel task scheduler: preemption, cooperative yield/exit,
//! timer-based sleep, an idle task, and finished-slot reuse.
//!
//! `tasks[0]` is the boot context and `tasks[1]` is the idle task. User tasks
//! use caller-owned kernel stacks. IRQ0 calls `tick`; `int $48` calls
//! `yieldCurrent`; `int $49` calls `exitCurrent`; `int $50` calls
//! `sleepCurrent`. All return the saved-register base that the assembly
//! epilogue should resume.
//!
//! Every GPR is saved (see `interrupts.S`). FPU/SIMD state is not switched
//! yet, so M4 tasks must not rely on live XMM registers across a preemption.

const gdt = @import("arch/x86_64/gdt.zig");
const sync = @import("sync.zig");

pub const max_tasks = 8;
pub const yield_vector: u8 = 48;
pub const exit_vector: u8 = 49;
pub const sleep_vector: u8 = 50;
pub const Entry = *const fn () callconv(.c) void;

pub const TaskState = enum { idle, ready, running, blocked, finished };

pub const Task = struct {
    name: []const u8,
    rsp: u64,
    state: TaskState,
    ticks: u64,
    wake_tick: u64,
    id: u32,
    index: usize,
};

pub const Stats = struct {
    ticks: u64,
    tasks: usize,
    finished: u64,
    current_id: u32,
    enabled: bool,
};

const saved_registers = 15;
const iret_frame_qwords = 5;
const initial_frame_qwords = saved_registers + 2 + iret_frame_qwords;
const idle_index: usize = 1;

var tasks: [max_tasks]Task = undefined;
var task_count: usize = 0;
var current: ?*Task = null;
var tick_counter: u64 = 0;
var finished_counter: u64 = 0;
var sleep_request: u64 = 0;
var next_id: u32 = 0;
var enabled = false;
var initialized = false;

var idle_stack: [8 * 1024]u8 align(16) = undefined;
var task_lock: sync.IrqLock = .{};

pub fn init() void {
    task_lock.acquire();
    defer task_lock.release();

    tasks[0] = .{ .name = "boot", .rsp = 0, .state = .running, .ticks = 0, .wake_tick = 0, .id = 0, .index = 0 };
    const idle_rsp = initialFrame(idle_stack[0..], idleEntry) orelse unreachable;
    tasks[idle_index] = .{ .name = "idle", .rsp = idle_rsp, .state = .idle, .ticks = 0, .wake_tick = 0, .id = 1, .index = idle_index };
    task_count = idle_index + 1;
    current = &tasks[0];
    tick_counter = 0;
    finished_counter = 0;
    sleep_request = 0;
    next_id = 2;
    enabled = true;
    initialized = true;
}

pub fn create(name: []const u8, entry: Entry, stack: []u8) ?*Task {
    if (!initialized) return null;

    task_lock.acquire();
    defer task_lock.release();

    const index = findSlot() orelse return null;
    const rsp = initialFrame(stack, entry) orelse return null;
    const id = next_id;
    next_id +%= 1;

    tasks[index] = .{
        .name = name,
        .rsp = rsp,
        .state = .finished,
        .ticks = 0,
        .wake_tick = 0,
        .id = id,
        .index = index,
    };
    if (index == task_count) task_count += 1;
    tasks[index].state = .ready;
    return &tasks[index];
}

pub fn tick(saved_rsp: u64) u64 {
    const counter: *volatile u64 = &tick_counter;
    counter.* +%= 1;
    if (!initialized) return saved_rsp;

    wakeBlocked();

    const current_task = current orelse return saved_rsp;
    current_task.rsp = saved_rsp;
    current_task.ticks +%= 1;
    if (!enabled) return saved_rsp;

    const next = nextOtherReady(current_task.index) orelse return saved_rsp;
    park(current_task);
    next.state = .running;
    current = next;
    return next.rsp;
}

pub fn yieldCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;
    const current_task = current orelse return saved_rsp;
    current_task.rsp = saved_rsp;

    const next = nextOtherReady(current_task.index) orelse return saved_rsp;
    park(current_task);
    next.state = .running;
    current = next;
    return next.rsp;
}

pub fn exitCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;
    const current_task = current orelse return saved_rsp;
    current_task.rsp = saved_rsp;
    current_task.state = .finished;
    const counter: *volatile u64 = &finished_counter;
    counter.* +%= 1;

    if (nextOtherReady(current_task.index)) |next| {
        next.state = .running;
        current = next;
        return next.rsp;
    }

    if (current_task.index == idle_index) haltForever();
    const idle = &tasks[idle_index];
    idle.state = .running;
    current = idle;
    return idle.rsp;
}

pub fn sleep(duration: u64) void {
    if (duration == 0) return;
    const flags = sync.irqSave();
    asm volatile ("cli");
    sleep_request = duration;
    asm volatile ("int $50" ::: .{ .memory = true });
    sync.irqRestore(flags);
}

pub fn sleepCurrent(saved_rsp: u64) u64 {
    if (!initialized) return saved_rsp;
    if (!enabled) {
        sleep_request = 0;
        return saved_rsp;
    }
    const current_task = current orelse return saved_rsp;
    if (current_task.index == idle_index) return saved_rsp;

    const duration = sleep_request;
    sleep_request = 0;
    if (duration == 0) return saved_rsp;

    current_task.rsp = saved_rsp;
    current_task.state = .blocked;
    current_task.wake_tick = tick_counter +% duration;

    if (nextOtherReady(current_task.index)) |next| {
        next.state = .running;
        current = next;
        return next.rsp;
    }
    const idle = &tasks[idle_index];
    idle.state = .running;
    current = idle;
    return idle.rsp;
}

pub fn yield() void {
    asm volatile ("int $48" ::: .{ .memory = true });
}

pub fn exit() noreturn {
    asm volatile ("int $49" ::: .{ .memory = true });
    haltForever();
}

pub fn stop() void {
    task_lock.acquire();
    defer task_lock.release();
    enabled = false;
}

pub fn ticks() u64 {
    const counter: *const volatile u64 = &tick_counter;
    return counter.*;
}

pub fn finishedCount() u64 {
    const counter: *const volatile u64 = &finished_counter;
    return counter.*;
}

pub fn stats() Stats {
    return .{
        .ticks = ticks(),
        .tasks = task_count,
        .finished = finishedCount(),
        .current_id = if (current) |task| task.id else 0,
        .enabled = enabled,
    };
}

fn wakeBlocked() void {
    var index: usize = 0;
    while (index < task_count) : (index += 1) {
        if (index == idle_index) continue;
        const task = &tasks[index];
        if (task.state == .blocked and tick_counter >= task.wake_tick) {
            task.state = .ready;
        }
    }
}

fn nextOtherReady(start: usize) ?*Task {
    var offset: usize = 1;
    while (offset < task_count) : (offset += 1) {
        const index = (start + offset) % task_count;
        const task = &tasks[index];
        if (task.state == .ready) return task;
    }
    return null;
}

fn findSlot() ?usize {
    var index: usize = idle_index + 1;
    while (index < task_count) : (index += 1) {
        if (tasks[index].state == .finished) return index;
    }
    if (task_count < max_tasks) return task_count;
    return null;
}

fn park(task: *Task) void {
    if (task.state != .running) return;
    task.state = if (task.index == idle_index) .idle else .ready;
}

fn idleEntry() callconv(.c) void {
    while (true) {
        asm volatile ("sti; hlt");
    }
}

fn haltForever() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
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

    frame[saved_registers + 2] = @intCast(@intFromPtr(entry));
    frame[saved_registers + 3] = @as(u64, gdt.kernel_code_selector);
    frame[saved_registers + 4] = 0x202;
    frame[saved_registers + 5] = entry_rsp;
    frame[saved_registers + 6] = @as(u64, gdt.kernel_data_selector);
    return base;
}
