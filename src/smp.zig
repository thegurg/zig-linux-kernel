//! SMP bring-up through Limine's MP protocol.
//!
//! Limine bootstraps and parks every application processor when the MP request
//! is present. `init` records the per-CPU descriptors and publishes nothing
//! yet; `start` assigns each AP a private stack and a GDT/TSS slot, then
//! atomically writes `goto_address` to release it. The AP switches from
//! Limine's page tables to ours, loads the shared GDT/IDT and either parks or
//! runs the SMP stress workload.
//!
//! Scheduling still runs only on the bootstrap processor. The APs exercise the
//! atomic spinlock and then halt; per-CPU scheduling and SMP-aware wait queues
//! are a later milestone.

const std = @import("std");
const limine = @import("limine.zig");
const vmm = @import("memory/vmm.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const sync = @import("sync.zig");

pub const max_cpus = gdt.max_cpus;
const ap_stack_size = 16 * 1024;
const stress_iterations: u64 = 100_000;
const max_start_spin: u64 = 50_000_000;

pub const ApContext = struct {
    stack_top: u64 = 0,
    index: u32 = 0,
    lapic_id: u32 = 0,
    gdt_cpu: u32 = 0,
    info: u64 = 0,
    online: u64 = 0,
    done: u64 = 0,
};

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
var ap_contexts: [max_cpus]ApContext = @splat(.{});

var stats: Stats = .{};
var initialized = false;
var started = false;
var test_mode = false;

var online_count: u64 = 0;
var parked_count: u64 = 0;
var done_count: u64 = 0;

var test_go: u64 = 0;
var test_counter: u64 = 0;
var test_inside: u64 = 0;
var test_overlap: u64 = 0;
var test_lock: sync.SpinLock = .{};

/// Physical PML4 used by the AP entry stub after it leaves Limine's page
/// tables. Written once during `init`.
pub export var ap_kernel_cr3: u64 = 0;

/// AP entry point implemented in `smp_entry.S`. The stub receives a
/// `limine_mp_info` in RDI and tail-calls `ap_main`.
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
            .lapic_id = info.lapic_id,
            .gdt_cpu = ap_index + 1,
            .info = @intFromPtr(info),
        };
        info.extra_argument = @intFromPtr(ctx);
        ap_index += 1;
    }
    stats.aps = ap_index;
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

/// Release every parked AP. `test` selects whether the APs wait for the stress
/// workload or immediately park in `hlt`.
pub fn start(run_test: bool) bool {
    if (!initialized or started) return false;
    test_mode = run_test;
    started = true;
    stats.started = true;
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

/// Wait until every released AP has reached `ap_main`.
pub fn waitOnline() bool {
    return waitCounter(&online_count, stats.aps);
}

/// Wait until every released AP has entered its final `hlt` loop.
pub fn waitParked() bool {
    return waitCounter(&parked_count, stats.aps);
}

fn waitCounter(counter: *u64, target: u32) bool {
    var spin: u64 = 0;
    while (@atomicLoad(u64, counter, .acquire) < target) {
        if (spin >= max_start_spin) return false;
        spin += 1;
        asm volatile ("pause");
    }
    return true;
}

/// Run the SMP stress test: every AP and the BSP hammer a shared counter under
/// a spinlock. A correct lock keeps the critical-section depth at exactly one
/// and produces the expected total.
pub fn runTest() ?TestResult {
    if (!initialized or started) return null;

    test_go = 0;
    test_counter = 0;
    test_inside = 0;
    test_overlap = 0;
    online_count = 0;
    done_count = 0;

    if (!start(true)) return null;
    if (!waitOnline()) return null;

    @atomicStore(u64, &test_go, 1, .release);
    runWorkload();

    if (!waitCounter(&done_count, stats.aps)) return null;

    return .{
        .cpus = stats.cpus,
        .aps = stats.aps,
        .online = onlineCount(),
        .counter = @atomicLoad(u64, &test_counter, .acquire),
        .expected = stress_iterations * (@as(u64, stats.aps) + 1),
        .overlap = @atomicLoad(u64, &test_overlap, .acquire),
    };
}

fn runWorkload() void {
    var iteration: u64 = 0;
    while (iteration < stress_iterations) : (iteration += 1) {
        test_lock.acquire();
        _ = @atomicRmw(u64, &test_inside, .Add, 1, .seq_cst);
        if (@atomicLoad(u64, &test_inside, .seq_cst) != 1) {
            _ = @atomicRmw(u64, &test_overlap, .Add, 1, .seq_cst);
        }
        _ = @atomicRmw(u64, &test_counter, .Add, 1, .seq_cst);
        _ = @atomicRmw(u64, &test_inside, .Sub, 1, .seq_cst);
        test_lock.release();
    }
}

/// Zig side of the application-processor entry path. Called by `ap_entry` with
/// a private descriptor and this CPU's `limine_mp_info`.
export fn ap_main(ctx: *ApContext, info: *limine.MpInfo) callconv(.c) noreturn {
    _ = info;

    // SSE and CR0.WP were enabled by `ap_entry` before this Zig code started.
    gdt.setKernelStack(ctx.gdt_cpu, ctx.stack_top);
    gdt.load(ctx.gdt_cpu);
    idt.load();

    _ = @atomicRmw(u64, &online_count, .Add, 1, .seq_cst);

    if (!test_mode) park();

    while (@atomicLoad(u64, &test_go, .acquire) == 0) {
        asm volatile ("pause");
    }

    runWorkload();
    _ = @atomicRmw(u64, &done_count, .Add, 1, .seq_cst);
    park();
}

fn park() noreturn {
    _ = @atomicRmw(u64, &parked_count, .Add, 1, .seq_cst);
    while (true) {
        asm volatile ("cli; hlt");
    }
}
