//! 8253/8254 Programmable Interval Timer, channel 0.
//!
//! The PIT is configured as a rate generator on IRQ0. The PIC line is left
//! masked until the caller explicitly unmasks it.

const port = @import("port.zig");

const base_frequency: u32 = 1_193_182;
const channel0: u16 = 0x40;
const channel2: u16 = 0x42;
const command: u16 = 0x43;
const status_port: u16 = 0x61;

pub fn init(hz: u32) void {
    if (hz == 0) return;

    var divisor = base_frequency / hz;
    if (divisor == 0) divisor = 1;
    if (divisor > 0xffff) divisor = 0xffff;

    // Channel 0, lobyte/hibyte, mode 3 (square wave), binary.
    port.outb(command, 0x36);
    port.outb(channel0, @truncate(divisor));
    port.outb(channel0, @truncate(divisor >> 8));
}

/// Block for `ms` milliseconds using PIT channel 2 in one-shot mode. Channel 2
/// is independent of the channel 0 timer, so this works before IRQ0 is enabled
/// and is used to calibrate the LAPIC timer. The speaker output stays off and
/// the previous port 0x61 state is restored. Returns false if the PIT does not
/// reach terminal count within a generous spin limit.
pub fn delayBlockingMs(ms: u16) bool {
    if (ms == 0) return true;

    const ticks = (@as(u64, base_frequency) * ms) / 1000;
    if (ticks == 0 or ticks > 0xffff) return false;
    const divisor: u16 = @intCast(ticks);

    const saved = port.inb(status_port);
    // Gate high, speaker data off.
    port.outb(status_port, (saved & ~@as(u8, 0x02)) | 0x01);

    // Channel 2, lobyte/hibyte, mode 0 (interrupt on terminal count), binary.
    port.outb(command, 0xb0);
    port.outb(channel2, @truncate(divisor));
    port.outb(channel2, @truncate(divisor >> 8));

    var spins: u64 = 0;
    var reached = false;
    while (spins < 200_000_000) : (spins += 1) {
        if ((port.inb(status_port) & 0x20) != 0) {
            reached = true;
            break;
        }
        asm volatile ("pause");
    }

    port.outb(status_port, saved);
    return reached;
}
