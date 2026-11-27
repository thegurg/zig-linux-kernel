//! zig-kernel: entry point and early boot sequence.
//!
//! Limine jumps to `_start` with the Limine stack and interrupts disabled.
//! `_start` switches to our own kernel stack and calls `kmain`, which brings up
//! the GDT/TSS, IDT and PIC before doing anything that may fault. M2-M10 then
//! program the PIT, bring up application processors and may hand control to
//! the scheduler.

const std = @import("std");
const build_options = @import("build_options");

const limine = @import("limine.zig");
const console = @import("console.zig");
const acpi = @import("acpi.zig");
const pmm = @import("memory/pmm.zig");
const vmm = @import("memory/vmm.zig");
const heap = @import("memory/heap.zig");
const serial = @import("arch/x86_64/serial.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const ioapic = @import("arch/x86_64/ioapic.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pic = @import("arch/x86_64/pic.zig");
const pit = @import("arch/x86_64/pit.zig");
const sched = @import("sched.zig");
const process = @import("process.zig");
const smp = @import("smp.zig");
const sync = @import("sync.zig");
const time = @import("time.zig");
const qemu = @import("arch/x86_64/qemu.zig");
const user = @import("user.zig");
const pci = @import("drivers/pci.zig");
const virtio_blk = @import("drivers/virtio_blk.zig");
const virtio_net = @import("drivers/virtio_net.zig");
const fat = @import("fs/fat.zig");
const tar = @import("fs/tar.zig");
const vfs = @import("fs/vfs.zig");
const storage = @import("storage.zig");
const net = @import("net/net.zig");
const network = @import("network.zig");

pub const version = "0.19.0-m19";

const timer_hz: u32 = time.tick_hz;
const timer_test_ticks: u64 = 30;
const sleep_ticks: u64 = 5;
const task_stack_size = 16 * 1024;
const m14_ioapic_ticks: u64 = 5;
const m14_preempt_iterations: u64 = 200_000_000;
const m14_max_spin: u64 = 200_000_000;

const m15_rate_ticks: u64 = 20;
const m15_rate_tolerance_percent: u64 = 20;
const m15_cross_cpu_tolerance_ns: u64 = 50_000_000;
const m15_sleep_ms: u64 = 50;
const m15_sleep_min_ns: u64 = 40_000_000;
const m15_sleep_max_ns: u64 = 80_000_000;
const m15_join_timeout_ms: u64 = 50;
const m15_max_spin: u64 = 200_000_000;

const m16_kernel_stack_size = 16 * 1024;
const m16_join_timeout_ms: u64 = 2_000;
const m16_preempt_spin: u64 = 200_000_000;
var m16_kernel_stacks: [12][m16_kernel_stack_size]u8 align(16) = undefined;

const m17_wait_timeout_ms: u64 = 2_000;
const m17_short_timeout_ms: u64 = 1;
const m17_basic_argv = [_][]const u8{ "m17proc", "basic" };
const m17_sleep_argv = [_][]const u8{ "m17proc", "sleep" };
const m17_instant_argv = [_][]const u8{ "m17proc", "instant" };
const m17_nx_argv = [_][]const u8{ "m17proc", "nx" };
const m17_guard_argv = [_][]const u8{ "m17proc", "guard" };
const m17_basic_env = [_][]const u8{"M17=1"};

const m18_wait_timeout_ms: u64 = 2_000;
const m18_init_argv = [_][]const u8{ "init", "basic" };
const m18_init_env = [_][]const u8{"M18=1"};

const m19_arp_timeout_ns: u64 = 1_000_000_000;
const m19_ping_timeout_ns: u64 = 2_000_000_000;
const m19_udp_timeout_ns: u64 = 200_000_000;
const m19_dns_timeout_ns: u64 = 3_000_000_000;
const m19_udp_port: u16 = 49160;
const m19_dns_name = "example.com";
var m17_elf_copy: [16 * 1024]u8 = undefined;
var m17_bad_elf: [64]u8 = @splat(0);
var m17_big_arg: [20_000]u8 = @splat('x');

var task_a_stack: [task_stack_size]u8 align(16) = undefined;
var task_b_stack: [task_stack_size]u8 align(16) = undefined;
var task_c_stack: [task_stack_size]u8 align(16) = undefined;
var task_a_runs: u64 = 0;
var task_b_runs: u64 = 0;
var task_c_runs: u64 = 0;
var task_d_runs: u64 = 0;
var task_e_runs: u64 = 0;
var task_f_runs: u64 = 0;
var task_g_runs: u64 = 0;
var wait_queue: sched.WaitQueue = .{};
var timed_wait_ticks: u64 = 0;
var timed_wait_signaled: u64 = 0;

var mutex: sched.Mutex = .{};
var mutex_value: u64 = 0;
var mutex_inside: u64 = 0;
var mutex_overlap: u64 = 0;
var mutex_done: u64 = 0;

var condition: sched.Condition = .{};
var condition_mutex: sched.Mutex = .{};
var condition_ready: u64 = 0;
var condition_waiting: u64 = 0;
var condition_waiter_done: u64 = 0;
var condition_signaler_done: u64 = 0;
var condition_signals: u64 = 0;

var m14_sleep_ticks: u64 = 0;
var m14_sleep_done: u64 = 0;
var m14_preempt_a: u64 = 0;
var m14_preempt_b: u64 = 0;
var m14_preempt_a_observed: u64 = 0;
var m14_preempt_b_observed: u64 = 0;
var m14_stacks: [3][task_stack_size]u8 align(16) = undefined;

var m15_barrier_ready: u64 = 0;
var m15_barrier_go: u64 = 0;
var m15_probe_ns: [sched.max_cpus]u64 = @splat(0);
var m15_probe_sleep_ns: [sched.max_cpus]u64 = @splat(0);
var m15_probe_monotonic: [sched.max_cpus]u64 = @splat(0);
var m15_probe_done: u64 = 0;
var m15_probe_stacks: [sched.max_cpus][task_stack_size]u8 align(16) = undefined;

var m15_sleep_ns: u64 = 0;
var m15_sleep_ticks: u64 = 0;
var m15_sleep_done: u64 = 0;
var m15_sleep_stack: [task_stack_size]u8 align(16) = undefined;

var m15_join_status: i32 = -1;
var m15_join_done: u64 = 0;
var m15_join_blocker: ?*sched.Task = null;
var m15_join_stacks: [4][task_stack_size]u8 align(16) = undefined;

var m15_priority_order: [3]i32 = @splat(-1);
var m15_priority_count: u64 = 0;
var m15_priority_stacks: [3][task_stack_size]u8 align(16) = undefined;

const fpu_pattern_a = [16]u8{
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0x0f, 0x1e,
};
const fpu_pattern_b = [16]u8{
    0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18,
    0x29, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90,
};
var fpu_result_a: [16]u8 align(16) = @splat(0);
var fpu_result_b: [16]u8 align(16) = @splat(0);
var fpu_done: u64 = 0;
var fpu_entered_a: u64 = 0;
var fpu_entered_b: u64 = 0;
var fpu_interleave_a: u64 = 0;
var fpu_interleave_b: u64 = 0;

pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(message: []const u8, return_address: ?usize) noreturn {
    serial.init();
    serial.write("\n[panic] ");
    serial.write(message);
    if (return_address) |address| {
        serial.write(" (return address 0x");
        serial.writeHex(address);
        serial.write(")");
    }
    serial.write("\n");
    qemu.exit(qemu.EXIT_FAILURE);
}

fn workerA() callconv(.c) void {
    const counter: *volatile u64 = &task_a_runs;
    counter.* +%= 1;
    sched.yield();
    counter.* +%= 1;
    sched.exit();
}

fn workerB() callconv(.c) void {
    const counter: *volatile u64 = &task_b_runs;
    counter.* +%= 1;
    sched.exit();
}

fn workerC() callconv(.c) void {
    const counter: *volatile u64 = &task_c_runs;
    counter.* +%= 1;
    sched.exit();
}

fn workerSleep() callconv(.c) void {
    const counter: *volatile u64 = &task_d_runs;
    sched.sleep(sleep_ticks);
    counter.* +%= 1;
    sched.exit();
}

fn workerBlock() callconv(.c) void {
    const counter: *volatile u64 = &task_e_runs;
    counter.* +%= 1;
    sched.block();
    counter.* +%= 1;
    sched.exit();
}

fn workerWait() callconv(.c) void {
    const counter: *volatile u64 = &task_f_runs;
    counter.* +%= 1;
    wait_queue.wait();
    counter.* +%= 1;
    sched.exit();
}

fn workerTimedWait() callconv(.c) void {
    const signaled = wait_queue.waitTimeout(timed_wait_ticks);
    const result: *volatile u64 = &timed_wait_signaled;
    result.* = if (signaled) 1 else 0;
    const counter: *volatile u64 = &task_g_runs;
    counter.* +%= 1;
    sched.exit();
}

fn workerMutex() callconv(.c) void {
    mutex.lock();

    const inside: *volatile u64 = &mutex_inside;
    inside.* +%= 1;
    if (inside.* != 1) {
        const overlap: *volatile u64 = &mutex_overlap;
        overlap.* +%= 1;
    }

    const value: *volatile u64 = &mutex_value;
    const before = value.*;
    sched.yield();
    value.* = before +% 1;
    inside.* -%= 1;
    mutex.unlock();

    const done: *volatile u64 = &mutex_done;
    done.* +%= 1;
    sched.exit();
}

fn workerConditionWaiter() callconv(.c) void {
    condition_mutex.lock();

    while (true) {
        const ready: *volatile u64 = &condition_ready;
        if (ready.* != 0) break;

        const waiting: *volatile u64 = &condition_waiting;
        waiting.* = 1;
        condition.wait(&condition_mutex);
    }

    const waiting: *volatile u64 = &condition_waiting;
    waiting.* = 0;
    const ready: *volatile u64 = &condition_ready;
    ready.* = 0;
    condition_mutex.unlock();

    const done: *volatile u64 = &condition_waiter_done;
    done.* +%= 1;
    sched.exit();
}

fn workerConditionSignaler() callconv(.c) void {
    condition_mutex.lock();

    const ready: *volatile u64 = &condition_ready;
    ready.* = 1;
    if (condition.signal()) {
        const signals: *volatile u64 = &condition_signals;
        signals.* +%= 1;
    }
    condition_mutex.unlock();

    const done: *volatile u64 = &condition_signaler_done;
    done.* +%= 1;
    sched.exit();
}

fn fpuWorker(pattern: *const [16]u8, result: *[16]u8) void {
    // The entire yield round trip stays inside one asm block so the compiler
    // cannot reuse XMM0 between `int $48` and the verification store. If the
    // scheduler fails to save/restore FPU state, this task reads the other
    // worker's pattern back.
    asm volatile (
        \\movdqu (%[pattern]), %%xmm0
        \\int $48
        \\movdqu %%xmm0, (%[result])
        :
        : [pattern] "r" (pattern),
          [result] "r" (result),
        : .{ .xmm0 = true, .memory = true });
}

fn workerFpuA() callconv(.c) void {
    const entered: *volatile u64 = &fpu_entered_a;
    entered.* = 1;
    fpuWorker(&fpu_pattern_a, &fpu_result_a);
    if (@as(*const volatile u64, &fpu_entered_b).* != 0) {
        const interleave: *volatile u64 = &fpu_interleave_a;
        interleave.* = 1;
    }
    const done: *volatile u64 = &fpu_done;
    done.* +%= 1;
    sched.exit();
}

fn workerFpuB() callconv(.c) void {
    const entered: *volatile u64 = &fpu_entered_b;
    entered.* = 1;
    fpuWorker(&fpu_pattern_b, &fpu_result_b);
    if (@as(*const volatile u64, &fpu_entered_a).* != 0) {
        const interleave: *volatile u64 = &fpu_interleave_b;
        interleave.* = 1;
    }
    const done: *volatile u64 = &fpu_done;
    done.* +%= 1;
    sched.exit();
}

fn m14Sleeper() callconv(.c) void {
    const before = sched.ticksOn(0);
    sched.sleep(sleep_ticks);
    m14_sleep_ticks = sched.ticksOn(0) -% before;
    _ = @atomicRmw(u64, &m14_sleep_done, .Add, 1, .seq_cst);
    sched.exit();
}

fn m14PreemptA() callconv(.c) void {
    m14PreemptWorkload(&m14_preempt_a, &m14_preempt_b, &m14_preempt_a_observed);
}

fn m14PreemptB() callconv(.c) void {
    m14PreemptWorkload(&m14_preempt_b, &m14_preempt_a, &m14_preempt_b_observed);
}

fn m14PreemptWorkload(own: *u64, other: *u64, observed: *u64) void {
    var iteration: u64 = 0;
    while (iteration < m14_preempt_iterations) : (iteration += 1) {
        _ = @atomicRmw(u64, own, .Add, 1, .monotonic);
        if (@atomicLoad(u64, other, .acquire) != 0) {
            @atomicStore(u64, observed, 1, .release);
            break;
        }
    }
    sched.exit();
}

/// ELF entry point. Limine gives us a valid stack, but it lives in
/// bootloader-reclaimable memory that later milestones will hand back to the
/// allocator. Switch to the kernel's own stack before entering Zig code.
export fn _start() callconv(.naked) noreturn {
    const code = std.fmt.comptimePrint(
        \\lea kernel_stack(%%rip), %%rsp
        \\addq ${d}, %%rsp
        \\xor %%rbp, %%rbp
        \\call kmain
        \\ud2
    , .{gdt.kernel_stack_size});
    asm volatile (code);
}

export fn kmain() callconv(.c) noreturn {
    asm volatile ("cli; cld");
    cpu.enableSse();

    serial.init();
    serial.write("\n");
    serial.write("zig-kernel: early boot\n");

    gdt.init();
    idt.init();
    pic.remap(0x20, 0x28);

    // Install the per-CPU block early so the interrupt entry path always has a
    // valid `%gs:0` FPU pointer, even before the scheduler exists.
    cpu.initPerCpu(0, 0);

    if (!limine.baseRevisionSupported()) {
        serial.write("zig-kernel: unsupported Limine base revision: ");
        serial.writeHex(limine.base_revision[2]);
        serial.write("\n");
        qemu.exit(qemu.EXIT_FAILURE);
    }

    pmm.init() catch |err| {
        serial.write("pmm: initialization failed: ");
        serial.write(@errorName(err));
        serial.write("\n");
        qemu.exit(qemu.EXIT_FAILURE);
    };

    vmm.init() catch |err| {
        serial.write("vmm: initialization failed: ");
        serial.write(@errorName(err));
        serial.write("\n");
        qemu.exit(qemu.EXIT_FAILURE);
    };
    heap.init();

    console.init();
    banner();
    reportBootInfo();

    // ACPI discovery needs the HHDM, so it runs after `vmm.init`. A failure is
    // not fatal: the kernel keeps the legacy PIC/PIT path available.
    acpi.init() catch |err| {
        console.print("acpi: unavailable: {s}\n", .{@errorName(err)});
    };
    if (acpi.isReady()) {
        const madt = acpi.getInfo();
        console.print("acpi: madt revision={d} cpus={d}/{d} ioapics={d} isos={d} lapic=0x{x}\n", .{
            madt.revision,     madt.enabled_local_apics, madt.local_apic_count,
            madt.ioapic_count, madt.iso_count,           madt.local_apic_address,
        });
        if (madt.lapic_address_override) |address| {
            console.print("acpi: lapic address override=0x{x}\n", .{address});
        }
    }

    const ioapic_ready = ioapic.init();
    if (ioapic_ready) {
        var index: usize = 0;
        while (index < ioapic.controllerCount()) : (index += 1) {
            const controller = ioapic.controllerAt(index) orelse continue;
            console.print("ioapic: id={d} version={d} entries={d} gsi_base={d} address=0x{x}\n", .{
                controller.id, controller.version, controller.entries, controller.gsi_base, controller.phys,
            });
        }
    } else {
        console.write("ioapic: unavailable\n");
    }

    smp.init() catch |err| {
        console.print("smp: initialization failed: {s}\n", .{@errorName(err)});
    };

    const lapic_ready = lapic.init();
    if (!lapic_ready) console.write("lapic: initialization failed\n");
    const bsp_lapic_id = if (lapic_ready) lapic.id() else smp.getStats().bsp_lapic_id;
    cpu.initPerCpu(0, bsp_lapic_id);
    sched.init();
    process.init();
    vmm.setTlbShootdownHandler(&sched.shootdownTlb);

    // Establish the time base before any AP is released. The TSC calibration
    // uses PIT channel 2, which is free at this point and independent of the
    // scheduler's channel 0 tick. `force_pit` also forces the tick fallback so
    // the fallback boot image exercises both timer and time fallbacks.
    time.init(build_options.force_pit);
    const boot_time = time.info();
    console.print("time: tsc={d} invariant={d} calibrated={d} hz={d} source={s} reason={s}\n", .{
        @intFromBool(boot_time.tsc_supported),
        @intFromBool(boot_time.invariant_tsc),
        @intFromBool(boot_time.tsc_calibrated),
        boot_time.tsc_hz,
        @tagName(boot_time.source),
        @tagName(boot_time.fallback_reason),
    });

    // Measure the LAPIC timer on the BSP before releasing the APs; they reuse
    // the same reload value. PIT channel 2 is only the calibration reference.
    var lapic_timer_ready = false;
    if (lapic_ready) {
        if (lapic.calibrateTimer(timer_hz)) |count| {
            console.print("timer: LAPIC {d} counts per tick\n", .{count});
            lapic_timer_ready = true;
        } else {
            console.write("timer: LAPIC calibration failed; PIT fallback available\n");
        }
    }

    if (smp.getStats().cpus != 0) {
        const smp_stats = smp.getStats();
        console.print("smp: cpus={d}, aps={d}, bsp_lapic_id={d}, x2apic={d}\n", .{
            smp_stats.cpus, smp_stats.aps, smp_stats.bsp_lapic_id, @intFromBool(lapic.isX2apic()),
        });
        if (!build_options.exit_after_boot and smp_stats.aps != 0) {
            if (smp.start() and smp.waitOnline()) {
                console.print("smp: {d} APs online, scheduler idle\n", .{smp.onlineCount()});
                if (!syncTimeOffsets()) console.write("time: TSC synchronization failed\n");
            } else {
                console.write("smp: failed to bring APs online\n");
            }
        }
    }

    if (build_options.test_page_fault) {
        serial.write("selftest: triggering page fault\n");
        asm volatile (
            \\xor %%rax, %%rax
            \\movb (%%rax), %%al
            ::: .{ .rax = true, .memory = true });
        serial.write("selftest: page fault did not fire\n");
        qemu.exit(qemu.EXIT_FAILURE);
    }

    if (build_options.exit_after_boot) {
        serial.write("selftest: checking PMM\n");
        if (!selftestPmm()) {
            serial.write("selftest: PMM checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: PMM checks passed\n");

        serial.write("selftest: checking VMM\n");
        if (!selftestVmm()) {
            serial.write("selftest: VMM checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: VMM checks passed\n");

        serial.write("selftest: checking heap\n");
        if (!selftestHeap()) {
            serial.write("selftest: heap checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: heap checks passed\n");
        serial.write("selftest: M1c checks passed\n");

        serial.write("selftest: checking timer and scheduler\n");
        if (!selftestTimerScheduler()) {
            stopTimer();
            serial.write("selftest: timer/scheduler checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: timer checks passed\n");
        serial.write("selftest: scheduler checks passed\n");
        serial.write("selftest: M2 checks passed\n");

        serial.write("selftest: checking task lifecycle\n");
        if (!selftestTaskLifecycle()) {
            stopTimer();
            serial.write("selftest: task lifecycle checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: lifecycle checks passed\n");
        serial.write("selftest: M3 checks passed\n");

        serial.write("selftest: checking sleep\n");
        if (!selftestSleep()) {
            stopTimer();
            serial.write("selftest: sleep checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: sleep checks passed\n");
        serial.write("selftest: M4 checks passed\n");

        serial.write("selftest: checking blocking wakeup\n");
        if (!selftestBlocking()) {
            stopTimer();
            serial.write("selftest: blocking checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: block checks passed\n");
        serial.write("selftest: M5 checks passed\n");

        serial.write("selftest: checking wait queue\n");
        if (!selftestWaitQueue()) {
            stopTimer();
            serial.write("selftest: wait queue checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: waitq checks passed\n");
        serial.write("selftest: M6 checks passed\n");

        serial.write("selftest: checking timed wait\n");
        if (!selftestTimedWait()) {
            stopTimer();
            serial.write("selftest: timed wait checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: timed checks passed\n");
        serial.write("selftest: M7 checks passed\n");

        serial.write("selftest: checking mutex\n");
        if (!selftestMutex()) {
            stopTimer();
            serial.write("selftest: mutex checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: mutex checks passed\n");

        serial.write("selftest: checking condition variable\n");
        if (!selftestCondition()) {
            stopTimer();
            serial.write("selftest: condition checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: cond checks passed\n");
        serial.write("selftest: M8 checks passed\n");

        serial.write("selftest: checking FPU context switch\n");
        if (!selftestFpu()) {
            stopTimer();
            serial.write("selftest: fpu checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: fpu checks passed\n");
        serial.write("selftest: M9 checks passed\n");

        stopTimer();
        serial.write("selftest: checking SMP\n");
        if (!selftestSmp()) {
            serial.write("selftest: smp checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: smp checks passed\n");
        serial.write("selftest: M11 checks passed\n");

        serial.write("selftest: checking M12 allocator and TLB hardening\n");
        if (!selftestM12()) {
            serial.write("selftest: M12 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M12 checks passed\n");

        serial.write("selftest: checking M13 per-CPU timers\n");
        if (!selftestM13()) {
            serial.write("selftest: M13 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M13 checks passed\n");

        serial.write("selftest: checking M14 ACPI, IOAPIC and CPU 0 timer\n");
        if (!selftestM14()) {
            serial.write("selftest: M14 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M14 checks passed\n");

        serial.write("selftest: checking M15 time and scheduler contracts\n");
        if (!selftestM15()) {
            serial.write("selftest: M15 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M15 checks passed\n");

        serial.write("selftest: checking M16 ring 3 and address spaces\n");
        if (!selftestM16()) {
            serial.write("selftest: M16 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M16 checks passed\n");

        serial.write("selftest: checking M17 ELF loading and process lifecycle\n");
        if (!selftestM17()) {
            serial.write("selftest: M17 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M17 checks passed\n");

        serial.write("selftest: checking M18 PCI, virtio-blk and VFS\n");
        if (!selftestM18()) {
            serial.write("selftest: M18 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M18 checks passed\n");

        serial.write("selftest: checking M19 virtio-net and network stack\n");
        if (!selftestM19()) {
            serial.write("selftest: M19 checks failed\n");
            qemu.exit(qemu.EXIT_FAILURE);
        }
        serial.write("selftest: M19 checks passed\n");

        serial.write("selftest: triggering int3\n");
        asm volatile ("int3");
        serial.write("selftest: returned from int3\n");
        serial.write("selftest: exiting QEMU\n");
        qemu.exit(qemu.EXIT_SUCCESS);
    }

    const storage_status = storage.init();
    console.print("storage: pci={d} virtio={d} fat={d} initramfs={d}\n", .{
        storage_status.pci_devices,
        @intFromBool(storage_status.virtio),
        @intFromBool(storage_status.fat),
        @intFromBool(storage_status.initramfs),
    });

    const network_status = network.init();
    if (network_status.configured) {
        var mac_buffer: [18]u8 = undefined;
        var ip_buffer: [16]u8 = undefined;
        const mac_text = net.macString(&mac_buffer, network_status.info.?.mac);
        const ip_text = net.ipv4String(&ip_buffer, network.guest_ip);
        console.print("network: pci={d} device=1 configured=1 mac={s} ip={s}\n", .{
            network_status.pci_devices, mac_text, ip_text,
        });
    } else {
        console.print("network: pci={d} device={d} configured=0\n", .{
            network_status.pci_devices, @intFromBool(network_status.device),
        });
    }

    console.print("\nboot: {s} initialized (memory, per-CPU scheduler, SMP)\n", .{version});

    // CPU 0 uses the same LAPIC timer as the APs whenever calibration
    // succeeded. The legacy PIT path remains the fallback and is selected
    // explicitly by the `force_pit` test image.
    if (!build_options.force_pit and lapic_timer_ready and lapic.startPeriodicTimer(sched.timer_vector)) {
        console.write("timer: source=lapic\n");
    } else {
        pit.init(timer_hz);
        pic.unmask(0);
        console.print("timer: source=pit, {d} Hz, IRQ0 unmasked\n", .{timer_hz});
    }
    console.write("scheduler: boot task exiting to idle (interrupts enabled there)\n");
    sched.exit();
}

fn banner() void {
    console.banner("zig-kernel " ++ version);
    console.write("x86_64 | limine boot protocol | framebuffer + COM1 console\n");
}

fn reportBootInfo() void {
    console.print("limine base revision: {d}\n", .{limine.base_revision_number});

    if (limine.hhdmOffset()) |offset| {
        console.print("hhdm offset: 0x{x}\n", .{offset});
    } else {
        console.write("hhdm offset: unavailable\n");
    }

    if (limine.executableAddress()) |address| {
        console.print("executable: phys=0x{x} virt=0x{x}\n", .{
            address.physical_base, address.virtual_base,
        });
    } else {
        console.write("executable: address unavailable\n");
    }

    if (limine.framebuffer()) |fb| {
        const address = if (fb.address) |ptr| @intFromPtr(ptr) else 0;
        console.print("framebuffer: {d}x{d}, {d} bpp, pitch {d} bytes, at 0x{x}\n", .{
            fb.width, fb.height, fb.bpp, fb.pitch, address,
        });
    } else {
        console.write("framebuffer: unavailable (serial only)\n");
    }

    const memmap = limine.memmap() orelse {
        console.write("memory map: unavailable\n");
        return;
    };

    var usable_bytes: u64 = 0;
    var index: u64 = 0;
    while (index < memmap.entry_count) : (index += 1) {
        const entry = memmap.entries[index] orelse continue;
        if (entry.type == @backingInt(limine.MemmapEntryType.usable)) {
            usable_bytes += entry.length;
        }
    }
    console.print("memory map: {d} entries, {d} MiB usable\n", .{
        memmap.entry_count, usable_bytes / (1024 * 1024),
    });

    const pmm_stats = pmm.stats();
    console.print("pmm: {d} MiB free / {d} MiB managed ({d} pages)\n", .{
        pmm.freeBytes() / (1024 * 1024),
        pmm.totalBytes() / (1024 * 1024),
        pmm_stats.total_pages,
    });

    const paging = vmm.stats();
    console.print("paging: pml4=0x{x}, kernel 0x{x} -> 0x{x} ({d} KiB), hhdm {d} MiB\n", .{
        paging.pml4_phys,
        paging.kernel_virt_base,
        paging.kernel_phys_base,
        paging.kernel_bytes / 1024,
        paging.hhdm_bytes / (1024 * 1024),
    });

    const heap_stats = heap.stats();
    console.print("heap: {d} MiB reserved at 0x{x}, {d} KiB mapped\n", .{
        heap_stats.reserved_bytes / (1024 * 1024),
        heap.base,
        heap_stats.mapped_bytes / 1024,
    });
}

fn selftestPmm() bool {
    const before = pmm.stats();
    if (before.total_pages < 4 or before.free_pages < 4) return false;

    var pages: [4]u64 = undefined;
    for (&pages) |*slot| {
        slot.* = pmm.allocPage() orelse return false;
        if (slot.* == 0) return false; // zero page must stay reserved
        if (slot.* % pmm.page_size != 0) return false;
        if (slot.* >= pmm.max_physical_address) return false;
    }

    for (0..pages.len) |i| {
        for (i + 1..pages.len) |j| {
            if (pages[i] == pages[j]) return false;
        }
    }

    if (pmm.stats().free_pages != before.free_pages - pages.len) return false;

    if (!pmm.freePage(pages[1])) return false;
    if (pmm.stats().free_pages != before.free_pages - pages.len + 1) return false;
    if (pmm.freePage(pages[1])) return false; // double free must fail
    if (pmm.freePage(1)) return false; // misaligned address
    if (pmm.freePage(pmm.max_physical_address)) return false; // out of range
    if (pmm.freePage(0)) return false; // reserved/never allocated

    const reused = pmm.allocPage() orelse return false;
    if (reused != pages[1]) return false; // free page must be reused first
    if (pmm.stats().free_pages != before.free_pages - pages.len) return false;

    if (!pmm.freePage(reused)) return false;
    if (!pmm.freePage(pages[0])) return false;
    if (!pmm.freePage(pages[2])) return false;
    if (!pmm.freePage(pages[3])) return false;

    return pmm.stats().free_pages == before.free_pages;
}

fn selftestVmm() bool {
    const paging = vmm.stats();
    if (!paging.active) return false;
    if (vmm.currentPml4() != paging.pml4_phys) return false;

    const code = @intFromPtr(&selftestVmm);
    const expected = vmm.kernelPhysical(code) orelse return false;
    if (vmm.translate(code) != expected) return false;

    const hhdm = vmm.hhdmOffset();
    if (limine.framebuffer()) |fb| {
        if (fb.address) |address| {
            const fb_virt: u64 = @intCast(@intFromPtr(address));
            if (fb_virt >= hhdm) {
                const fb_phys = fb_virt - hhdm;
                if (fb_phys < pmm.max_physical_address and vmm.translate(fb_virt) != fb_phys) {
                    return false;
                }
            }
        }
    }

    const phys = pmm.allocPage() orelse return false;
    const test_virt: u64 = 0xffffffffb0000000;
    var mapped = false;
    defer {
        if (mapped) _ = vmm.unmapPage(test_virt);
        _ = pmm.freePage(phys);
    }

    const hhdm_ptr: *volatile u64 = @ptrFromInt(hhdm + phys);
    hhdm_ptr.* = 0x1122334455667788;
    if (vmm.translate(hhdm + phys) != phys) return false;

    if (vmm.mapPage(test_virt + 1, phys, vmm.kernel_rw)) return false; // misaligned
    if (!vmm.mapPage(test_virt, phys, vmm.kernel_rw)) return false;
    mapped = true;

    if (vmm.mapPage(test_virt, phys, vmm.kernel_rw)) return false; // already mapped
    if (vmm.translate(test_virt) != phys) return false;

    const test_ptr: *volatile u64 = @ptrFromInt(test_virt);
    if (test_ptr.* != 0x1122334455667788) return false;
    test_ptr.* = 0x8877665544332211;
    if (hhdm_ptr.* != 0x8877665544332211) return false;

    if (!vmm.unmapPage(test_virt)) return false;
    mapped = false;
    if (vmm.translate(test_virt) != null) return false;

    return true;
}

fn selftestHeap() bool {
    const empty = heap.stats();
    if (empty.mapped_bytes != 0) return false;
    if (empty.reserved_bytes != heap.reserved_bytes) return false;

    const a = heap.alloc(64, 8) orelse return false;
    const b = heap.alloc(128, 16) orelse return false;
    const c = heap.alloc(4096, 4096) orelse return false;

    if (@intFromPtr(a) % 8 != 0) return false;
    if (@intFromPtr(b) % 16 != 0) return false;
    if (@intFromPtr(c) % 4096 != 0) return false;
    if (rangesOverlap(a, 64, b, 128)) return false;
    if (rangesOverlap(a, 64, c, 4096)) return false;
    if (rangesOverlap(b, 128, c, 4096)) return false;

    for (0..64) |i| a[i] = @truncate(i);
    for (0..128) |i| b[i] = @truncate(i + 1);
    @memset(c[0..4096], 0xab);

    for (0..64) |i| {
        if (a[i] != @as(u8, @truncate(i))) return false;
    }
    for (0..128) |i| {
        if (b[i] != @as(u8, @truncate(i + 1))) return false;
    }
    for (c[0..4096]) |byte| {
        if (byte != 0xab) return false;
    }

    heap.free(a, 64);
    const a2 = heap.alloc(64, 8) orelse return false;
    if (a2 != a) return false;

    heap.free(b, 128);
    heap.free(c, 4096);
    heap.free(a2, 64);

    const slice = heap.allocator.alloc(u8, 100) catch return false;
    @memset(slice, 0x5a);
    if (slice[99] != 0x5a) return false;
    heap.allocator.free(slice);

    if (heap.alloc(heap.reserved_bytes + 1, 8) != null) return false;

    const after = heap.stats();
    return after.mapped_bytes > 0 and after.free_bytes == after.mapped_bytes;
}

fn selftestTimerScheduler() bool {
    task_a_runs = 0;
    task_b_runs = 0;

    if (sched.stats().tasks != 2) return false; // boot + idle
    if (sched.create("worker-a", workerA, task_a_stack[0..]) == null) return false;
    if (sched.create("worker-b", workerB, task_b_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    pit.init(timer_hz);
    pic.unmask(0);

    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const a = @as(*const volatile u64, &task_a_runs).*;
    const b = @as(*const volatile u64, &task_b_runs).*;
    const finished = sched.finishedCount();
    console.print("timer: {d} ticks at {d} Hz\n", .{ elapsed, timer_hz });
    console.print("scheduler: worker counters a={d}, b={d}, finished={d}\n", .{ a, b, finished });

    return elapsed >= timer_test_ticks and a > 0 and b > 0 and finished >= 2;
}

fn selftestTaskLifecycle() bool {
    task_c_runs = 0;

    // The timer test leaves interrupts disabled. Interrupts are enabled again
    // only after worker-c has been fully inserted into the scheduler.
    if (sched.create("worker-c", workerC, task_c_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false; // worker-c reused a finished slot

    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks and sched.finishedCount() < 3) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const c = @as(*const volatile u64, &task_c_runs).*;
    const finished = sched.finishedCount();
    console.print("lifecycle: worker-c={d}, finished={d}, elapsed={d} ticks\n", .{ c, finished, elapsed });

    return c > 0 and finished >= 3;
}

fn selftestSleep() bool {
    task_d_runs = 0;

    // worker-c has finished, so its slot and stack can be reused.
    if (sched.create("worker-sleep", workerSleep, task_c_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks and sched.finishedCount() < 4) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const d = @as(*const volatile u64, &task_d_runs).*;
    const finished = sched.finishedCount();
    console.print("sleep: worker-sleep={d}, finished={d}, elapsed={d} ticks\n", .{ d, finished, elapsed });

    return d > 0 and finished >= 4 and elapsed >= sleep_ticks;
}

fn selftestBlocking() bool {
    task_e_runs = 0;

    const worker = sched.create("worker-block", workerBlock, task_c_stack[0..]) orelse return false;
    if (sched.stats().tasks != 4) return false;

    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks and sched.blockedCount() == 0) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    if (sched.blockedCount() == 0) {
        console.write("block: timed out waiting for worker to block\n");
        return false;
    }
    const first = @as(*const volatile u64, &task_e_runs).*;
    if (first == 0) return false;
    if (!sched.wake(worker)) return false;

    const wake_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - wake_start < timer_test_ticks and sched.finishedCount() < 5) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const e = @as(*const volatile u64, &task_e_runs).*;
    const finished = sched.finishedCount();
    console.print("block: worker-block={d}, finished={d}, elapsed={d} ticks\n", .{ e, finished, elapsed });

    return e == 2 and finished >= 5;
}

fn selftestWaitQueue() bool {
    task_f_runs = 0;

    if (sched.create("worker-wait", workerWait, task_c_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks and sched.blockedCount() == 0) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    if (sched.blockedCount() == 0) {
        console.write("waitq: timed out waiting for worker\n");
        return false;
    }
    const first = @as(*const volatile u64, &task_f_runs).*;
    if (first == 0) return false;
    if (!wait_queue.wakeOne()) return false;

    const wake_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - wake_start < timer_test_ticks and sched.finishedCount() < 6) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const f = @as(*const volatile u64, &task_f_runs).*;
    const finished = sched.finishedCount();
    console.print("waitq: worker-wait={d}, finished={d}, elapsed={d} ticks\n", .{ f, finished, elapsed });

    return f == 2 and finished >= 6;
}

fn selftestTimedWait() bool {
    // Timeout path: nobody signals the queue, so the worker must be woken by
    // its deadline and report a timeout to the boot task.
    task_g_runs = 0;
    timed_wait_signaled = 0;
    const timeout_ticks: u64 = 3;
    timed_wait_ticks = timeout_ticks;

    if (sched.create("worker-timed", workerTimedWait, task_c_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const timeout_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - timeout_start < timer_test_ticks and sched.finishedCount() < 7) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const timeout_elapsed = sched.ticks() - timeout_start;
    const timeout_runs = @as(*const volatile u64, &task_g_runs).*;
    const timeout_signaled = @as(*const volatile u64, &timed_wait_signaled).*;
    const after_timeout = sched.finishedCount();
    if (timeout_runs != 1 or timeout_signaled != 0 or after_timeout < 7 or timeout_elapsed < timeout_ticks) {
        console.print("timed: timeout path failed: runs={d}, signaled={d}, finished={d}, elapsed={d}\n", .{
            timeout_runs, timeout_signaled, after_timeout, timeout_elapsed,
        });
        return false;
    }

    // Signal path: the boot task wakes the waiter well before its deadline,
    // and the worker must report a normal signal rather than a timeout.
    task_g_runs = 0;
    timed_wait_signaled = 0;
    timed_wait_ticks = timer_test_ticks;

    if (sched.create("worker-timed", workerTimedWait, task_c_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const signal_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - signal_start < timer_test_ticks and sched.blockedCount() == 0) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    if (sched.blockedCount() == 0 or !wait_queue.wakeOne()) {
        console.write("timed: signal path failed to block/wake\n");
        return false;
    }

    const wake_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - wake_start < timer_test_ticks and sched.finishedCount() < 8) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const signal_elapsed = sched.ticks() - signal_start;
    const signal_runs = @as(*const volatile u64, &task_g_runs).*;
    const signal_signaled = @as(*const volatile u64, &timed_wait_signaled).*;
    const finished = sched.finishedCount();
    console.print("timed: timeout={d} ticks, signaled={d}, finished={d}, elapsed={d} ticks\n", .{
        timeout_elapsed, signal_signaled, finished, signal_elapsed,
    });

    return signal_runs == 1 and signal_signaled == 1 and finished >= 8;
}

fn selftestMutex() bool {
    mutex_value = 0;
    mutex_inside = 0;
    mutex_overlap = 0;
    mutex_done = 0;

    if (sched.create("worker-mutex-a", workerMutex, task_a_stack[0..]) == null) return false;
    if (sched.create("worker-mutex-b", workerMutex, task_b_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const base = sched.finishedCount();
    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks and sched.finishedCount() < base + 2) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const value = @as(*const volatile u64, &mutex_value).*;
    const done = @as(*const volatile u64, &mutex_done).*;
    const overlap = @as(*const volatile u64, &mutex_overlap).*;
    const finished = sched.finishedCount();
    console.print("mutex: value={d}, done={d}, overlap={d}, finished={d}, elapsed={d} ticks\n", .{
        value, done, overlap, finished, elapsed,
    });

    return value == 2 and done == 2 and overlap == 0 and finished >= base + 2;
}

fn selftestCondition() bool {
    condition_ready = 0;
    condition_waiting = 0;
    condition_waiter_done = 0;
    condition_signaler_done = 0;
    condition_signals = 0;

    if (sched.create("worker-cond-wait", workerConditionWaiter, task_a_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const wait_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - wait_start < timer_test_ticks and
        @as(*const volatile u64, &condition_waiting).* == 0)
    {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    if (@as(*const volatile u64, &condition_waiting).* == 0) {
        console.write("cond: timed out waiting for waiter\n");
        return false;
    }

    // The waiter holds `condition_mutex` across the predicate check and
    // `wait`, so this signaller cannot run ahead of the enqueue.
    if (sched.create("worker-cond-signal", workerConditionSignaler, task_b_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const base = sched.finishedCount();
    const signal_start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - signal_start < timer_test_ticks and sched.finishedCount() < base + 2) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - signal_start;
    const ready = @as(*const volatile u64, &condition_ready).*;
    const waiter_done = @as(*const volatile u64, &condition_waiter_done).*;
    const signaler_done = @as(*const volatile u64, &condition_signaler_done).*;
    const signals = @as(*const volatile u64, &condition_signals).*;
    const finished = sched.finishedCount();
    console.print("cond: ready={d}, waiter={d}, signaler={d}, signals={d}, finished={d}, elapsed={d} ticks\n", .{
        ready, waiter_done, signaler_done, signals, finished, elapsed,
    });

    return ready == 0 and waiter_done == 1 and signaler_done == 1 and signals == 1 and finished >= base + 2;
}

fn selftestFpu() bool {
    fpu_done = 0;
    fpu_entered_a = 0;
    fpu_entered_b = 0;
    fpu_interleave_a = 0;
    fpu_interleave_b = 0;
    fpu_result_a = @splat(0);
    fpu_result_b = @splat(0);

    if (sched.create("worker-fpu-a", workerFpuA, task_a_stack[0..]) == null) return false;
    if (sched.create("worker-fpu-b", workerFpuB, task_b_stack[0..]) == null) return false;
    if (sched.stats().tasks != 4) return false;

    const base = sched.finishedCount();
    const start = sched.ticks();
    asm volatile ("sti");
    while (sched.ticks() - start < timer_test_ticks and sched.finishedCount() < base + 2) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    const elapsed = sched.ticks() - start;
    const done = @as(*const volatile u64, &fpu_done).*;
    const finished = sched.finishedCount();
    const a_ok = std.mem.eql(u8, &fpu_result_a, &fpu_pattern_a);
    const b_ok = std.mem.eql(u8, &fpu_result_b, &fpu_pattern_b);
    const interleaved = @as(*const volatile u64, &fpu_interleave_a).* == 1 and
        @as(*const volatile u64, &fpu_interleave_b).* == 1;
    console.print("fpu: done={d}, a_ok={d}, b_ok={d}, interleaved={d}, finished={d}, elapsed={d} ticks\n", .{
        done, @intFromBool(a_ok), @intFromBool(b_ok), @intFromBool(interleaved), finished, elapsed,
    });

    return done == 2 and a_ok and b_ok and interleaved and finished >= base + 2;
}

fn selftestSmp() bool {
    const smp_stats = smp.getStats();
    if (smp_stats.aps != 0 and lapic.timerCountPerTick() == 0) {
        if (lapic.calibrateTimer(timer_hz) == null) {
            console.write("timer: LAPIC calibration failed\n");
            return false;
        }
    }
    if (!smp.start()) {
        console.print("smp: start failed: cpus={d}, aps={d}\n", .{ smp_stats.cpus, smp_stats.aps });
        return false;
    }
    if (!smp.waitOnline()) {
        console.write("smp: timed out waiting for APs\n");
        return false;
    }
    if (smp_stats.aps != 0) {
        console.print("smp: {d} APs online for scheduler tests\n", .{smp.onlineCount()});
    }

    // `stopTimer` disabled scheduling for the earlier BSP-only tests. AP tasks
    // need the scheduler (and blocking) enabled again.
    sched.resumeScheduling();
    // The M12 shootdown tests need the BSP to accept remote IPIs while the APs
    // are running. IRQ0 stays masked by `stopTimer`.
    asm volatile ("sti" ::: .{ .memory = true });
    if (!syncTimeOffsets()) console.write("time: TSC synchronization failed\n");

    const result = smp.runTest() orelse {
        console.print("smp: did not complete: cpus={d}, aps={d}, online={d}\n", .{
            smp_stats.cpus, smp_stats.aps, smp.onlineCount(),
        });
        return false;
    };
    console.print("smp: cpus={d}, aps={d}, online={d}, counter={d}, expected={d}, overlap={d}\n", .{
        result.cpus, result.aps, result.online, result.counter, result.expected, result.overlap,
    });

    const cross_cpu = smp.runCrossCpuWakeTest() orelse return false;
    const ap_exception = smp.runApExceptionTest() orelse return false;
    const tlb = selftestTlbShootdown();
    const locks = selftestLockGuards();
    console.print("smp: cross-cpu wake={d}, ap exception={d}, tlb={d}, nested locks={d}\n", .{
        @intFromBool(cross_cpu), @intFromBool(ap_exception), @intFromBool(tlb), @intFromBool(locks),
    });

    return result.online == result.aps and
        result.counter == result.expected and
        result.overlap == 0 and
        cross_cpu and ap_exception and tlb and locks;
}

/// M12: concurrent heap allocation and TLB-shootdown hardening. Runs with the
/// APs online and BSP interrupts enabled (set up by `selftestSmp`).
fn selftestM12() bool {
    const heap_result = smp.runConcurrentHeapTest() orelse return false;
    if (heap_result.errors != 0) {
        console.print("heap: concurrent allocs={d}, errors={d}\n", .{
            heap_result.allocs, heap_result.errors,
        });
        return false;
    }
    console.print("heap: concurrent allocs={d}, errors=0\n", .{heap_result.allocs});

    const irq_off = smp.runIrqOffShootdownTest() orelse return false;
    const tlb_result = smp.runConcurrentShootdownTest() orelse return false;
    if (!irq_off or tlb_result.errors != 0) {
        console.print("tlb: irq-off={d}, concurrent shootdowns={d}, errors={d}\n", .{
            @intFromBool(irq_off), tlb_result.shootdowns, tlb_result.errors,
        });
        return false;
    }
    if (smp.getStats().aps != 0 and tlb_result.shootdowns == 0) return false;

    console.print("tlb: irq-off=1, concurrent shootdowns={d}, errors=0\n", .{
        tlb_result.shootdowns,
    });
    return true;
}

/// M13: per-CPU timer counters, local AP sleep wakeups, and timer-driven AP
/// preemption. Runs with the APs online and their LAPIC timers active.
fn selftestM13() bool {
    const aps = smp.getStats().aps;
    if (aps != 0 and lapic.timerCountPerTick() == 0) return false;

    const result = smp.runTimerTest() orelse {
        console.write("timer: AP timer test did not complete\n");
        return false;
    };
    console.print("timer: per-cpu ticks={d}, sleepers={d}, preempted={d} (a={d}, b={d}, ticks={d})\n", .{
        result.ticks,     result.sleepers,  @intFromBool(result.preempted),
        result.preempt_a, result.preempt_b, result.preempt_ticks,
    });
    if (aps != 0 and (result.sleepers != aps or result.ticks < 3 * @as(u64, aps))) return false;
    return result.preempted;
}

/// M14: prove that ACPI/MADT and the IOAPIC are usable, deliver the still
/// running PIT through ISA IRQ 0 -> MADT ISO -> GSI, acknowledge it through the
/// Local APIC, then switch CPU 0 to its own LAPIC timer and exercise a local
/// sleeper and timer-driven preemption.
fn selftestM14() bool {
    if (!acpi.isReady()) {
        console.write("m14: ACPI MADT unavailable\n");
        return false;
    }
    const madt = acpi.getInfo();
    if (madt.ioapic_count == 0 or ioapic.controllerCount() == 0) {
        console.write("m14: no usable IOAPIC\n");
        return false;
    }
    if (!lapic.isInitialized() or lapic.timerCountPerTick() == 0) {
        console.write("m14: LAPIC timer not calibrated\n");
        return false;
    }

    // Cross-check the MADT CPU list against Limine's MP response.
    const smp_stats = smp.getStats();
    if (madt.enabled_local_apics < smp_stats.cpus) {
        console.print("m14: MADT cpus={d} below limine cpus={d}\n", .{
            madt.enabled_local_apics, smp_stats.cpus,
        });
        return false;
    }
    var bsp_found = false;
    var index: usize = 0;
    while (index < madt.local_apic_count) : (index += 1) {
        const entry = madt.local_apics[index];
        if (entry.enabled and entry.id == smp_stats.bsp_lapic_id) bsp_found = true;
    }
    if (!bsp_found) {
        console.print("m14: BSP LAPIC {d} missing from MADT\n", .{smp_stats.bsp_lapic_id});
        return false;
    }
    console.print("acpi: madt cpus matched limine={d}, bsp_lapic_id={d}\n", .{
        smp_stats.cpus, smp_stats.bsp_lapic_id,
    });

    const route = acpi.isaIrqRoute(0) orelse return false;
    console.print("m14: irq0 gsi={d}, polarity={s}, trigger={s}, overridden={d}\n", .{
        route.gsi,
        @tagName(route.polarity),
        @tagName(route.trigger),
        @intFromBool(route.overridden),
    });

    // The legacy PIC line is masked by `stopTimer`; the PIT itself keeps
    // running. Route its IRQ 0 through the ISO-resolved GSI to the scheduler
    // timer vector and observe LAPIC-EOI'd ticks.
    asm volatile ("cli");
    lapic.stopTimer();
    const start_ticks = sched.ticksOn(0);
    const result = ioapic.routeIsaIrq(0, sched.timer_vector, cpu.per_cpu[0].lapic_id) orelse {
        console.write("m14: IOAPIC IRQ0 routing failed\n");
        return false;
    };

    const expected_polarity: u32 = if (route.polarity == .active_low) 1 else 0;
    const expected_trigger: u32 = if (route.trigger == .level) 1 else 0;
    const vector_ok = @as(u8, @truncate(result.low & 0xff)) == sched.timer_vector;
    const dest_ok = ((result.high >> 24) & 0xff) == (cpu.per_cpu[0].lapic_id & 0xff);
    const polarity_ok = ((result.low >> 13) & 1) == expected_polarity;
    const trigger_ok = ((result.low >> 15) & 1) == expected_trigger;
    const unmasked = (result.low & (1 << 16)) == 0;
    console.print("m14: ioapic entry low=0x{x} high=0x{x}\n", .{ result.low, result.high });
    if (!(vector_ok and dest_ok and polarity_ok and trigger_ok and unmasked)) {
        console.write("m14: IOAPIC redirection readback mismatch\n");
        return false;
    }

    asm volatile ("sti");
    var spins: u64 = 0;
    while (sched.ticksOn(0) - start_ticks < m14_ioapic_ticks) {
        if (spins >= m14_max_spin) {
            asm volatile ("cli");
            console.write("m14: IOAPIC interrupt timeout\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }
    const ioapic_ticks = sched.ticksOn(0) - start_ticks;
    console.print("m14: ioapic ticks={d}\n", .{ioapic_ticks});

    asm volatile ("cli");
    if (!ioapic.setMasked(result.gsi, true)) return false;
    const masked = ioapic.isMasked(result.gsi) orelse return false;
    if (!masked) {
        console.write("m14: IOAPIC mask readback failed\n");
        return false;
    }

    // CPU 0 now uses the same timer mechanism as every AP.
    if (!lapic.startPeriodicTimer(sched.timer_vector)) return false;
    console.write("timer: source=lapic\n");

    m14_sleep_ticks = 0;
    m14_sleep_done = 0;
    const sleep_base = sched.finishedCount();
    if (sched.createOn(0, "cpu0-sleeper", m14Sleeper, m14_stacks[0][0..]) == null) return false;

    asm volatile ("sti");
    spins = 0;
    while (@atomicLoad(u64, &m14_sleep_done, .acquire) == 0 or
        sched.finishedCount() < sleep_base + 1)
    {
        if (spins >= m14_max_spin) {
            asm volatile ("cli");
            console.write("m14: CPU 0 sleep timed out\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }
    asm volatile ("cli");

    const slept = @atomicLoad(u64, &m14_sleep_ticks, .acquire);
    console.print("m14: cpu0 sleep ticks={d}\n", .{slept});
    if (slept < sleep_ticks) return false;

    m14_preempt_a = 0;
    m14_preempt_b = 0;
    m14_preempt_a_observed = 0;
    m14_preempt_b_observed = 0;
    const preempt_base = sched.finishedCount();
    const preempt_start = sched.ticksOn(0);
    if (sched.createOn(0, "cpu0-preempt-a", m14PreemptA, m14_stacks[1][0..]) == null) return false;
    if (sched.createOn(0, "cpu0-preempt-b", m14PreemptB, m14_stacks[2][0..]) == null) return false;

    asm volatile ("sti");
    spins = 0;
    while (sched.finishedCount() < preempt_base + 2) {
        if (spins >= m14_max_spin) {
            asm volatile ("cli");
            console.write("m14: CPU 0 preemption timed out\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }
    asm volatile ("cli");

    const observed_a = @atomicLoad(u64, &m14_preempt_a_observed, .acquire) != 0;
    const observed_b = @atomicLoad(u64, &m14_preempt_b_observed, .acquire) != 0;
    const preempt_ticks = sched.ticksOn(0) - preempt_start;
    console.print("m14: cpu0 preempted={d} a={d} b={d} ticks={d}\n", .{
        @intFromBool(observed_a and observed_b),
        @atomicLoad(u64, &m14_preempt_a, .acquire),
        @atomicLoad(u64, &m14_preempt_b, .acquire),
        preempt_ticks,
    });
    return observed_a and observed_b and preempt_ticks > 0;
}

fn syncTimeOffsets() bool {
    if (time.currentSource() != .tsc) return true;
    if (!time.syncAll(sched.onlineMask())) return false;
    const info = time.info();
    console.print("time: sync cpus={d} skew={d} ns\n", .{ info.synced_cpus, info.sync_skew_ns });
    return true;
}

fn m15MonotonicCheck() bool {
    var previous = time.nowNs();
    var sample: usize = 0;
    while (sample < 1000) : (sample += 1) {
        const current = time.nowNs();
        if (current < previous) return false;
        previous = current;
    }
    return true;
}

/// Measure 20 CPU 0 ticks against the nanosecond clock. The caller checks the
/// result against the expected 200 ms window.
fn m15RateCheck() u64 {
    const start_ns = time.nowNs();
    const start_ticks = sched.ticksOn(0);

    asm volatile ("sti" ::: .{ .memory = true });
    while (sched.ticksOn(0) - start_ticks < m15_rate_ticks) {
        asm volatile ("hlt");
    }
    asm volatile ("cli");

    return time.nowNs() -% start_ns;
}

fn m15TimeProbe() callconv(.c) void {
    const index = cpu.currentIndex();
    _ = @atomicRmw(u64, &m15_barrier_ready, .Add, 1, .seq_cst);

    var spins: u64 = 0;
    while (@atomicLoad(u64, &m15_barrier_go, .acquire) == 0) {
        if (spins >= m15_max_spin) break;
        spins += 1;
        asm volatile ("pause");
    }

    const stamp = time.nowNs();
    m15_probe_ns[index] = stamp;

    var monotonic: u64 = 1;
    var previous = stamp;
    var sample: usize = 0;
    while (sample < 1000) : (sample += 1) {
        const current = time.nowNs();
        if (current < previous) {
            monotonic = 0;
            break;
        }
        previous = current;
    }
    m15_probe_monotonic[index] = monotonic;

    // Each CPU also proves that sleepMs is driven by its own timer and that
    // the resulting nanosecond delta matches the requested duration.
    const sleep_start = time.nowNs();
    sched.sleepMs(m15_sleep_ms);
    const sleep_end = time.nowNs();
    m15_probe_sleep_ns[index] = sleep_end -% sleep_start;

    _ = @atomicRmw(u64, &m15_probe_done, .Add, 1, .seq_cst);
    sched.exit();
}

fn m15SleepWorker() callconv(.c) void {
    const before_ns = time.nowNs();
    const before_ticks = sched.ticksOn(0);
    sched.sleepMs(m15_sleep_ms);
    m15_sleep_ns = time.nowNs() -% before_ns;
    m15_sleep_ticks = sched.ticksOn(0) -% before_ticks;
    _ = @atomicRmw(u64, &m15_sleep_done, .Add, 1, .seq_cst);
    sched.exit();
}

fn m15JoinStatusWorker() callconv(.c) void {
    _ = @atomicRmw(u64, &m15_join_done, .Add, 1, .seq_cst);
    sched.exitWith(42);
}

fn m15JoinAlreadyWorker() callconv(.c) void {
    sched.exitWith(7);
}

fn m15JoinBlockWorker() callconv(.c) void {
    sched.block();
    sched.exitWith(9);
}

fn m15PriorityWorker(priority: i32) void {
    const slot = @atomicRmw(u64, &m15_priority_count, .Add, 1, .seq_cst);
    if (slot < m15_priority_order.len) m15_priority_order[@intCast(slot)] = priority;
    sched.exit();
}

fn m15PriorityLow() callconv(.c) void {
    m15PriorityWorker(0);
}

fn m15PriorityNormal() callconv(.c) void {
    m15PriorityWorker(1);
}

fn m15PriorityHigh() callconv(.c) void {
    m15PriorityWorker(2);
}

fn m15CrossCpu() bool {
    const aps = smp.getStats().aps;
    if (aps == 0) {
        console.write("m15: cross-cpu skipped cpus=1\n");
        return true;
    }

    if (time.currentSource() == .tsc and !time.syncAll(sched.onlineMask())) {
        console.write("m15: TSC synchronization failed\n");
        return false;
    }
    const sync_info = time.info();
    console.print("m15: sync cpus={d} skew={d} ns\n", .{
        sync_info.synced_cpus, sync_info.sync_skew_ns,
    });

    m15_barrier_ready = 0;
    m15_barrier_go = 0;
    m15_probe_done = 0;
    m15_probe_ns = @splat(0);
    m15_probe_sleep_ns = @splat(0);
    m15_probe_monotonic = @splat(0);

    var ap: usize = 0;
    while (ap < aps) : (ap += 1) {
        const cpu_index: u32 = @intCast(ap + 1);
        if (sched.createOn(cpu_index, "m15-time", m15TimeProbe, m15_probe_stacks[ap][0..]) == null) {
            return false;
        }
    }

    asm volatile ("sti" ::: .{ .memory = true });
    var spins: u64 = 0;
    while (@atomicLoad(u64, &m15_barrier_ready, .acquire) < aps) {
        if (spins >= m15_max_spin) {
            asm volatile ("cli");
            console.write("m15: time probe barrier timed out\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }

    @atomicStore(u64, &m15_barrier_go, 1, .release);
    const bsp_stamp = time.nowNs();

    spins = 0;
    while (@atomicLoad(u64, &m15_probe_done, .acquire) < aps) {
        if (spins >= m15_max_spin) {
            asm volatile ("cli");
            console.write("m15: time probe timed out\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }
    asm volatile ("cli");

    var minimum = bsp_stamp;
    var maximum = bsp_stamp;
    var all_ok = true;
    var sleep_total: u64 = 0;

    ap = 0;
    while (ap < aps) : (ap += 1) {
        const index = ap + 1;
        if (@atomicLoad(u64, &m15_probe_monotonic[index], .acquire) == 0) all_ok = false;

        const stamp = m15_probe_ns[index];
        minimum = @min(minimum, stamp);
        maximum = @max(maximum, stamp);

        const slept = m15_probe_sleep_ns[index];
        sleep_total +%= slept;
        if (slept < m15_sleep_min_ns or slept > m15_sleep_max_ns) all_ok = false;
    }

    const skew = maximum - minimum;
    console.print("m15: cross-cpu skew_ns={d} sleep_ns={d} tolerance_ns={d}\n", .{
        skew, sleep_total / aps, m15_cross_cpu_tolerance_ns,
    });
    return all_ok and skew <= m15_cross_cpu_tolerance_ns;
}

fn m15DeadlineQueue() bool {
    m15_sleep_done = 0;
    m15_sleep_ns = 0;
    m15_sleep_ticks = 0;
    const pushes_before = sched.deadlinePushCount();
    const pops_before = sched.deadlinePopCount();

    if (sched.createOn(0, "m15-deadline", m15SleepWorker, m15_sleep_stack[0..]) == null) {
        return false;
    }

    asm volatile ("sti" ::: .{ .memory = true });
    var spins: u64 = 0;
    while (sched.deadlineDepthOn(0) == 0) {
        if (spins >= m15_max_spin) {
            asm volatile ("cli");
            console.write("m15: deadline queue never populated\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }

    spins = 0;
    while (@atomicLoad(u64, &m15_sleep_done, .acquire) == 0) {
        if (spins >= m15_max_spin) {
            asm volatile ("cli");
            console.write("m15: deadline sleeper timed out\n");
            return false;
        }
        spins += 1;
        asm volatile ("pause");
    }
    asm volatile ("cli");

    const pushes = sched.deadlinePushCount() - pushes_before;
    const pops = sched.deadlinePopCount() - pops_before;
    console.print("m15: deadlines pushes={d} pops={d} sleep_ns={d} ticks={d}\n", .{
        pushes, pops, m15_sleep_ns, m15_sleep_ticks,
    });

    return pushes > 0 and pops > 0 and
        m15_sleep_ns >= m15_sleep_min_ns and m15_sleep_ns <= m15_sleep_max_ns and
        m15_sleep_ticks >= 5;
}

fn m15Join() bool {
    asm volatile ("sti" ::: .{ .memory = true });

    m15_join_done = 0;
    const status_task = sched.createJoinableOn(0, "m15-join-status", m15JoinStatusWorker, m15_join_stacks[0][0..]) orelse {
        asm volatile ("cli");
        return false;
    };
    const joined = sched.join(status_task, 1000);

    const already_task = sched.createJoinableOn(0, "m15-join-already", m15JoinAlreadyWorker, m15_join_stacks[1][0..]) orelse {
        asm volatile ("cli");
        return false;
    };
    // Run the already-exited worker to completion before joining it, so the
    // join observes the `already_finished` outcome rather than blocking.
    sched.yield();
    const already = sched.join(already_task, 1000);
    const twice = sched.join(already_task, 0);

    const blocked_task = sched.createJoinableOn(0, "m15-join-block", m15JoinBlockWorker, m15_join_stacks[2][0..]) orelse {
        asm volatile ("cli");
        return false;
    };
    const timed = sched.join(blocked_task, m15_join_timeout_ms);
    if (timed.outcome != .timeout) {
        asm volatile ("cli");
        console.print("m15: join timeout path returned {s}\n", .{@tagName(timed.outcome)});
        return false;
    }

    if (!sched.wake(blocked_task)) {
        asm volatile ("cli");
        return false;
    }
    const retried = sched.join(blocked_task, 1000);
    asm volatile ("cli");

    console.print("m15: join joined={s}/{d} already={s}/{d} twice={s} timeout={s} retry={s}/{d}\n", .{
        @tagName(joined.outcome),  joined.status,
        @tagName(already.outcome), already.status,
        @tagName(twice.outcome),   @tagName(timed.outcome),
        @tagName(retried.outcome), retried.status,
    });

    return joined.outcome == .joined and joined.status == 42 and
        already.outcome == .already_finished and already.status == 7 and
        twice.outcome == .invalid and
        timed.outcome == .timeout and
        retried.outcome == .joined and retried.status == 9;
}

fn m15Priority() bool {
    m15_priority_count = 0;
    m15_priority_order = @splat(-1);

    if (sched.createWithPriorityOn(0, "m15-low", m15PriorityLow, m15_priority_stacks[0][0..], .low) == null) {
        return false;
    }
    if (sched.createWithPriorityOn(0, "m15-normal", m15PriorityNormal, m15_priority_stacks[1][0..], .normal) == null) {
        return false;
    }
    if (sched.createWithPriorityOn(0, "m15-high", m15PriorityHigh, m15_priority_stacks[2][0..], .high) == null) {
        return false;
    }

    asm volatile ("sti" ::: .{ .memory = true });
    sched.sleepMs(m15_sleep_ms);
    asm volatile ("cli");

    const order = m15_priority_order;
    const count = @atomicLoad(u64, &m15_priority_count, .acquire);
    console.print("m15: priority order={d},{d},{d} count={d}\n", .{
        order[0], order[1], order[2], count,
    });

    return count == 3 and order[0] == 2 and order[1] == 1 and order[2] == 0;
}

fn m15Fallback() bool {
    const original = time.currentSource();
    time.selectSourceForTest(.ticks);
    if (time.currentSource() != .ticks) return false;

    var previous = time.nowNs();
    var sample: usize = 0;
    while (sample < 1000) : (sample += 1) {
        const current = time.nowNs();
        if (current < previous) {
            time.selectSourceForTest(original);
            return false;
        }
        previous = current;
    }

    asm volatile ("sti" ::: .{ .memory = true });
    const start = time.nowNs();
    sched.sleepMs(m15_sleep_ms);
    const elapsed = time.nowNs() -% start;
    asm volatile ("cli");
    time.selectSourceForTest(original);

    console.print("m15: fallback source=ticks monotonic=1 sleep_ns={d}\n", .{elapsed});
    return elapsed >= m15_sleep_min_ns and elapsed <= m15_sleep_max_ns;
}

fn selftestM15() bool {
    const info = time.info();
    console.print("m15: tsc supported={d} invariant={d} calibrated={d} hz={d} source={s} reason={s}\n", .{
        @intFromBool(info.tsc_supported),
        @intFromBool(info.invariant_tsc),
        @intFromBool(info.tsc_calibrated),
        info.tsc_hz,
        @tagName(info.source),
        @tagName(info.fallback_reason),
    });
    if (info.source == .tsc and !info.tsc_calibrated) return false;

    if (!m15MonotonicCheck()) {
        console.write("m15: monotonic clock moved backwards\n");
        return false;
    }

    const elapsed = m15RateCheck();
    const expected = m15_rate_ticks * (1_000_000_000 / time.tick_hz);
    const tolerance = expected * m15_rate_tolerance_percent / 100;
    console.print("m15: rate_ns={d} expected_ns={d} tolerance_ns={d}\n", .{
        elapsed, expected, tolerance,
    });
    if (elapsed + tolerance < expected or elapsed > expected + tolerance) {
        console.write("m15: monotonic rate outside tolerance\n");
        return false;
    }

    if (!m15CrossCpu()) {
        console.write("m15: cross-CPU time check failed\n");
        return false;
    }
    if (!m15DeadlineQueue()) {
        console.write("m15: deadline queue check failed\n");
        return false;
    }
    if (!m15Join()) {
        console.write("m15: join check failed\n");
        return false;
    }
    if (!m15Priority()) {
        console.write("m15: priority check failed\n");
        return false;
    }
    if (!m15Fallback()) {
        console.write("m15: fallback clocksource check failed\n");
        return false;
    }

    asm volatile ("cli");
    return true;
}

fn m16Spawn(image: user.Image, stack_index: usize, mode: u64) ?*sched.Task {
    if (stack_index >= m16_kernel_stacks.len) return null;
    return sched.createUser(
        "m16-user",
        image.entry,
        m16_kernel_stacks[stack_index][0..],
        image.root,
        user.stack_top,
        mode,
        .{ .joinable = true },
    );
}

fn m16Join(task: *sched.Task) ?sched.JoinResult {
    const result = sched.join(task, m16_join_timeout_ms);
    switch (result.outcome) {
        .joined, .already_finished => return result,
        else => {
            console.print("m16: join outcome={s}\n", .{@tagName(result.outcome)});
            return null;
        },
    }
}

fn m16ReadQword(phys: u64, offset: u64) u64 {
    const ptr: *const volatile u64 = @ptrFromInt(vmm.hhdmOffset() + phys + offset);
    return ptr.*;
}

fn m16WriteQword(phys: u64, offset: u64, value: u64) void {
    const ptr: *volatile u64 = @ptrFromInt(vmm.hhdmOffset() + phys + offset);
    ptr.* = value;
}

/// M16: exercise ring 3, per-task address spaces, the int 0x80 gate, user
/// pointer validation, and timer preemption.
fn selftestM16() bool {
    const before = vmm.addressSpaceStats();

    // Basic syscall round trip: write, getpid, yield, sleepMs, exit(42).
    var image = user.create(false) orelse {
        console.write("m16: basic image load failed\n");
        return false;
    };
    var task = m16Spawn(image, 0, 0) orelse {
        user.destroy(image.root);
        console.write("m16: basic task create failed\n");
        return false;
    };
    var result = m16Join(task) orelse return false;
    console.print("m16: user exit status={d}\n", .{result.status});
    if (result.status != 42) return false;

    // A NULL fault must terminate only the user task.
    image = user.create(false) orelse return false;
    task = m16Spawn(image, 1, 1) orelse {
        user.destroy(image.root);
        return false;
    };
    result = m16Join(task) orelse return false;
    console.print("m16: user null fault status={d}\n", .{result.status});
    if (result.status != -15) return false;

    // Two live tasks map different physical pages at the same virtual address.
    var image_a = user.create(false) orelse return false;
    var image_b = user.create(false) orelse {
        user.destroy(image_a.root);
        return false;
    };
    m16WriteQword(image_a.data_phys, 0, 0xA1);
    m16WriteQword(image_b.data_phys, 0, 0xB2);
    const data_a = m16Spawn(image_a, 2, 2) orelse {
        user.destroy(image_a.root);
        user.destroy(image_b.root);
        return false;
    };
    const data_b = m16Spawn(image_b, 3, 2) orelse {
        user.destroy(image_a.root);
        user.destroy(image_b.root);
        return false;
    };
    const result_a = m16Join(data_a) orelse return false;
    const result_b = m16Join(data_b) orelse return false;
    console.print("m16: isolation data a={d} b={d}\n", .{ result_a.status, result_b.status });
    if (result_a.status != 0xA1 or result_b.status != 0xB2) return false;

    // The holder sleeps with an extra mapping live; the prober must fault and
    // die without affecting the holder.
    image_a = user.create(true) orelse return false;
    image_b = user.create(false) orelse {
        user.destroy(image_a.root);
        return false;
    };
    m16WriteQword(image_a.extra_phys.?, 0, 0x7E);
    const holder = m16Spawn(image_a, 4, 7) orelse {
        user.destroy(image_a.root);
        user.destroy(image_b.root);
        return false;
    };
    const prober = m16Spawn(image_b, 5, 5) orelse {
        user.destroy(image_a.root);
        user.destroy(image_b.root);
        return false;
    };
    const probe_result = m16Join(prober) orelse return false;
    const holder_result = m16Join(holder) orelse return false;
    console.print("m16: isolation extra holder={d} probe={d}\n", .{
        holder_result.status, probe_result.status,
    });
    if (holder_result.status != 0x7E or probe_result.status != -15) return false;

    // Two busy user tasks on one CPU must both make progress without yielding.
    image_a = user.create(false) orelse return false;
    image_b = user.create(false) orelse {
        user.destroy(image_a.root);
        return false;
    };
    m16WriteQword(image_a.data_phys, 0, 0);
    m16WriteQword(image_b.data_phys, 0, 0);
    const spin_a = m16Spawn(image_a, 6, 3) orelse {
        user.destroy(image_a.root);
        user.destroy(image_b.root);
        return false;
    };
    const spin_b = m16Spawn(image_b, 7, 3) orelse {
        user.destroy(image_a.root);
        user.destroy(image_b.root);
        return false;
    };

    const ticks_start = sched.ticksOn(0);
    var count_a: u64 = 0;
    var count_b: u64 = 0;
    var spins: u64 = 0;
    asm volatile ("sti");
    while (spins < m16_preempt_spin) : (spins += 1) {
        count_a = m16ReadQword(image_a.data_phys, 0);
        count_b = m16ReadQword(image_b.data_phys, 0);
        if (count_a > 0 and count_b > 0 and sched.ticksOn(0) != ticks_start) break;
        asm volatile ("pause");
    }
    asm volatile ("cli");
    const preempt_ticks = sched.ticksOn(0) - ticks_start;

    m16WriteQword(image_a.data_phys, 8, 1);
    m16WriteQword(image_b.data_phys, 8, 1);
    const spin_a_result = m16Join(spin_a) orelse return false;
    const spin_b_result = m16Join(spin_b) orelse return false;
    console.print("m16: preemption counters={d},{d} ticks={d}\n", .{
        count_a, count_b, preempt_ticks,
    });
    if (count_a == 0 or count_b == 0 or preempt_ticks == 0) return false;
    if (spin_a_result.status != 0 or spin_b_result.status != 0) return false;

    // Unmapped and non-canonical user pointers must be rejected by copyFromUser
    // and reported as an error without faulting the kernel.
    image = user.create(false) orelse return false;
    task = m16Spawn(image, 8, 4) orelse {
        user.destroy(image.root);
        return false;
    };
    result = m16Join(task) orelse return false;
    console.print("m16: user badptr status={d}\n", .{result.status});
    if (result.status != 0) return false;

    const after = vmm.addressSpaceStats();
    const created = after.created - before.created;
    const destroyed = after.destroyed - before.destroyed;
    console.print("m16: aspace created={d} destroyed={d}\n", .{ created, destroyed });
    return created == destroyed;
}

/// M17: general ELF loading, SysV argv/envp stack, W^X/NX, waits, reaping, and
/// generation-tagged process handles.
fn selftestM17() bool {
    // Warm the heap so the kernel-stack block is already in the free list when
    // the leak-free reclaim comparison below takes its snapshot.
    const warm = process.spawn(user.proc_elf, .{
        .name = "m17-warm",
        .argv = &m17_instant_argv,
    }) catch |err| {
        console.print("m17: warm spawn failed: {s}\n", .{@errorName(err)});
        return false;
    };
    var result = process.wait(warm, m17_wait_timeout_ms);
    if (result.outcome != .exited or result.status != 44) return false;
    var reaped = process.reap(warm);
    if (reaped.outcome != .reaped or reaped.status != 44) return false;

    const aspace_before = vmm.addressSpaceStats();
    const free_before = pmm.stats().free_pages;

    // argc/argv/envp construction: the program prints the strings it received.
    var handle = process.spawn(user.proc_elf, .{
        .name = "m17-argv",
        .argv = &m17_basic_argv,
        .envp = &m17_basic_env,
    }) catch |err| {
        console.print("m17: argv spawn failed: {s}\n", .{@errorName(err)});
        return false;
    };
    result = process.wait(handle, m17_wait_timeout_ms);
    if (result.outcome != .exited or result.status != 42) {
        console.print("m17: argv wait outcome={s} status={d}\n", .{
            @tagName(result.outcome), result.status,
        });
        return false;
    }
    console.print("m17: argv status={d} pid={d} gen={d}\n", .{
        result.status, handle.pid, handle.generation,
    });
    reaped = process.reap(handle);
    if (reaped.outcome != .reaped or reaped.status != 42) return false;

    // Two live processes: one exits immediately, one sleeps for 50 ms.
    const fast = process.spawn(user.proc_elf, .{
        .name = "m17-fast",
        .argv = &m17_basic_argv,
        .envp = &m17_basic_env,
    }) catch return false;
    const slow = process.spawn(user.proc_elf, .{
        .name = "m17-slow",
        .argv = &m17_sleep_argv,
    }) catch {
        _ = process.reap(fast);
        return false;
    };

    const fast_result = process.wait(fast, m17_wait_timeout_ms);
    const slow_result = process.wait(slow, m17_wait_timeout_ms);
    console.print("m17: concurrent statuses={d},{d}\n", .{
        fast_result.status, slow_result.status,
    });
    if (fast_result.outcome != .exited or fast_result.status != 42) return false;
    if (slow_result.outcome != .exited or slow_result.status != 43) return false;
    if (process.reap(fast).outcome != .reaped) return false;
    if (process.reap(slow).outcome != .reaped) return false;

    // A finite wait must time out while the process is still sleeping, then a
    // longer wait must observe the stored exit status.
    handle = process.spawn(user.proc_elf, .{
        .name = "m17-timeout",
        .argv = &m17_sleep_argv,
    }) catch return false;
    const timed = process.wait(handle, m17_short_timeout_ms);
    if (timed.outcome != .timeout) return false;
    const retried = process.wait(handle, m17_wait_timeout_ms);
    if (retried.outcome != .exited or retried.status != 43) return false;
    console.print("m17: wait timeout=timeout retry=exited/{d}\n", .{retried.status});
    reaped = process.reap(handle);
    console.print("m17: reap outcome={s} status={d}\n", .{
        @tagName(reaped.outcome), reaped.status,
    });
    if (reaped.outcome != .reaped or reaped.status != 43) return false;

    // A stale generation must not name the slot's next process, and the slot
    // must be reusable after reaping.
    const old_handle = handle;
    handle = process.spawn(user.proc_elf, .{
        .name = "m17-reuse",
        .argv = &m17_instant_argv,
    }) catch return false;
    const stale = process.wait(old_handle, 0);
    const generation_advanced = handle.generation != old_handle.generation;
    console.print("m17: generation advanced={d} stale={s}\n", .{
        @intFromBool(generation_advanced), @tagName(stale.outcome),
    });
    if (!generation_advanced or stale.outcome != .invalid) return false;
    const reuse_result = process.wait(handle, m17_wait_timeout_ms);
    if (reuse_result.outcome != .exited or reuse_result.status != 44) return false;
    reaped = process.reap(handle);
    if (reaped.outcome != .reaped or reaped.status != 44) return false;

    // NX enforcement: fetching from the RW+NX data page kills only the faulting
    // process; a sibling process still exits normally.
    const nx = process.spawn(user.proc_elf, .{
        .name = "m17-nx",
        .argv = &m17_nx_argv,
    }) catch return false;
    const nx_sibling = process.spawn(user.proc_elf, .{
        .name = "m17-nx-sibling",
        .argv = &m17_instant_argv,
    }) catch {
        _ = process.reap(nx);
        return false;
    };
    const nx_result = process.wait(nx, m17_wait_timeout_ms);
    const nx_sibling_result = process.wait(nx_sibling, m17_wait_timeout_ms);
    console.print("m17: nx fault status={d} sibling={d}\n", .{
        nx_result.status, nx_sibling_result.status,
    });
    if (nx_result.outcome != .exited or nx_result.status != -15) return false;
    if (nx_sibling_result.outcome != .exited or nx_sibling_result.status != 44) return false;
    if (process.reap(nx).outcome != .reaped) return false;
    if (process.reap(nx_sibling).outcome != .reaped) return false;

    // The page immediately below the stack is an unmapped guard page.
    const guard = process.spawn(user.proc_elf, .{
        .name = "m17-guard",
        .argv = &m17_guard_argv,
    }) catch return false;
    const guard_sibling = process.spawn(user.proc_elf, .{
        .name = "m17-guard-sibling",
        .argv = &m17_instant_argv,
    }) catch {
        _ = process.reap(guard);
        return false;
    };
    const guard_result = process.wait(guard, m17_wait_timeout_ms);
    const guard_sibling_result = process.wait(guard_sibling, m17_wait_timeout_ms);
    console.print("m17: guard fault status={d} sibling={d}\n", .{
        guard_result.status, guard_sibling_result.status,
    });
    if (guard_result.outcome != .exited or guard_result.status != -15) return false;
    if (guard_sibling_result.outcome != .exited or guard_sibling_result.status != 44) return false;
    if (process.reap(guard).outcome != .reaped) return false;
    if (process.reap(guard_sibling).outcome != .reaped) return false;

    // Malformed and unsupported images must be rejected without leaking pages,
    // address spaces, kernel stacks, or process slots.
    var rejected: usize = 0;
    if (process.spawn(m17_bad_elf[0..], .{ .name = "m17-bad" })) |_| {
        return false;
    } else |_| {
        rejected += 1;
    }

    if (user.proc_elf.len > m17_elf_copy.len) return false;
    @memcpy(m17_elf_copy[0..user.proc_elf.len], user.proc_elf);
    m17_elf_copy[18] = 3; // EM_386
    m17_elf_copy[19] = 0;
    if (process.spawn(m17_elf_copy[0..user.proc_elf.len], .{ .name = "m17-mach" })) |_| {
        return false;
    } else |_| {
        rejected += 1;
    }

    @memcpy(m17_elf_copy[0..user.proc_elf.len], user.proc_elf);
    const phoff = std.mem.readInt(u64, m17_elf_copy[32..40], .little);
    const second_vaddr: usize = @intCast(phoff + 56 + 16);
    std.mem.writeInt(u64, m17_elf_copy[second_vaddr..][0..8], 0x0040_0000, .little);
    if (process.spawn(m17_elf_copy[0..user.proc_elf.len], .{ .name = "m17-overlap" })) |_| {
        return false;
    } else |_| {
        rejected += 1;
    }

    var big_argv: [2][]const u8 = .{ "m17proc", m17_big_arg[0..] };
    if (process.spawn(user.proc_elf, .{
        .name = "m17-overflow",
        .argv = &big_argv,
    })) |_| {
        return false;
    } else |_| {
        rejected += 1;
    }

    console.print("m17: bad loads rejected={d}\n", .{rejected});
    if (rejected != 4) return false;

    const aspace_after = vmm.addressSpaceStats();
    const created = aspace_after.created - aspace_before.created;
    const destroyed = aspace_after.destroyed - aspace_before.destroyed;
    const free_after = pmm.stats().free_pages;
    const free_match = free_after == free_before;
    console.print("m17: reclaim aspaces created={d} destroyed={d} free_pages_match={d}\n", .{
        created, destroyed, @intFromBool(free_match),
    });
    if (created != destroyed or !free_match) return false;

    const stats = process.stats();
    console.print("m17: process table slots={d} live={d} spawned={d} reaped={d}\n", .{
        stats.slots, stats.live, stats.spawned, stats.reaped,
    });
    return stats.slots == 0 and stats.live == 0 and stats.spawned == stats.reaped;
}

/// M18: enumerate PCI, read and write the legacy virtio-blk disk, mount its
/// FAT16 filesystem through the VFS, read the Limine-module initramfs, and load
/// `INIT.ELF` from the filesystem into the M17 process model.
fn selftestM18() bool {
    const status = storage.init();
    console.print("m18: pci devices={d}\n", .{status.pci_devices});
    if (status.pci_devices == 0) return false;

    const device = pci.find(pci.virtio_vendor_id, pci.virtio_legacy_blk_device_id) orelse {
        console.write("m18: legacy virtio-blk not found\n");
        return false;
    };
    const bar = device.bar(0) orelse return false;
    console.print("m18: pci virtio-blk bus={d} slot={d} fn={d} io=0x{x} irq={d}\n", .{
        device.bus, device.device, device.function, bar.base, device.irq_line,
    });

    if (!status.virtio) {
        console.print("m18: virtio-blk init failed: {s}\n", .{
            @errorName(status.virtio_error orelse error.NotInitialized),
        });
        return false;
    }
    const info = status.blk orelse return false;
    console.print("m18: virtio-blk sectors={d} queue={d} io=0x{x} ring_pages={d}\n", .{
        info.capacity_sectors, info.queue_size, info.io_base, info.ring_pages,
    });
    if (info.capacity_sectors < 64 or info.queue_size == 0 or info.ring_pages == 0) return false;

    // Raw sector read: the generated image carries a FAT boot signature and a
    // known OEM name.
    var sector: [512]u8 = undefined;
    if (!virtio_blk.readSectors(0, &sector)) {
        console.write("m18: sector 0 read failed\n");
        return false;
    }
    if (sector[510] != 0x55 or sector[511] != 0xaa) return false;
    if (!std.mem.eql(u8, sector[3..11], "ZIGKERNL")) return false;
    console.print("m18: sector read lba=0 signature=ok oem={s}\n", .{sector[3..11]});

    // Raw sector write/read: use the final sector, which the image builder
    // leaves outside every allocated cluster.
    const last_sector = info.capacity_sectors - 1;
    var pattern: [512]u8 = undefined;
    for (&pattern, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    if (!virtio_blk.writeSectors(last_sector, &pattern)) {
        console.write("m18: sector write failed\n");
        return false;
    }
    var readback: [512]u8 = @splat(0);
    if (!virtio_blk.readSectors(last_sector, &readback)) return false;
    if (!std.mem.eql(u8, &pattern, &readback)) return false;
    console.print("m18: sector write/read lba={d} bytes=512 ok\n", .{last_sector});

    // FAT mount and direct reads. `storage.init` mounted the same volume at
    // `/`; the selftest exercises both the direct API and the VFS path.
    if (!status.fat) {
        console.print("m18: fat mount failed: {s}\n", .{
            @errorName(status.fat_error orelse error.NotFat),
        });
        return false;
    }
    const volume = storage.fatVolume() orelse return false;
    console.print("m18: fat type={s} clusters={d} root_cluster={d} cluster_bytes={d}\n", .{
        @tagName(volume.fat_type),
        volume.cluster_count,
        volume.root_cluster,
        fat.clusterBytes(volume),
    });

    var file = vfs.open("/HELLO.TXT") orelse {
        console.write("m18: vfs open HELLO.TXT failed\n");
        return false;
    };
    var hello: [64]u8 = undefined;
    const hello_len = file.readAll(&hello) orelse return false;
    if (!std.mem.eql(u8, hello[0..hello_len], "hello from fat\n")) return false;
    console.print("m18: vfs fat read file={s} bytes={d}\n", .{ "/HELLO.TXT", hello_len });

    file = vfs.open("/SUB/NESTED.TXT") orelse return false;
    var nested: [64]u8 = undefined;
    const nested_len = file.readAll(&nested) orelse return false;
    if (!std.mem.eql(u8, nested[0..nested_len], "nested file contents")) return false;
    console.print("m18: vfs nested read file={s} bytes={d}\n", .{ "/SUB/NESTED.TXT", nested_len });

    // A multi-cluster file through the VFS exercises cluster-chain following.
    file = vfs.open("/BIG.BIN") orelse return false;
    var big: [1300]u8 = undefined;
    const big_len = file.readAll(&big) orelse return false;
    if (big_len != 1300 or big[0] != 0 or big[1299] != @as(u8, @intCast(1299 % 251))) return false;
    console.print("m18: vfs cluster chain bytes={d} ok\n", .{big_len});

    // Limine-module initramfs, independent of the block device.
    if (!status.initramfs) {
        console.write("m18: initramfs module missing\n");
        return false;
    }
    const archive_data = storage.archive() orelse return false;
    const tar_entry = (tar.find(archive_data, "HELLO.TXT") catch null) orelse {
        console.write("m18: initramfs HELLO.TXT missing\n");
        return false;
    };
    var tar_buffer: [64]u8 = undefined;
    const tar_len = tar.readAll(archive_data, tar_entry, &tar_buffer) orelse return false;
    if (!std.mem.eql(u8, tar_buffer[0..tar_len], "hello from initramfs\n")) return false;
    var tar_file = vfs.open("/initramfs/HELLO.TXT") orelse return false;
    var tar_vfs_buffer: [64]u8 = undefined;
    const tar_vfs_len = tar_file.readAll(&tar_vfs_buffer) orelse return false;
    if (!std.mem.eql(u8, tar_vfs_buffer[0..tar_vfs_len], "hello from initramfs\n")) return false;
    console.print("m18: initramfs bytes={d} file_bytes={d}\n", .{
        archive_data.len, tar_vfs_len,
    });

    // Load and run the on-disk `INIT.ELF` through the M17 process model.
    const init_entry = (fat.find(volume, "INIT.ELF") catch null) orelse {
        console.write("m18: INIT.ELF missing\n");
        return false;
    };
    const init_size: usize = @intCast(init_entry.size);
    if (init_size == 0) return false;
    const init_bytes = heap.alloc(init_size, 16) orelse return false;
    defer heap.free(init_bytes, init_size);
    if (fat.readAll(volume, init_entry, init_bytes[0..init_size]) == null) return false;

    const handle = process.spawn(init_bytes[0..init_size], .{
        .name = "m18-init",
        .argv = &m18_init_argv,
        .envp = &m18_init_env,
    }) catch |err| {
        console.print("m18: init spawn failed: {s}\n", .{@errorName(err)});
        return false;
    };
    const result = process.wait(handle, m18_wait_timeout_ms);
    const reaped = process.reap(handle);
    console.print("m18: init from fat status={d} reap={s} pid={d}\n", .{
        result.status, @tagName(reaped.outcome), handle.pid,
    });
    if (result.outcome != .exited or result.status != 42) return false;
    if (reaped.outcome != .reaped or reaped.status != 42) return false;

    const stats = process.stats();
    return stats.slots == 0 and stats.live == 0;
}

/// M19: bring up the legacy virtio-net device, resolve the gateway with ARP,
/// exchange an ICMP echo, exercise UDP loopback, and attempt a DNS query.
fn selftestM19() bool {
    const status = network.init();
    console.print("m19: pci devices={d}\n", .{status.pci_devices});
    if (!status.device) {
        if (status.init_error) |err| {
            console.print("m19: legacy virtio-net unavailable: {s}\n", .{@errorName(err)});
        } else {
            console.write("m19: legacy virtio-net not found\n");
        }
        return false;
    }

    const device = pci.find(pci.virtio_vendor_id, pci.virtio_legacy_net_device_id) orelse return false;
    const bar = device.bar(0) orelse return false;
    const info = status.info orelse return false;

    var mac_buffer: [18]u8 = undefined;
    const mac_text = net.macString(&mac_buffer, info.mac);
    console.print("m19: pci virtio-net bus={d} slot={d} fn={d} io=0x{x} irq={d}\n", .{
        device.bus, device.device, device.function, bar.base, device.irq_line,
    });
    console.print("m19: virtio-net mac={s} rxq={d} txq={d} io=0x{x} ring_pages={d}/{d}\n", .{
        mac_text,           info.rx_queue_size, info.tx_queue_size, info.io_base,
        info.rx_ring_pages, info.tx_ring_pages,
    });
    if (info.rx_queue_size == 0 or info.tx_queue_size == 0 or
        info.rx_ring_pages == 0 or info.tx_ring_pages == 0) return false;

    var ip_buffer: [16]u8 = undefined;
    var gateway_buffer: [16]u8 = undefined;
    var dns_buffer: [16]u8 = undefined;
    const ip_text = net.ipv4String(&ip_buffer, network.guest_ip);
    const gateway_text = net.ipv4String(&gateway_buffer, network.gateway_ip);
    const dns_text = net.ipv4String(&dns_buffer, network.dns_ip);
    console.print("m19: ipv4 address={s} gateway={s} dns={s}\n", .{
        ip_text, gateway_text, dns_text,
    });

    const gateway_mac = net.arpResolve(network.gateway_ip, m19_arp_timeout_ns) orelse {
        console.write("m19: arp gateway failed\n");
        return false;
    };
    var gateway_mac_buffer: [18]u8 = undefined;
    console.print("m19: arp gateway mac={s}\n", .{
        net.macString(&gateway_mac_buffer, gateway_mac),
    });

    if (!net.ping(network.gateway_ip, m19_ping_timeout_ns)) {
        console.write("m19: icmp gateway echo failed\n");
        return false;
    }
    console.print("m19: icmp echo reply gateway={s}\n", .{gateway_text});

    const loopback: net.Ipv4 = .{ 127, 0, 0, 1 };
    if (!net.ping(loopback, m19_udp_timeout_ns)) {
        console.write("m19: icmp loopback echo failed\n");
        return false;
    }
    console.print("m19: icmp loopback reply=1\n", .{});

    if (!net.udpBind(m19_udp_port)) {
        console.write("m19: udp bind failed\n");
        return false;
    }
    defer net.udpUnbind(m19_udp_port);

    const payload = "m19 loopback datagram";
    if (!net.udpSend(m19_udp_port, loopback, m19_udp_port, payload)) {
        console.write("m19: udp loopback send failed\n");
        return false;
    }
    var datagram_buffer: [64]u8 = undefined;
    const datagram = net.udpRecv(m19_udp_port, m19_udp_timeout_ns, &datagram_buffer) orelse {
        console.write("m19: udp loopback receive failed\n");
        return false;
    };
    if (!std.mem.eql(u8, datagram_buffer[0..datagram.len], payload)) return false;
    console.print("m19: udp loopback port={d} bytes={d}\n", .{ m19_udp_port, datagram.len });

    const dns_result = net.dnsQueryTo(
        network.stub_dns_ip,
        network.stub_dns_port,
        m19_dns_name,
        m19_dns_timeout_ns,
    );
    if (dns_result) |address| {
        var answer_buffer: [16]u8 = undefined;
        console.print("m19: dns query name={s} status=ok address={s}\n", .{
            m19_dns_name, net.ipv4String(&answer_buffer, address),
        });
    } else |err| {
        console.print("m19: dns query name={s} status={s}\n", .{
            m19_dns_name, @errorName(err),
        });
        return false;
    }

    return true;
}

/// Verify that an unmap after the APs are running triggers a TLB shootdown that
/// every online CPU acknowledges.
fn selftestTlbShootdown() bool {
    if (smp.getStats().aps == 0) return true;

    const before = sched.tlbShootdownCount();
    const phys = pmm.allocPage() orelse return false;
    defer _ = pmm.freePage(phys);

    const virt: u64 = 0xffff_ffff_c000_0000;
    if (vmm.translate(virt) != null) return false;
    if (!vmm.mapPage(virt, phys, vmm.kernel_rw)) return false;
    if (!vmm.unmapPage(virt)) return false;

    const after = sched.tlbShootdownCount();
    console.print("tlb: shootdowns={d}\n", .{after - before});
    return after > before;
}

/// Check that nested IRQ-safe lock acquisitions save and restore interrupt
/// state independently.
fn selftestLockGuards() bool {
    var outer: sync.IrqSpinLock = .{};
    var inner: sync.IrqSpinLock = .{};

    const original = sync.irqSave();
    asm volatile ("sti");

    const first = outer.acquire();
    const second = inner.acquire();
    const disabled_while_held = (sync.irqSave() & (@as(u64, 1) << 9)) == 0;
    second.release();
    first.release();
    const restored_after_release = (sync.irqSave() & (@as(u64, 1) << 9)) != 0;

    asm volatile ("cli");
    sync.irqRestore(original);
    return disabled_while_held and restored_after_release;
}

fn stopTimer() void {
    asm volatile ("cli");
    pic.mask(0);
    lapic.stopTimer();
    sched.stop();
}

fn rangesOverlap(a: [*]u8, a_len: usize, b: [*]u8, b_len: usize) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    return a_start < b_start + b_len and b_start < a_start + a_len;
}
