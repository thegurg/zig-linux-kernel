//! Interrupt Descriptor Table, CPU exception handling and IRQ entry points.
//!
//! The 32 CPU exception stubs and 16 IRQ stubs live in `interrupts.S`. Each
//! stub normalises the frame (pushing a synthetic error code when the CPU does
//! not) and jumps to a common entry that saves registers, calls
//! `isr_dispatch`, and `iretq`s back. IRQ0 feeds the scheduler.

const std = @import("std");
const console = @import("../../console.zig");
const sched = @import("../../sched.zig");
const gdt = @import("gdt.zig");
const pic = @import("pic.zig");
const qemu = @import("qemu.zig");

const gate_count = 256;

var idt: [gate_count][16]u8 align(16) = @splat(@splat(0));

var idtr: [10]u8 align(8) = @splat(0);

/// Addresses of the 32 exception and 16 IRQ stubs, exported by
/// `interrupts.S` in .rodata.
extern const isr_stub_table: [32]u64;
extern const irq_stub_table: [16]u64;

/// Stack frame as laid out by the CPU plus the two values our stubs push.
/// In long mode the CPU pushes a full five-qword frame (RIP, CS, RFLAGS, RSP,
/// SS) even for same-privilege interrupts.
const Frame = extern struct {
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const names = [32][]const u8{
    "#DE divide error",
    "#DB debug",
    "NMI",
    "#BP breakpoint",
    "#OF overflow",
    "#BR bound range",
    "#UD invalid opcode",
    "#NM device not available",
    "#DF double fault",
    "coprocessor segment overrun",
    "#TS invalid TSS",
    "#NP segment not present",
    "#SS stack-segment fault",
    "#GP general protection fault",
    "#PF page fault",
    "reserved",
    "#MF x87 floating-point",
    "#AC alignment check",
    "#MC machine check",
    "#XM SIMD floating-point",
    "#VE virtualization",
    "#CP control protection",
    "reserved",
    "reserved",
    "reserved",
    "reserved",
    "reserved",
    "reserved",
    "#HV hypervisor injection",
    "#VC VMM communication",
    "#SX security",
    "reserved",
};

pub fn init() void {
    inline for (0..32) |vector| {
        const ist: u8 = if (vector == 8) 1 else 0;
        setGate(vector, isr_stub_table[vector], ist);
    }
    inline for (0..16) |irq| {
        setGate(32 + irq, irq_stub_table[irq], 0);
    }

    idtr = @splat(0);
    std.mem.writeInt(u16, idtr[0..2], @sizeOf(@TypeOf(idt)) - 1, .little);
    std.mem.writeInt(u64, idtr[2..10], @intFromPtr(&idt), .little);

    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
        : .{ .memory = true });
}

fn setGate(vector: usize, handler: u64, ist: u8) void {
    const entry = &idt[vector];
    entry[0] = @truncate(handler);
    entry[1] = @truncate(handler >> 8);
    entry[2] = @truncate(gdt.kernel_code_selector);
    entry[3] = 0;
    entry[4] = ist & 0x7;
    entry[5] = 0x8e; // present, DPL0, 64-bit interrupt gate
    entry[6] = @truncate(handler >> 16);
    entry[7] = @truncate(handler >> 24);
    entry[8] = @truncate(handler >> 32);
    entry[9] = @truncate(handler >> 40);
    entry[10] = @truncate(handler >> 48);
    entry[11] = @truncate(handler >> 56);
    entry[12] = 0;
    entry[13] = 0;
    entry[14] = 0;
    entry[15] = 0;
}

export fn isr_dispatch(frame: *Frame, saved_rsp: u64) callconv(.c) u64 {
    const vector: u8 = @intCast(frame.vector & 0xff);

    if (vector >= 32 and vector < 48) {
        const irq = vector - 32;
        pic.sendEoi(irq);
        if (irq == 0) return sched.tick(saved_rsp);
        return saved_rsp;
    }

    const from_user = (frame.cs & 3) == 3;

    console.print("\n[exception] vector {d}: {s}\n", .{
        frame.vector,
        if (vector < names.len) names[vector] else "unknown",
    });
    console.print("  error=0x{x} rip=0x{x} cs=0x{x} rflags=0x{x}\n", .{
        frame.error_code, frame.rip, frame.cs, frame.rflags,
    });
    if (from_user) {
        console.print("  rsp=0x{x} ss=0x{x}\n", .{ frame.rsp, frame.ss });
    }

    if (vector == 14) {
        const cr2 = asm volatile ("mov %%cr2, %[value]"
            : [value] "=r" (-> u64),
        );
        console.print("  cr2=0x{x}\n", .{cr2});
    }

    if (vector == 3) {
        console.write("breakpoint handled, resuming\n");
        return saved_rsp;
    }

    console.write("fatal exception, halting\n");
    qemu.exit(qemu.EXIT_FAILURE);
}
