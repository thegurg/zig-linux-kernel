//! SMP bring-up through Limine's MP protocol.
//!
//! Limine bootstraps and parks every application processor when the MP request
//! is present. `init` records the per-CPU descriptors; `start` assigns each AP
//! a private stack and a GDT/TSS slot, then atomically writes `goto_address` to
//! release it. The AP switches to our page tables, installs its per-CPU state,
//! initialises its local APIC, and enters the scheduler idle loop.
//!
//! Task execution is per-CPU: the scheduler pins tasks to a CPU and uses LAPIC
//! IPIs for remote wakeups and TLB shootdowns. The timer remains a BSP PIT
//! interrupt, but its timeout scan wakes sleepers on every CPU.

const std = @import("std");
const limine = @import("limine.zig");
const vmm = @import("memory/vmm.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const sync = @import("sync.zig");
const sched = @import("sched.zig");

pub const max_cpus = gdt.max_cpus;
const ap_stack_size = 16 * 1024;
const stress_iterations: u64 = 100_000;
const max_start_spin: u64 = 50_000_000;
const max_test_spin: u64 = 100_000_000;

/// Per-AP descriptor passed to the assembly entry stub. `stack_top` must stay
/// at offset 0 because `smp_entry.S` loads it before any Zig code runs.
pub const ApContext = extern struct {
    stack_top: u64 = 0,
    index: u32 = 0,
    cpu_index: u32 = 0,
    lapic_id: u32 = 0,
    gdt_cpu: u32 = 0,
    info: u64 = 0,
};

comptime {
    if (@offsetOf(ApContext, "stack_top") != 0) @compileError("ApContext.stack_top must be at offset 0");
}

pub const Stats = struct {
    cpus: u32 = 0,
    aps: u32 = 0,
    bsp_lapic_id: u32 = 0,
    x2apic: bool = false,
    started: bool = false,
};

pub const TestResult = struct {
    cpus: u32,
    aps: u32,
    online: u32,
    counter: u64,
    expected: u64,
    overlap: u64,
};

pub const InitError = error{
    NoMpResponse,
    TooManyCpus,
};

var ap_stacks: [max_cpus][ap_stack_size]u8 align(16) = undefined;
var ap_task_stacks: [max_cpus][ap_stack_size]u8 align(16) = undefined;
var ap_contexts: [max_cpus]ApContext = @splat(.{});

var stats: Stats = .{};
var initialized = false;
var started = false;

var online_count: u64 = 0;
var parked_count: u64 = 0;
var done_count: u64 = 0;

var test_counter: u64 = 0;
var test_inside: u64 = 0;
var test_overlap: u64 = 0;
var test_lock: sync.IrqSpinLock = .{};

var xwake_queue: sched.WaitQueue = .{};
var xwake_woken: u64 = 0;
var xwake_stack: [ap_stack_size]u8 align(16) = undefined;

const ap_exc_pattern = [16]u8{
    0x31, 0x42, 0x53, 0x64, 0x75, 0x86, 0x97, 0xa8,
    0xb9, 0xca, 0xdb, 0xec, 0xfd, 0x0e, 0x1f, 0x20,
};
var ap_exc_result: [16]u8 align(16) = @splat(0);
var ap_exc_done: u64 = 0;
var ap_exc_stack: [ap_stack_size]u8 align(16) = undefined;

/// Physical PML4 used by the AP entry stub after it leaves Limine's page
/// tables. Written once during `init`.
pub export var ap_kernel_cr3: u64 = 0;

extern fn ap_entry() callconv(.c) noreturn;

pub fn init() InitError!void {
    const response = limine.mp() orelse return error.NoMpResponse;
    if (response.cpu_count > max_cpus) return error.TooManyCpus;

    ap_kernel_cr3 = vmm.currentPml4();
    stats = .{
        .cpus = @intCast(response.cpu_count),
        .bsp_lapic_id = response.bsp_lapic_id,
        .x2apic = (response.flags & limine.mp_x2apic) != 0,
    };

    var ap_index: u32 = 0;
    var index: usize = 0;
    while (index < response.cpu_count) : (index += 1) {
        const info = response.cpus[index] orelse continue;
        if (info.lapic_id == response.bsp_lapic_id) continue;

        const ctx = &ap_contexts[ap_index];
        ctx.* = .{
            .stack_top = @intFromPtr(&ap_stacks[ap_index]) + ap_stack_size,
            .index = ap_index,
            .cpu_index = ap_index + 1,
            .lapic_id = info.lapic_id,
            .gdt_cpu = ap_index + 1,
            .info = @intFromPtr(info),
        };
        info.extra_argument = @intFromPtr(ctx);
        ap_index += 1;
    }
    stats.aps = ap_index;
    stats.x2apic = lapic.isX2apic();
    initialized = true;
}

pub fn getStats() Stats {
    return stats;
}

pub fn onlineCount() u32 {
    return @intCast(@atomicLoad(u64, &online_count, .acquire));
}

pub fn parkedCount() u32 {
    return @intCast(@atomicLoad(u64, &parked_count, .acquire));
}

/// Release every parked AP. Each AP initialises its scheduler state and enters
/// the idle loop; it no longer returns to the bootloader park loop.
pub fn start() bool {
    if (!initialized or started) return false;
    started = true;
    stats.started = true;
    online_count = 0;
    parked_count = 0;

    const entry = @intFromPtr(&ap_entry);
    var index: usize = 0;
    while (index < stats.aps) : (index += 1) {
        const info: *limine.MpInfo = @ptrFromInt(ap_contexts[index].info);
        info.extra_argument = @intFromPtr(&ap_contexts[index]);
        @atomicStore(u64, &info.goto_address, entry, .seq_cst);
    }
    return true;
}

/// Wait until every released AP has installed its scheduler state.
pub fn waitOnline() bool {
    var spin: u64 = 0;
    while (@atomicLoad(u64, &online_count, .acquire) < stats.aps) {
        if (spin >= max_start_spin) return false;
        spin += 1;
        asm volatile ("pause");
    }
    return true;
}

/// Stress test: every AP and the BSP hammer a shared counter under an IRQ-safe
/// spinlock. A correct lock keeps the critical-section depth at exactly one.
pub fn runTest() ?TestResult {
    if (!initialized or !started) return null;

    test_counter = 0;
    test_inside = 0;
    test_overlap = 0;
    done_count = 0;
    const finished_base = sched.finishedCount();

    var ap: usize = 0;
    while (ap < stats.aps) : (ap += 1) {
        const cpu_index: u32 = @intCast(ap + 1);
        if (sched.createOn(cpu_index, "smp-worker", stressWorker, ap_task_stacks[ap][0..]) == null) {
            return null;
        }
    }

    runWorkload();

    const expected_finished = finished_base + @as(u64, stats.aps);
    var spin: u64 = 0;
    while (@atomicLoad(u64, &done_count, .acquire) < stats.aps or
        sched.finishedCount() < expected_finished)
    {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    return .{
        .cpus = stats.cpus,
        .aps = stats.aps,
        .online = onlineCount(),
        .counter = @atomicLoad(u64, &test_counter, .acquire),
        .expected = stress_iterations * (@as(u64, stats.aps) + 1),
        .overlap = @atomicLoad(u64, &test_overlap, .acquire),
    };
}

fn stressWorker() callconv(.c) void {
    runWorkload();
    _ = @atomicRmw(u64, &done_count, .Add, 1, .seq_cst);
    sched.exit();
}

fn runWorkload() void {
    var iteration: u64 = 0;
    while (iteration < stress_iterations) : (iteration += 1) {
        const guard = test_lock.acquire();
        _ = @atomicRmw(u64, &test_inside, .Add, 1, .seq_cst);
        if (@atomicLoad(u64, &test_inside, .seq_cst) != 1) {
            _ = @atomicRmw(u64, &test_overlap, .Add, 1, .seq_cst);
        }
        _ = @atomicRmw(u64, &test_counter, .Add, 1, .seq_cst);
        _ = @atomicRmw(u64, &test_inside, .Sub, 1, .seq_cst);
        guard.release();
    }
}

/// Block a task on an AP, then wake it from the BSP. The wakeup must travel as
/// a reschedule IPI and the task must run to completion on its original CPU.
pub fn runCrossCpuWakeTest() ?bool {
    if (!initialized or !started) return null;
    if (stats.aps == 0) return true;

    xwake_woken = 0;
    const finished_base = sched.finishedCount();
    if (sched.createOn(1, "cross-cpu-wake", crossCpuWorker, xwake_stack[0..]) == null) {
        return null;
    }

    var spin: u64 = 0;
    while (!xwake_queue.wakeOne()) {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    while (@atomicLoad(u64, &xwake_woken, .acquire) == 0 or
        sched.finishedCount() < finished_base + 1)
    {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    return @atomicLoad(u64, &xwake_woken, .acquire) == 1;
}

fn crossCpuWorker() callconv(.c) void {
    xwake_queue.wait();
    _ = @atomicRmw(u64, &xwake_woken, .Add, 1, .seq_cst);
    sched.exit();
}

/// Run an INT3 on an AP task and verify that the AP's per-CPU FXSAVE area
/// restored the SIMD register across exception entry and exit.
pub fn runApExceptionTest() ?bool {
    if (!initialized or !started) return null;
    if (stats.aps == 0) return true;

    ap_exc_done = 0;
    ap_exc_result = @splat(0);
    const finished_base = sched.finishedCount();
    if (sched.createOn(1, "ap-exception", apExceptionWorker, ap_exc_stack[0..]) == null) {
        return null;
    }

    var spin: u64 = 0;
    while (@atomicLoad(u64, &ap_exc_done, .acquire) == 0 or
        sched.finishedCount() < finished_base + 1)
    {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    return @atomicLoad(u64, &ap_exc_done, .acquire) == 1 and
        std.mem.eql(u8, &ap_exc_result, &ap_exc_pattern);
}

fn apExceptionWorker() callconv(.c) void {
    asm volatile (
        \\movdqu (%[pattern]), %%xmm5
        \\int3
        \\movdqu %%xmm5, (%[result])
        :
        : [pattern] "r" (&ap_exc_pattern),
          [result] "r" (&ap_exc_result),
        : .{ .xmm5 = true, .memory = true });
    _ = @atomicRmw(u64, &ap_exc_done, .Add, 1, .seq_cst);
    sched.exit();
}

/// Zig side of the AP entry path. Called by `ap_entry` with a private
/// descriptor and this CPU's `limine_mp_info`.
export fn ap_main(ctx: *ApContext, info: *limine.MpInfo) callconv(.c) noreturn {
    _ = info;

    // SSE and CR0.WP were enabled by `ap_entry` before this Zig code started.
    gdt.setKernelStack(ctx.gdt_cpu, ctx.stack_top);
    gdt.load(ctx.gdt_cpu);
    idt.load();
    // Install GS/`%gs:0` before anything that can fault, including LAPIC
    // programming. `cpu.initPerCpu` replaces the scratch FPU area with the
    // boot area, and `sched.initCpu` later points it at the idle task.
    cpu.initPerCpu(ctx.cpu_index, ctx.lapic_id);

    const apic_ready = lapic.init();
    if (!apic_ready or !sched.initCpu(ctx.cpu_index, ctx.lapic_id)) park();

    _ = @atomicRmw(u64, &online_count, .Add, 1, .seq_cst);
    sched.enterScheduler();
}

fn park() noreturn {
    _ = @atomicRmw(u64, &parked_count, .Add, 1, .seq_cst);
    while (true) {
        asm volatile ("cli; hlt");
    }
}
