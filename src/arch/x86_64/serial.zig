//! COM1 serial port (16550 UART). Used for early boot logs and QEMU tests.

const port = @import("port.zig");
const sync = @import("../../sync.zig");

const com1: u16 = 0x3f8;

/// Serializes complete message writes across CPUs. `writeByte` itself stays
/// unlocked; only the public whole-message entry points take the lock.
var lock: sync.IrqSpinLock = .{};

pub fn init() void {
    port.outb(com1 + 1, 0x00); // disable interrupts
    port.outb(com1 + 3, 0x80); // enable DLAB
    port.outb(com1 + 0, 0x01); // divisor low: 115200 baud
    port.outb(com1 + 1, 0x00); // divisor high
    port.outb(com1 + 3, 0x03); // 8 bits, no parity, one stop bit
    port.outb(com1 + 2, 0xc7); // enable + clear FIFO
    port.outb(com1 + 4, 0x03); // DTR + RTS
}

fn transmitEmpty() bool {
    return (port.inb(com1 + 5) & 0x20) != 0;
}

pub fn writeByte(byte: u8) void {
    var spin: usize = 0;
    while (!transmitEmpty()) : (spin += 1) {
        if (spin > 1_000_000) return; // never hang the kernel on a dead UART
    }
    port.outb(com1, byte);
}

pub fn write(bytes: []const u8) void {
    const guard = lock.acquire();
    defer guard.release();
    for (bytes) |byte| {
        if (byte == '\n') writeByte('\r');
        writeByte(byte);
    }
}

pub fn writeHex(value: u64) void {
    const guard = lock.acquire();
    defer guard.release();
    const digits = "0123456789abcdef";
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(value >> shift);
        if (nibble != 0 or started or shift == 0) {
            started = true;
            writeByte(digits[nibble]);
        }
        if (shift == 0) break;
        shift -= 4;
    }
}
