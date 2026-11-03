//! 8259 PIC bring-up. Firmware may leave the PIC unmasked or mapped over CPU
//! exception vectors, so it is remapped to vectors 32-47 and starts fully
//! masked. M2 unmasks only IRQ0 for the PIT; the rest wait for drivers/APIC.

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

pub fn mask(irq: u8) void {
    if (irq >= 16) return;
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(irq & 7));

    if (irq < 8) {
        port.outb(master_data, port.inb(master_data) | bit);
    } else {
        port.outb(slave_data, port.inb(slave_data) | bit);
    }
}

pub fn unmask(irq: u8) void {
    if (irq >= 16) return;
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(irq & 7));

    if (irq < 8) {
        port.outb(master_data, port.inb(master_data) & ~bit);
    } else {
        port.outb(slave_data, port.inb(slave_data) & ~bit);
        // IRQs 8-15 arrive through the master's cascade line (IRQ2).
        const cascade: u8 = @as(u8, 1) << 2;
        port.outb(master_data, port.inb(master_data) & ~cascade);
    }
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) port.outb(slave_command, 0x20);
    port.outb(master_command, 0x20);
}
