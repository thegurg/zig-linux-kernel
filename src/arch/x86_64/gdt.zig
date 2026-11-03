//! Global Descriptor Table and 64-bit Task State Segment.
//!
//! Long mode barely uses segmentation, but a flat code/data GDT is still
//! required to reload the segment registers with our own descriptors, and the
//! TSS supplies the ring-0 stack pointer (RSP0) plus an IST stack for faults
//! that must not trust the current stack (notably #DF).

const std = @import("std");

pub const kernel_stack_size = 64 * 1024;
const double_fault_stack_size = 8 * 1024;

/// Stack used by `_start` before `kmain` runs. Exported so the entry stub can
/// reference the symbol from inline assembly.
pub export var kernel_stack: [kernel_stack_size]u8 align(16) = undefined;
var double_fault_stack: [double_fault_stack_size]u8 align(16) = undefined;

pub const kernel_code_selector: u16 = 0x08;
pub const kernel_data_selector: u16 = 0x10;
pub const tss_selector: u16 = 0x18;

/// Standard 64-bit TSS: exactly 104 bytes, with several fields at unaligned
/// offsets (RSP0 sits at byte 4), so it is built byte-wise instead of with an
/// `extern struct`.
const tss_size = 104;
const tss_rsp0_offset = 0x04;
const tss_ist1_offset = 0x24;
const tss_iomap_offset = 0x66;

var tss: [tss_size]u8 align(16) = @splat(0);

var gdt: [5]u64 align(16) = .{
    0x0000000000000000, // null
    0x00af9a000000ffff, // 64-bit kernel code: present, DPL0, code, L=1
    0x00cf92000000ffff, // kernel data: present, DPL0, writable, D/B=1
    0x0000000000000000, // TSS low, filled in by init()
    0x0000000000000000, // TSS high
};

var gdtr: [10]u8 align(8) = @splat(0);

pub fn kernelStackTop() u64 {
    return @intFromPtr(&kernel_stack) + kernel_stack_size;
}

fn doubleFaultStackTop() u64 {
    return @intFromPtr(&double_fault_stack) + double_fault_stack_size;
}

pub fn init() void {
    tssWrite64(tss_rsp0_offset, kernelStackTop());
    tssWrite64(tss_ist1_offset, doubleFaultStackTop()); // IST1 for #DF
    tssWrite16(tss_iomap_offset, 0xffff); // no I/O permission bitmap

    const base = @intFromPtr(&tss);
    const limit: u32 = tss_size - 1;
    gdt[3] = tssDescriptorLow(base, limit);
    gdt[4] = base >> 32;

    gdtr = @splat(0);
    std.mem.writeInt(u16, gdtr[0..2], @sizeOf(@TypeOf(gdt)) - 1, .little);
    std.mem.writeInt(u64, gdtr[2..10], @intFromPtr(&gdt), .little);

    load();
}

fn tssWrite64(comptime offset: usize, value: u64) void {
    std.mem.writeInt(u64, tss[offset..][0..8], value, .little);
}

fn tssWrite16(comptime offset: usize, value: u16) void {
    std.mem.writeInt(u16, tss[offset..][0..2], value, .little);
}

fn tssDescriptorLow(base: u64, limit: u32) u64 {
    return (@as(u64, limit) & 0xffff) |
        ((base & 0xffffff) << 16) |
        (@as(u64, 0x89) << 40) | // present, type = available 64-bit TSS
        ((@as(u64, limit >> 16) & 0xf) << 48) |
        (((base >> 24) & 0xff) << 56);
}

fn load() void {
    // Load the new GDT, reload CS through a far return, then reload the data
    // segment registers. The old SS stays cached and valid until then.
    asm volatile (
        \\lgdt (%[gdtr])
        \\pushq $0x08
        \\leaq 2f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\2:
        \\mov $0x10, %%ax
        \\mov %%ax, %%ss
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        :
        : [gdtr] "r" (&gdtr),
        : .{ .rax = true, .memory = true });

    asm volatile ("ltr %[selector]"
        :
        : [selector] "{ax}" (tss_selector),
        : .{ .memory = true });
}
