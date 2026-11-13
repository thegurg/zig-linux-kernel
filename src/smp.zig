//! SMP bring-up through Limine's MP protocol.
//!
//! Limine bootstraps and parks every application processor when the MP request
//! is present. `init` records the per-CPU descriptors; `start` assigns each AP
//! a private stack and a GDT/TSS slot, then atomically writes `goto_address` to
//! release it. The AP switches to our page tables, installs its per-CPU state,
//! initialises its local APIC, and enters the scheduler idle loop.
//!
//! Task execution is per-CPU: the scheduler pins tasks to a CPU and uses LAPIC
//! IPIs for remote wakeups and TLB shootdowns. CPU 0 keeps the PIT tick; each AP
//! starts its own periodic LAPIC timer during bring-up, so AP tasks are
//! preempted and timed sleepers wake locally.

const std = @import("std");
const limine = @import("limine.zig");
const vmm = @import("memory/vmm.zig");
const pmm = @import("memory/pmm.zig");
const heap = @import("memory/heap.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const sync = @import("sync.zig");
const sched = @import("sched.zig");

pub const max_cpus = gdt.max_cpus;
const ap_stack_size = 16 * 1024;
const stress_iterations: u64 = 100_000;
const heap_stress_iterations: u64 = 1_000;
const tlb_stress_iterations: u64 = 50;
const timer_sleep_ticks: u64 = 3;
const preempt_iterations: u64 = 200_000_000;
const max_start_spin: u64 = 50_000_000;
const max_test_spin: u64 = 100_000_000;
const tlb_stress_base: u64 = 0xffff_ffff_c200_0000;
const irq_off_test_virt: u64 = 0xffff_ffff_c100_0000;

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

var heap_done: u64 = 0;
var heap_errors: u64 = 0;
var heap_test_stacks: [max_cpus][ap_stack_size]u8 align(16) = undefined;

var irq_off_active: u64 = 0;
var irq_off_done: u64 = 0;
var irq_off_stack: [ap_stack_size]u8 align(16) = undefined;

var tlb_stress_done: u64 = 0;
var tlb_stress_errors: u64 = 0;
var tlb_stress_stacks: [max_cpus][ap_stack_size]u8 align(16) = undefined;

var timer_sleep_done: u64 = 0;
var timer_sleep_by_cpu: [max_cpus]u64 = @splat(0);
var timer_sleep_stacks: [max_cpus][ap_stack_size]u8 align(16) = undefined;

var preempt_a: u64 = 0;
var preempt_b: u64 = 0;
var preempt_a_observed: u64 = 0;
var preempt_b_observed: u64 = 0;
var preempt_stacks: [2][ap_stack_size]u8 align(16) = undefined;

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

pub const ConcurrentHeapResult = struct {
    allocs: u64,
    errors: u64,
};

/// Allocate and free blocks concurrently on every CPU. The heap lock must keep
/// the free list consistent under contention.
pub fn runConcurrentHeapTest() ?ConcurrentHeapResult {
    if (!initialized or !started) return null;

    heap_done = 0;
    heap_errors = 0;
    const finished_base = sched.finishedCount();

    var ap: usize = 0;
    while (ap < stats.aps) : (ap += 1) {
        const cpu_index: u32 = @intCast(ap + 1);
        if (sched.createOn(cpu_index, "heap-worker", heapWorker, heap_test_stacks[ap][0..]) == null) {
            return null;
        }
    }

    heapWorkload();
    _ = @atomicRmw(u64, &heap_done, .Add, 1, .seq_cst);

    const expected_finished = finished_base + @as(u64, stats.aps);
    var spin: u64 = 0;
    while (@atomicLoad(u64, &heap_done, .acquire) < @as(u64, stats.aps) + 1 or
        sched.finishedCount() < expected_finished)
    {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    return .{
        .allocs = heap_stress_iterations * (@as(u64, stats.aps) + 1),
        .errors = @atomicLoad(u64, &heap_errors, .acquire),
    };
}

fn heapWorker() callconv(.c) void {
    heapWorkload();
    _ = @atomicRmw(u64, &heap_done, .Add, 1, .seq_cst);
    sched.exit();
}

fn heapWorkload() void {
    const sizes = [_]usize{ 24, 64, 257, 1024, 4096 };
    var iteration: u64 = 0;
    while (iteration < heap_stress_iterations) : (iteration += 1) {
        const size = sizes[@intCast(iteration % sizes.len)];
        const pattern: u8 = @truncate(0x5a +% iteration);
        const ptr = heap.alloc(size, 16) orelse {
            _ = @atomicRmw(u64, &heap_errors, .Add, 1, .seq_cst);
            return;
        };
        @memset(ptr[0..size], pattern);
        var index: usize = 0;
        while (index < size) : (index += 1) {
            if (ptr[index] != pattern) {
                _ = @atomicRmw(u64, &heap_errors, .Add, 1, .seq_cst);
                break;
            }
        }
        heap.free(ptr, size);
    }
}

/// Verify that a shootdown targeting a CPU with interrupts disabled waits for
/// the pending IPI instead of timing out. The AP worker keeps interrupts off
/// until it observes the shootdown request counter change.
pub fn runIrqOffShootdownTest() ?bool {
    if (!initialized or !started) return null;
    if (stats.aps == 0) return true;

    irq_off_active = 0;
    irq_off_done = 0;
    const finished_base = sched.finishedCount();

    if (sched.createOn(1, "irq-off-tlb", irqOffWorker, irq_off_stack[0..]) == null) {
        return null;
    }

    var spin: u64 = 0;
    while (@atomicLoad(u64, &irq_off_active, .acquire) == 0) {
        if (spin >= max_test_spin) return false;
        spin += 1;
        asm volatile ("pause");
    }

    const phys = pmm.allocPage() orelse return null;
    defer _ = pmm.freePage(phys);

    if (vmm.translate(irq_off_test_virt) != null) return false;
    if (!vmm.mapPage(irq_off_test_virt, phys, vmm.kernel_rw)) return false;
    if (!vmm.unmapPage(irq_off_test_virt)) return false;

    while (@atomicLoad(u64, &irq_off_done, .acquire) == 0 or
        sched.finishedCount() < finished_base + 1)
    {
        if (spin >= max_test_spin) return false;
        spin += 1;
        asm volatile ("pause");
    }

    return @atomicLoad(u64, &irq_off_done, .acquire) == 1;
}

fn irqOffWorker() callconv(.c) void {
    const before = sched.tlbShootdownCount();
    asm volatile ("cli" ::: .{ .memory = true });
    @atomicStore(u64, &irq_off_active, 1, .release);

    var spin: u64 = 0;
    while (sched.tlbShootdownCount() == before) {
        if (spin >= max_test_spin) break;
        spin += 1;
        asm volatile ("pause");
    }

    // The shooter has published its request. Keep interrupts disabled briefly
    // so the IPI is pending when it reaches this CPU.
    var tail: u64 = 0;
    while (tail < 1000) : (tail += 1) {
        asm volatile ("pause");
    }

    asm volatile ("sti" ::: .{ .memory = true });
    @atomicStore(u64, &irq_off_active, 0, .release);

    if (sched.tlbShootdownCount() != before) {
        _ = @atomicRmw(u64, &irq_off_done, .Add, 1, .seq_cst);
    }
    sched.exit();
}

pub const ConcurrentTlbResult = struct {
    shootdowns: u64,
    errors: u64,
};

/// Map and unmap a private page on every AP concurrently. Several CPUs issue
/// shootdowns at the same time, which exercises the per-shooter mailboxes.
pub fn runConcurrentShootdownTest() ?ConcurrentTlbResult {
    if (!initialized or !started) return null;
    if (stats.aps == 0) return .{ .shootdowns = 0, .errors = 0 };

    tlb_stress_done = 0;
    tlb_stress_errors = 0;
    const before = sched.tlbShootdownCount();
    const finished_base = sched.finishedCount();

    var ap: usize = 0;
    while (ap < stats.aps) : (ap += 1) {
        const cpu_index: u32 = @intCast(ap + 1);
        if (sched.createOn(cpu_index, "tlb-worker", tlbStressWorker, tlb_stress_stacks[ap][0..]) == null) {
            return null;
        }
    }

    const expected_finished = finished_base + @as(u64, stats.aps);
    var spin: u64 = 0;
    while (@atomicLoad(u64, &tlb_stress_done, .acquire) < stats.aps or
        sched.finishedCount() < expected_finished)
    {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    return .{
        .shootdowns = sched.tlbShootdownCount() - before,
        .errors = @atomicLoad(u64, &tlb_stress_errors, .acquire),
    };
}

fn tlbStressWorker() callconv(.c) void {
    const page_size: usize = @intCast(vmm.page_size);
    const me: u64 = @intCast(cpu.currentIndex());
    const virt = tlb_stress_base + me * vmm.page_size;

    var iteration: u64 = 0;
    while (iteration < tlb_stress_iterations) : (iteration += 1) {
        const phys = pmm.allocPage() orelse {
            _ = @atomicRmw(u64, &tlb_stress_errors, .Add, 1, .seq_cst);
            break;
        };
        if (!vmm.mapPage(virt, phys, vmm.kernel_rw)) {
            _ = pmm.freePage(phys);
            _ = @atomicRmw(u64, &tlb_stress_errors, .Add, 1, .seq_cst);
            break;
        }

        const ptr: [*]u8 = @ptrFromInt(virt);
        @memset(ptr[0..page_size], @truncate(0x33 +% iteration));

        if (!vmm.unmapPage(virt)) {
            _ = @atomicRmw(u64, &tlb_stress_errors, .Add, 1, .seq_cst);
        }
        _ = pmm.freePage(phys);
    }

    _ = @atomicRmw(u64, &tlb_stress_done, .Add, 1, .seq_cst);
    sched.exit();
}

pub const TimerTestResult = struct {
    ticks: u64,
    sleepers: u64,
    preempted: bool,
    preempt_a: u64,
    preempt_b: u64,
    preempt_ticks: u64,
};

/// Verify that each AP's LAPIC timer advances its own tick counter and wakes a
/// local timed sleeper, then prove timer-driven preemption with two CPU-bound
/// tasks pinned to CPU 1. Both counters must be observed while the other task is
/// still running; without preemption the first task spins to its bound alone.
pub fn runTimerTest() ?TimerTestResult {
    if (!initialized or !started) return null;
    if (stats.aps != 0 and lapic.timerCountPerTick() == 0) return null;

    timer_sleep_done = 0;
    timer_sleep_by_cpu = @splat(0);
    const sleep_finished_base = sched.finishedCount();

    var ap: usize = 0;
    while (ap < stats.aps) : (ap += 1) {
        const cpu_index: u32 = @intCast(ap + 1);
        if (sched.createOn(cpu_index, "timer-sleeper", apSleeperWorker, timer_sleep_stacks[ap][0..]) == null) {
            return null;
        }
    }

    const expected_sleepers = @as(u64, stats.aps);
    var spin: u64 = 0;
    while (@atomicLoad(u64, &timer_sleep_done, .acquire) < expected_sleepers or
        sched.finishedCount() < sleep_finished_base + expected_sleepers)
    {
        if (spin >= max_test_spin) return null;
        spin += 1;
        asm volatile ("pause");
    }

    var total_ticks: u64 = 0;
    var index: usize = 0;
    while (index < stats.aps) : (index += 1) {
        total_ticks += timer_sleep_by_cpu[index + 1];
    }

    var preempted = true;
    var preempt_count_a: u64 = 0;
    var preempt_count_b: u64 = 0;
    var preempt_ticks: u64 = 0;
    if (stats.aps != 0) {
        preempt_a = 0;
        preempt_b = 0;
        preempt_a_observed = 0;
        preempt_b_observed = 0;
        const preempt_finished_base = sched.finishedCount();
        const before_ticks = sched.ticksOn(1);

        if (sched.createOn(1, "preempt-a", preemptWorkerA, preempt_stacks[0][0..]) == null) return null;
        if (sched.createOn(1, "preempt-b", preemptWorkerB, preempt_stacks[1][0..]) == null) return null;

        spin = 0;
        while (sched.finishedCount() < preempt_finished_base + 2) {
            if (spin >= max_test_spin) return null;
            spin += 1;
            asm volatile ("pause");
        }

        preempt_count_a = @atomicLoad(u64, &preempt_a, .acquire);
        preempt_count_b = @atomicLoad(u64, &preempt_b, .acquire);
        preempt_ticks = sched.ticksOn(1) - before_ticks;
        preempted = @atomicLoad(u64, &preempt_a_observed, .acquire) != 0 and
            @atomicLoad(u64, &preempt_b_observed, .acquire) != 0 and
            preempt_ticks > 0;
    }

    return .{
        .ticks = total_ticks,
        .sleepers = expected_sleepers,
        .preempted = preempted,
        .preempt_a = preempt_count_a,
        .preempt_b = preempt_count_b,
        .preempt_ticks = preempt_ticks,
    };
}

fn apSleeperWorker() callconv(.c) void {
    const index = cpu.currentIndex();
    const before = sched.ticksOn(index);
    sched.sleep(timer_sleep_ticks);
    timer_sleep_by_cpu[index] = sched.ticksOn(index) -% before;
    _ = @atomicRmw(u64, &timer_sleep_done, .Add, 1, .seq_cst);
    sched.exit();
}

fn preemptWorkerA() callconv(.c) void {
    preemptWorkload(&preempt_a, &preempt_b, &preempt_a_observed);
}

fn preemptWorkerB() callconv(.c) void {
    preemptWorkload(&preempt_b, &preempt_a, &preempt_b_observed);
}

fn preemptWorkload(own: *u64, other: *u64, observed: *u64) void {
    var iteration: u64 = 0;
    while (iteration < preempt_iterations) : (iteration += 1) {
        _ = @atomicRmw(u64, own, .Add, 1, .monotonic);
        if (@atomicLoad(u64, other, .acquire) != 0) {
            @atomicStore(u64, observed, 1, .release);
            break;
        }
    }
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

    // Calibration happened on the BSP before release. The timer stays pending
    // until `enterScheduler` resumes the idle frame with interrupts enabled.
    if (lapic.timerCountPerTick() != 0) {
        _ = lapic.startPeriodicTimer(sched.timer_vector);
    }

    _ = @atomicRmw(u64, &online_count, .Add, 1, .seq_cst);
    sched.enterScheduler();
}

fn park() noreturn {
    _ = @atomicRmw(u64, &parked_count, .Add, 1, .seq_cst);
    while (true) {
        asm volatile ("cli; hlt");
    }
}
