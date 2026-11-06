//! zig-kernel: entry point and early boot sequence.
//!
//! Limine jumps to `_start` with the Limine stack and interrupts disabled.
//! `_start` switches to our own kernel stack and calls `kmain`, which brings up
//! the GDT/TSS, IDT and PIC before doing anything that may fault. M2-M9 then
//! program the PIT, create tasks and may hand control to the scheduler.

const std = @import("std");
const build_options = @import("build_options");

const limine = @import("limine.zig");
const console = @import("console.zig");
const pmm = @import("memory/pmm.zig");
const vmm = @import("memory/vmm.zig");
const heap = @import("memory/heap.zig");
const serial = @import("arch/x86_64/serial.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pic = @import("arch/x86_64/pic.zig");
const pit = @import("arch/x86_64/pit.zig");
const sched = @import("sched.zig");
const qemu = @import("arch/x86_64/qemu.zig");

pub const version = "0.12.0-m9";

const timer_hz: u32 = 100;
const timer_test_ticks: u64 = 30;
const sleep_ticks: u64 = 5;
const task_stack_size = 16 * 1024;

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
    console.write("\nM1c complete. Paging and kernel heap are live.\n");

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

        stopTimer();
        serial.write("selftest: triggering int3\n");
        asm volatile ("int3");
        serial.write("selftest: returned from int3\n");
        serial.write("selftest: M9 checks passed, exiting QEMU\n");
        qemu.exit(qemu.EXIT_SUCCESS);
    }

    sched.init();
    pit.init(timer_hz);
    pic.unmask(0);
    console.print("timer: PIT {d} Hz, interrupts enabled\n", .{timer_hz});
    console.write("scheduler: boot task exiting to idle\n");
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

    sched.init();
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

fn stopTimer() void {
    asm volatile ("cli");
    pic.mask(0);
    sched.stop();
}

fn rangesOverlap(a: [*]u8, a_len: usize, b: [*]u8, b_len: usize) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    return a_start < b_start + b_len and b_start < a_start + a_len;
}
