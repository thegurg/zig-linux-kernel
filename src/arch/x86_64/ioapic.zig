//! I/O APIC driver: MMIO access and redirection-table programming.
//!
//! The IOAPIC is reached through the HHDM after the 2 MiB chunk containing its
//! MMIO window is marked uncached. Only the registers M14 needs are used:
//! version/capability, ID and the redirection table. An IOAPIC has no EOI
//! register; fixed interrupts delivered through the IOAPIC are acknowledged
//! with a Local APIC EOI by the interrupt entry path.

const acpi = @import("../../acpi.zig");
const pmm = @import("../../memory/pmm.zig");
const vmm = @import("../../memory/vmm.zig");

const ioregsel: u32 = 0x00;
const iowin: u32 = 0x10;

const reg_id: u32 = 0x00;
const reg_version: u32 = 0x01;
const redirection_base: u32 = 0x10;

const mask_bit: u32 = 1 << 16;
const polarity_bit: u32 = 1 << 13;
const trigger_bit: u32 = 1 << 15;

pub const max_controllers = acpi.max_ioapics;

pub const Controller = struct {
    id: u8 = 0,
    gsi_base: u32 = 0,
    phys: u64 = 0,
    version: u8 = 0,
    entries: u16 = 0,
    regs: ?[*]volatile u32 = null,
};

pub const Redirection = struct {
    low: u32,
    high: u32,
};

pub const IsaIrqResult = struct {
    irq: u8,
    gsi: u32,
    polarity: acpi.Polarity,
    trigger: acpi.Trigger,
    overridden: bool,
    low: u32,
    high: u32,
};

var controllers: [max_controllers]Controller = @splat(.{});
var controller_count: usize = 0;

/// Bring up every IOAPIC described by the MADT. Entries start masked so a
/// firmware route cannot fire before the kernel programs it. Returns false if
/// ACPI is unavailable or no IOAPIC could be mapped.
pub fn init() bool {
    controller_count = 0;
    if (!acpi.isReady()) return false;

    const info = acpi.getInfo();
    var index: usize = 0;
    while (index < info.ioapic_count) : (index += 1) {
        const source = info.ioapics[index];
        if (source.address == 0) continue;
        if (!mapWindow(source.address)) continue;

        const phys: u64 = source.address;
        const virt = vmm.hhdmOffset() + phys;
        const regs: [*]volatile u32 = @ptrFromInt(virt);

        const version = readRegister(regs, reg_version);
        const controller = &controllers[controller_count];
        controller.* = .{
            .id = @truncate(readRegister(regs, reg_id) >> 24),
            .gsi_base = source.gsi_base,
            .phys = phys,
            .version = @truncate(version),
            .entries = @truncate(((version >> 16) & 0xff) + 1),
            .regs = regs,
        };

        // Mask every pin. A zero vector with the mask bit set is inert.
        var pin: u32 = 0;
        while (pin < controller.entries) : (pin += 1) {
            writeRedirectionRaw(controller, pin, mask_bit, 0);
        }

        controller_count += 1;
    }

    return controller_count != 0;
}

pub fn controllerCount() usize {
    return controller_count;
}

pub fn controllerAt(index: usize) ?*const Controller {
    if (index >= controller_count) return null;
    return &controllers[index];
}

/// Program a redirection entry. `masked` leaves the pin masked after the write
/// so callers can inspect or stage a route before enabling it.
pub fn program(
    gsi: u32,
    vector: u8,
    destination: u32,
    polarity: acpi.Polarity,
    trigger: acpi.Trigger,
    masked: bool,
) bool {
    const controller = findController(gsi) orelse return false;
    const pin = gsi - controller.gsi_base;

    var low: u32 = @as(u32, vector);
    if (polarity == .active_low) low |= polarity_bit;
    if (trigger == .level) low |= trigger_bit;
    low |= mask_bit;
    const high: u32 = (destination & 0xff) << 24;

    // Update high first with the entry masked, then publish the low word. This
    // avoids a transient mixed destination/vector pair.
    writeRedirectionRaw(controller, pin, low, high);
    if (!masked) {
        low &= ~mask_bit;
        writeRedirectionRaw(controller, pin, low, high);
    }
    return true;
}

/// Resolve ISA IRQ through the MADT ISO and program the resulting GSI. The
/// caller must use a vector whose handler sends a Local APIC EOI; an
/// IOAPIC-delivered interrupt must not send a PIC EOI.
pub fn routeIsaIrq(irq: u8, vector: u8, destination: u32) ?IsaIrqResult {
    const route = acpi.isaIrqRoute(irq) orelse return null;
    if (!program(route.gsi, vector, destination, route.polarity, route.trigger, false)) {
        return null;
    }
    const entry = readRedirection(route.gsi) orelse return null;
    return .{
        .irq = irq,
        .gsi = route.gsi,
        .polarity = route.polarity,
        .trigger = route.trigger,
        .overridden = route.overridden,
        .low = entry.low,
        .high = entry.high,
    };
}

pub fn readRedirection(gsi: u32) ?Redirection {
    const controller = findController(gsi) orelse return null;
    const pin = gsi - controller.gsi_base;
    return .{
        .low = readRegister(controller.regs.?, redirection_base + 2 * pin),
        .high = readRegister(controller.regs.?, redirection_base + 2 * pin + 1),
    };
}

pub fn setMasked(gsi: u32, masked: bool) bool {
    const controller = findController(gsi) orelse return false;
    const pin = gsi - controller.gsi_base;
    const low_reg = redirection_base + 2 * pin;

    var low = readRegister(controller.regs.?, low_reg);
    if (masked) {
        low |= mask_bit;
    } else {
        low &= ~mask_bit;
    }
    writeRegister(controller.regs.?, low_reg, low);
    return true;
}

pub fn isMasked(gsi: u32) ?bool {
    const entry = readRedirection(gsi) orelse return null;
    return (entry.low & mask_bit) != 0;
}

fn findController(gsi: u32) ?*Controller {
    var index: usize = 0;
    while (index < controller_count) : (index += 1) {
        const controller = &controllers[index];
        if (gsi >= controller.gsi_base and gsi < controller.gsi_base + controller.entries) {
            return controller;
        }
    }
    return null;
}

fn mapWindow(phys: u32) bool {
    if (!rangeValid(phys)) return false;
    if (!vmm.markUncached(phys, vmm.page_size)) return false;

    // markUncached edits the HHDM PDE in place; invalidate the translation so
    // the first register access cannot use a cached mapping.
    const virt = vmm.hhdmOffset() + phys;
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (virt),
        : .{ .memory = true });
    return true;
}

fn rangeValid(phys: u64) bool {
    return phys != 0 and phys < pmm.max_physical_address;
}

fn writeRedirectionRaw(controller: *const Controller, pin: u32, low: u32, high: u32) void {
    const regs = controller.regs orelse return;
    const low_reg = redirection_base + 2 * pin;
    writeRegister(regs, low_reg, low);
    writeRegister(regs, low_reg + 1, high);
}

fn readRegister(regs: [*]volatile u32, reg: u32) u32 {
    regs[ioregsel / 4] = reg;
    return regs[iowin / 4];
}

fn writeRegister(regs: [*]volatile u32, reg: u32, value: u32) void {
    regs[ioregsel / 4] = reg;
    regs[iowin / 4] = value;
}
