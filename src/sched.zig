//! Round-robin kernel task scheduler groundwork.
//!
//! `tasks[0]` is the boot context (the code that called `init`). Additional
//! tasks are created with their own kernel stacks and become runnable after
//! the next timer tick. `tick` is called from the IRQ0 path with the current
//! saved-register base; it returns the base the assembly epilogue should
//! resume, which may belong to a different task.
//!
//! The context switch saves every general-purpose register (see
//! `interrupts.S`). Floating-point/SIMD state is not switched yet, so tasks
//! must not rely on live XMM registers across a preemption in M2.

const gdt = @import("arch/x86_64/gdt.zig");

pub const max_tasks = 8;
pub const Entry = *const fn () callconv(.c) void;

pub const TaskState = enum {
    ready,
    running,
};

pub const Task = struct {
    name: []const u8,
    /// Saved-register base, consumed by the `isr_common` epilogue.
    rsp: u64,
    state: TaskState,
    ticks: u64,
    id: u32,
    index: usize,
};

pub const Stats = struct {
    ticks: u64,
    tasks: usize,
    current_id: u32,
    enabled: bool,
};

const saved_registers = 15;
// Long mode always pushes/returns a full 5-qword interrupt frame (RIP, CS,
// RFLAGS, RSP, SS), even for same-privilege interrupts.
const iret_frame_qwords = 5;
const initial_frame_qwords = saved_registers + 2 + iret_frame_qwords;

var tasks: [max_tasks]Task = undefined;
var task_count: usize = 1;
var current: ?*Task = null;
var tick_counter: u64 = 0;
var enabled = false;
var initialized = false;

/// Reset the scheduler and register the current execution context as task 0.
pub fn init() void {
    tasks[0] = .{
        .name = "boot",
        .rsp = 0,
        .state = .running,
        .ticks = 0,
        .id = 0,
        .index = 0,
    };
    task_count = 1;
    current = &tasks[0];
    tick_counter = 0;
    enabled = true;
    initialized = true;
}

/// Create a runnable kernel task. The caller owns `stack`; it must stay valid
/// for the lifetime of the task and should be at least a few KiB.
pub fn create(name: []const u8, entry: Entry, stack: []u8) ?*Task {
    if (!initialized or task_count >= max_tasks) return null;

    const rsp = initialFrame(stack, entry) orelse return null;
    const index = task_count;
    tasks[index] = .{
        .name = name,
        .rsp = rsp,
        .state = .ready,
        .ticks = 0,
        .id = @intCast(index),
        .index = index,
    };
    task_count += 1;
    return &tasks[index];
}

/// Timer tick entry point. `saved_rsp` is the base of the register block the
/// current interrupt frame pushed; the return value is the base to resume.
pub fn tick(saved_rsp: u64) u64 {
    const counter: *volatile u64 = &tick_counter;
    counter.* +%= 1;
    if (!initialized) return saved_rsp;

    const current_task = current orelse return saved_rsp;
    current_task.rsp = saved_rsp;
    current_task.ticks +%= 1;

    if (!enabled or task_count <= 1) return saved_rsp;

    const next = nextReady(current_task.index) orelse return saved_rsp;
    if (next == current_task) return saved_rsp;

    if (current_task.state == .running) current_task.state = .ready;
    next.state = .running;
    current = next;
    return next.rsp;
}

/// Stop switching tasks. The timer keeps counting so the running context can
/// finish its checks and shut the machine down.
pub fn stop() void {
    enabled = false;
}

pub fn ticks() u64 {
    const counter: *const volatile u64 = &tick_counter;
    return counter.*;
}

pub fn stats() Stats {
    return .{
        .ticks = ticks(),
        .tasks = task_count,
        .current_id = if (current) |task| task.id else 0,
        .enabled = enabled,
    };
}

fn nextReady(start: usize) ?*Task {
    var offset: usize = 1;
    while (offset <= task_count) : (offset += 1) {
        const index = (start + offset) % task_count;
        const task = &tasks[index];
        if (task.state == .ready) return task;
    }
    return null;
}

fn initialFrame(stack: []u8, entry: Entry) ?u64 {
    if (stack.len < 512) return null;

    const start = @intFromPtr(stack.ptr);
    const top = (start + stack.len) & ~@as(usize, 15);
    if (top < start + 256) return null;

    // A normal function entry sees RSP % 16 == 8 (as if a call had pushed a
    // return address). iretq will leave RSP here after dropping its frame.
    const entry_rsp = top - 8;
    const base = entry_rsp - initial_frame_qwords * @sizeOf(u64);
    const frame: [*]u64 = @ptrFromInt(base);
    @memset(frame[0..initial_frame_qwords], 0);

    // Layout consumed by isr_common: 15 saved registers, vector, error code,
    // then the full long-mode iret frame: RIP, CS, RFLAGS, RSP, SS.
    frame[saved_registers + 2] = @intCast(@intFromPtr(entry));
    frame[saved_registers + 3] = @as(u64, gdt.kernel_code_selector);
    frame[saved_registers + 4] = 0x202; // IF=1, reserved bit 1
    frame[saved_registers + 5] = entry_rsp;
    frame[saved_registers + 6] = @as(u64, gdt.kernel_data_selector);
    return base;
}
