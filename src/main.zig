//! zig-kernel: entry point and early boot sequence.
//!
//! Limine jumps to `_start` with the Limine stack and interrupts disabled.
//! `_start` switches to our own kernel stack and calls `kmain`, which brings up
//! the GDT/TSS, IDT and PIC before doing anything that may fault.

const std = @import("std");
const build_options = @import("build_options");

const limine = @import("limine.zig");
const console = @import("console.zig");
const serial = @import("arch/x86_64/serial.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pic = @import("arch/x86_64/pic.zig");
const qemu = @import("arch/x86_64/qemu.zig");

pub const version = "0.2.0-m1a";

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

    console.init();
    banner();
    reportBootInfo();
    console.write("\nM1a complete. GDT/TSS and IDT are live.\n");

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
        serial.write("selftest: triggering int3\n");
        asm volatile ("int3");
        serial.write("selftest: returned from int3\n");
        serial.write("selftest: M1a checks passed, exiting QEMU\n");
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
}

fn halt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}
