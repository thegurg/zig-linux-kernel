//! 8259 PIC bring-up. We do not use the legacy PIC for interrupts, but
//! firmware may leave it unmasked or mapped over the CPU exception vectors.
//! Remap it out of the way and mask every line until a real interrupt
//! controller (APIC) is brought up.

const port = @import("port.zig");

const master_command: u16 = 0x20;
const master_data: u16 = 0x21;
const slave_command: u16 = 0xa0;
const slave_data: u16 = 0xa1;

pub fn remap(master_offset: u8, slave_offset: u8) void {
    // ICW1: begin initialisation, expect ICW4.
    port.outb(master_command, 0x11);
    port.ioWait();
    port.outb(slave_command, 0x11);
    port.ioWait();

    // ICW2: vector offsets.
    port.outb(master_data, master_offset);
    port.ioWait();
    port.outb(slave_data, slave_offset);
    port.ioWait();

    // ICW3: slave is cascaded through master IRQ2.
    port.outb(master_data, 0x04);
    port.ioWait();
    port.outb(slave_data, 0x02);
    port.ioWait();

    // ICW4: 8086/88 mode.
    port.outb(master_data, 0x01);
    port.ioWait();
    port.outb(slave_data, 0x01);
    port.ioWait();

    maskAll();
}

pub fn maskAll() void {
    port.outb(master_data, 0xff);
    port.outb(slave_data, 0xff);
}
