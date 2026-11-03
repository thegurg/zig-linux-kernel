//! zig-kernel: entry point and early boot sequence.
//!
//! Limine jumps to `_start` with the Limine stack and interrupts disabled.
//! `_start` switches to our own kernel stack and calls `kmain`, which brings up
//! the GDT/TSS, IDT and PIC before doing anything that may fault.

const std = @import("std");
const build_options = @import("build_options");

const limine = @import("limine.zig");
const console = @import("console.zig");
const pmm = @import("memory/pmm.zig");
const serial = @import("arch/x86_64/serial.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pic = @import("arch/x86_64/pic.zig");
const qemu = @import("arch/x86_64/qemu.zig");

pub const version = "0.3.0-m1b";

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

    console.init();
    banner();
    reportBootInfo();
    console.write("\nM1b complete. Physical page allocator online.\n");

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

        serial.write("selftest: triggering int3\n");
        asm volatile ("int3");
        serial.write("selftest: returned from int3\n");
        serial.write("selftest: M1b checks passed, exiting QEMU\n");
        qemu.exit(qemu.EXIT_SUCCESS);
    }

    halt();
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

    if (limine.framebuffer()) |fb| {
        console.print("framebuffer: {d}x{d}, {d} bpp, pitch {d} bytes\n", .{
            fb.width, fb.height, fb.bpp, fb.pitch,
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

fn halt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}
