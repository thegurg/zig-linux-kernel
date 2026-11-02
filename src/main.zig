//! zig-kernel: entry point and M0 boot sequence.
//!
//! Limine jumps here with the ELF entry point set to `kmain`, a valid stack and
//! interrupts disabled. Everything the kernel needs to survive is brought up
//! explicitly from this point on.

const std = @import("std");
const build_options = @import("build_options");

const limine = @import("limine.zig");
const console = @import("console.zig");
const serial = @import("arch/x86_64/serial.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const qemu = @import("arch/x86_64/qemu.zig");

pub const version = "0.1.0-m0";

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

export fn kmain() callconv(.c) noreturn {
    asm volatile ("cli; cld");
    cpu.enableSse();

    serial.init();
    serial.write("\n");
    serial.write("zig-kernel: early boot\n");

    if (!limine.baseRevisionSupported()) {
        serial.write("zig-kernel: unsupported Limine base revision: ");
        serial.writeHex(limine.base_revision[2]);
        serial.write("\n");
        qemu.exit(qemu.EXIT_FAILURE);
    }

    console.init();
    banner();
    reportBootInfo();
    console.write("\nM0 complete. Kernel is alive.\n");

    if (build_options.exit_after_boot) {
        serial.write("selftest: M0 checks passed, exiting QEMU\n");
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
        if (entry.type == @intFromEnum(limine.MemmapEntryType.usable)) {
            usable_bytes += entry.length;
        }
    }
    console.print("memory map: {d} entries, {d} MiB usable\n", .{
        memmap.entry_count, usable_bytes / (1024 * 1024),
    });
}

fn halt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}
