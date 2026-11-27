//! Legacy PCI configuration-space access and enumeration.
//!
//! M18 uses the `0xCF8`/`0xCFC` mechanism so enumeration works before any
//! ECAM/MCFG support exists. Every access is a 32-bit dword aligned to four
//! bytes; byte and word reads extract the requested field from that dword.
//!
//! Enumeration is intentionally BSP-only and runs once during boot. Firmware
//! (OVMF) has already assigned BARs, so the driver decodes them but does not
//! relocate anything.

const port = @import("../arch/x86_64/port.zig");

pub const config_address_port: u16 = 0xcf8;
pub const config_data_port: u16 = 0xcfc;

pub const max_devices = 64;
pub const max_bars = 6;

pub const Bar = struct {
    raw: u64 = 0,
    base: u64 = 0,
    is_io: bool = false,
    is_64: bool = false,
};

pub const Device = struct {
    bus: u8,
    device: u5,
    function: u3,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    header_type: u8,
    irq_line: u8,
    bars: [max_bars]Bar = @splat(.{}),

    pub fn address(self: Device) u32 {
        return configAddress(self.bus, self.device, self.function, 0);
    }

    pub fn isVirtio(self: Device) bool {
        return self.vendor_id == virtio_vendor_id;
    }

    pub fn bar(self: Device, index: usize) ?Bar {
        if (index >= max_bars) return null;
        return self.bars[index];
    }
};

pub const virtio_vendor_id: u16 = 0x1af4;
pub const virtio_legacy_blk_device_id: u16 = 0x1001;
pub const virtio_modern_blk_device_id: u16 = 0x1042;
pub const virtio_legacy_net_device_id: u16 = 0x1000;
pub const virtio_modern_net_device_id: u16 = 0x1041;

const command_io_space: u16 = 1 << 0;
const command_memory_space: u16 = 1 << 1;
const command_bus_master: u16 = 1 << 2;
const command_interrupt_disable: u16 = 1 << 10;

var devices: [max_devices]Device = undefined;
var device_count: usize = 0;

pub fn configAddress(bus: u8, device: u5, function: u3, offset: u8) u32 {
    return 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8) |
        (@as(u32, offset) & 0xfc);
}

pub fn read32(bus: u8, device: u5, function: u3, offset: u8) u32 {
    port.outl(config_address_port, configAddress(bus, device, function, offset));
    return port.inl(config_data_port);
}

pub fn read16(bus: u8, device: u5, function: u3, offset: u8) u16 {
    const dword = read32(bus, device, function, offset & 0xfc);
    return @truncate(dword >> @intCast((offset & 2) * 8));
}

pub fn read8(bus: u8, device: u5, function: u3, offset: u8) u8 {
    const dword = read32(bus, device, function, offset & 0xfc);
    return @truncate(dword >> @intCast((offset & 3) * 8));
}

pub fn write32(bus: u8, device: u5, function: u3, offset: u8, value: u32) void {
    port.outl(config_address_port, configAddress(bus, device, function, offset));
    port.outl(config_data_port, value);
}

pub fn write16(bus: u8, device: u5, function: u3, offset: u8, value: u16) void {
    const aligned = offset & 0xfc;
    const dword = read32(bus, device, function, aligned);
    const shift: u5 = @intCast((offset & 2) * 8);
    const mask: u32 = @as(u32, 0xffff) << shift;
    write32(bus, device, function, aligned, (dword & ~mask) | (@as(u32, value) << shift));
}

/// Walk the PCI capability list and return the config offset of `cap_id`.
pub fn findCapability(device: Device, cap_id: u8) ?u8 {
    const status = read16(device.bus, device.device, device.function, 0x06);
    if ((status & (1 << 4)) == 0) return null;

    var offset: u8 = @truncate(read8(device.bus, device.device, device.function, 0x34) & 0xfc);
    var steps: usize = 0;
    while (offset != 0 and steps < 48) : (steps += 1) {
        const header = read32(device.bus, device.device, device.function, offset);
        const id: u8 = @truncate(header);
        if (id == cap_id) return offset;
        const next: u8 = @truncate(header >> 8);
        if (next == 0) return null;
        offset = next & 0xfc;
    }
    return null;
}

/// Enable the PCI command bits the driver needs. `interrupts == false` also sets
/// Interrupt Disable so a polling driver cannot take a stray INTx.
pub fn enable(device: Device, io: bool, mmio: bool, bus_master: bool, interrupts: bool) void {
    var command = read16(device.bus, device.device, device.function, 0x04);
    if (io) command |= command_io_space;
    if (mmio) command |= command_memory_space;
    if (bus_master) command |= command_bus_master;
    if (!interrupts) command |= command_interrupt_disable;
    write16(device.bus, device.device, device.function, 0x04, command);
}

pub fn init() usize {
    device_count = 0;
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            const vendor = read16(@intCast(bus), @intCast(slot), 0, 0x00);
            if (vendor == 0xffff) continue;

            add(@intCast(bus), @intCast(slot), 0, vendor);
            const header = read8(@intCast(bus), @intCast(slot), 0, 0x0e);
            if ((header & 0x80) == 0) continue;

            var function: u8 = 1;
            while (function < 8) : (function += 1) {
                const function_vendor = read16(@intCast(bus), @intCast(slot), @intCast(function), 0x00);
                if (function_vendor == 0xffff) continue;
                add(@intCast(bus), @intCast(slot), @intCast(function), function_vendor);
            }
        }
    }
    return device_count;
}

pub fn count() usize {
    return device_count;
}

pub fn at(index: usize) ?Device {
    if (index >= device_count) return null;
    return devices[index];
}

pub fn find(vendor_id: u16, device_id: u16) ?Device {
    for (devices[0..device_count]) |device| {
        if (device.vendor_id == vendor_id and device.device_id == device_id) return device;
    }
    return null;
}

pub fn findClass(class_code: u8, subclass: u8) ?Device {
    for (devices[0..device_count]) |device| {
        if (device.class_code == class_code and device.subclass == subclass) return device;
    }
    return null;
}

pub fn hasCapability(device: Device, cap_id: u8) bool {
    return findCapability(device, cap_id) != null;
}

fn add(bus: u8, slot: u5, function: u3, vendor_id: u16) void {
    if (device_count >= devices.len) return;

    const device_id = read16(bus, slot, function, 0x02);
    const class_dword = read32(bus, slot, function, 0x08);
    const header_type = read8(bus, slot, function, 0x0e);
    const irq_line = read8(bus, slot, function, 0x3c);

    var device = Device{
        .bus = bus,
        .device = slot,
        .function = function,
        .vendor_id = vendor_id,
        .device_id = device_id,
        .class_code = @truncate(class_dword >> 24),
        .subclass = @truncate(class_dword >> 16),
        .prog_if = @truncate(class_dword >> 8),
        .header_type = header_type,
        .irq_line = irq_line,
    };
    decodeBars(&device);
    devices[device_count] = device;
    device_count += 1;
}

fn decodeBars(device: *Device) void {
    var index: usize = 0;
    while (index < max_bars) : (index += 1) {
        const slot = index;
        const raw = read32(device.bus, device.device, device.function, @intCast(0x10 + index * 4));
        if (raw == 0) continue;

        var bar = Bar{ .raw = raw };
        if ((raw & 1) != 0) {
            bar.is_io = true;
            bar.base = raw & ~@as(u64, 0x3);
        } else {
            const kind = (raw >> 1) & 0x3;
            if (kind == 0x2 and index + 1 < max_bars) {
                const high = read32(device.bus, device.device, device.function, @intCast(0x10 + (index + 1) * 4));
                bar.raw = @as(u64, raw) | (@as(u64, high) << 32);
                bar.base = bar.raw & ~@as(u64, 0xf);
                bar.is_64 = true;
                index += 1;
            } else {
                bar.base = raw & ~@as(u64, 0xf);
            }
        }
        device.bars[slot] = bar;
    }
}
