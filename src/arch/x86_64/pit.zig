//! 8253/8254 Programmable Interval Timer, channel 0.
//!
//! The PIT is configured as a rate generator on IRQ0. The PIC line is left
//! masked until the caller explicitly unmasks it.

const port = @import("port.zig");

const base_frequency: u32 = 1_193_182;
const channel0: u16 = 0x40;
const command: u16 = 0x43;

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
