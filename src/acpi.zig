//! ACPI table discovery for the bootstrap CPU.
//!
//! M14 needs the Multiple APIC Description Table (MADT) to learn which local
//! APICs, I/O APICs and Interrupt Source Overrides (ISOs) the platform
//! provides. The RSDP is requested through Limine (base revision 3 returns it
//! as a physical address), so every table is read through the HHDM after
//! validating its signature, length and checksum.
//!
//! Only the MADT is interpreted. AML and the rest of the ACPI namespace remain
//! out of scope.

const std = @import("std");
const limine = @import("limine.zig");
const pmm = @import("memory/pmm.zig");
const vmm = @import("memory/vmm.zig");

/// ISA IRQ polarity and trigger mode after an Interrupt Source Override has
/// been resolved. Bus-default flags are mapped to the ISA defaults (active
/// high, edge triggered).
pub const Polarity = enum { active_high, active_low };
pub const Trigger = enum { edge, level };

pub const max_local_apics = 64;
pub const max_ioapics = 8;
pub const max_isos = 32;

/// A table larger than this is treated as corrupt rather than mapped blindly.
const max_table_length: u32 = 1024 * 1024;

pub const LocalApic = struct {
    id: u32 = 0,
    enabled: bool = false,
    x2apic: bool = false,
};

pub const IoApic = struct {
    id: u8 = 0,
    address: u32 = 0,
    gsi_base: u32 = 0,
};

pub const Iso = struct {
    bus: u8 = 0,
    source: u8 = 0,
    gsi: u32 = 0,
    polarity: Polarity = .active_high,
    trigger: Trigger = .edge,
};

pub const Info = struct {
    revision: u8 = 0,
    local_apic_address: u32 = 0,
    lapic_address_override: ?u64 = null,
    local_apic_count: u8 = 0,
    enabled_local_apics: u8 = 0,
    local_apics: [max_local_apics]LocalApic = @splat(.{}),
    ioapic_count: u8 = 0,
    ioapics: [max_ioapics]IoApic = @splat(.{}),
    iso_count: u8 = 0,
    isos: [max_isos]Iso = @splat(.{}),
};

/// Result of resolving an ISA IRQ through the MADT. When no override exists
/// the classic identity mapping (`GSI == IRQ`) is used.
pub const IsaIrqRoute = struct {
    irq: u8,
    gsi: u32,
    polarity: Polarity,
    trigger: Trigger,
    overridden: bool,
};

pub const InitError = error{
    NoRsdp,
    BadRsdp,
    NoRootTable,
    BadRootTable,
    NoMadt,
    BadMadt,
    TooManyEntries,
};

var info: Info = .{};
var ready = false;

/// Locate and parse the MADT. Must run after `vmm.init` because all ACPI
/// tables are accessed through the HHDM. A failure leaves `isReady()` false and
/// the caller is expected to fall back to the legacy PIC/PIT path.
pub fn init() InitError!void {
    ready = false;
    info = .{};

    const response = limine.rsdp() orelse return error.NoRsdp;
    const rsdp_phys = @intFromPtr(response.address orelse return error.NoRsdp);
    if (!rangeValid(rsdp_phys, 20)) return error.BadRsdp;

    const rsdp = physicalToVirtual(rsdp_phys) orelse return error.BadRsdp;
    if (!std.mem.eql(u8, rsdp[0..8], "RSD PTR ")) return error.BadRsdp;
    if (checksum(rsdp, 20) != 0) return error.BadRsdp;

    const revision = rsdp[15];
    var rsdp_len: usize = 20;
    if (revision >= 2) {
        const length = readU32(rsdp, 20);
        if (length < 36 or length > max_table_length) return error.BadRsdp;
        rsdp_len = length;
        if (!rangeValid(rsdp_phys, rsdp_len)) return error.BadRsdp;
        if (checksum(rsdp, rsdp_len) != 0) return error.BadRsdp;
    }

    const root_phys: u64 = if (revision >= 2 and rsdp_len >= 28)
        readU64(rsdp, 24)
    else
        readU32(rsdp, 16);
    if (!rangeValid(root_phys, 36)) return error.NoRootTable;

    const root = physicalToVirtual(root_phys) orelse return error.NoRootTable;
    const is_xsdt = std.mem.eql(u8, root[0..4], "XSDT");
    const is_rsdt = std.mem.eql(u8, root[0..4], "RSDT");
    if (!is_xsdt and !is_rsdt) return error.BadRootTable;

    const root_len = readU32(root, 4);
    if (root_len < 36 or root_len > max_table_length) return error.BadRootTable;
    if (!rangeValid(root_phys, root_len)) return error.BadRootTable;
    if (checksum(root, root_len) != 0) return error.BadRootTable;

    const entry_size: usize = if (is_xsdt) 8 else 4;
    var offset: usize = 36;
    while (offset + entry_size <= root_len) : (offset += entry_size) {
        const table_phys: u64 = if (is_xsdt) readU64(root, offset) else readU32(root, offset);
        if (!rangeValid(table_phys, 8)) continue;

        const table = physicalToVirtual(table_phys) orelse continue;
        if (!std.mem.eql(u8, table[0..4], "APIC")) continue;

        const madt_len = readU32(table, 4);
        if (madt_len < 44 or madt_len > max_table_length) return error.BadMadt;
        if (!rangeValid(table_phys, madt_len)) return error.BadMadt;
        if (checksum(table, madt_len) != 0) return error.BadMadt;

        try parseMadt(table, madt_len);
        ready = true;
        return;
    }

    return error.NoMadt;
}

pub fn isReady() bool {
    return ready;
}

pub fn getInfo() *const Info {
    return &info;
}

/// Resolve ISA IRQ `irq` to an I/O APIC GSI. The MADT Interrupt Source
/// Override is authoritative; only when no ISA override exists does the classic
/// identity mapping (`GSI == IRQ`) apply. For IRQ 0 that means GSI 0.
pub fn isaIrqRoute(irq: u8) ?IsaIrqRoute {
    if (!ready) return null;

    var index: usize = 0;
    while (index < info.iso_count) : (index += 1) {
        const iso = info.isos[index];
        if (iso.bus == 0 and iso.source == irq) {
            return .{
                .irq = irq,
                .gsi = iso.gsi,
                .polarity = iso.polarity,
                .trigger = iso.trigger,
                .overridden = true,
            };
        }
    }

    return .{
        .irq = irq,
        .gsi = irq,
        .polarity = .active_high,
        .trigger = .edge,
        .overridden = false,
    };
}

fn parseMadt(table: [*]const u8, len: usize) InitError!void {
    var parsed: Info = .{};
    parsed.revision = table[8];
    parsed.local_apic_address = readU32(table, 36);

    var offset: usize = 44;
    while (offset < len) {
        if (offset + 2 > len) return error.BadMadt;
        const entry_type = table[offset];
        const entry_len = table[offset + 1];
        if (entry_len < 2 or offset + entry_len > len) return error.BadMadt;

        switch (entry_type) {
            0 => {
                // Processor Local APIC: ACPI processor ID, APIC ID, flags.
                if (entry_len < 8) return error.BadMadt;
                if (parsed.local_apic_count >= max_local_apics) return error.TooManyEntries;
                const flags = readU32(table, offset + 4);
                parsed.local_apics[parsed.local_apic_count] = .{
                    .id = table[offset + 3],
                    .enabled = (flags & 1) != 0,
                    .x2apic = false,
                };
                parsed.local_apic_count += 1;
                if ((flags & 1) != 0) parsed.enabled_local_apics += 1;
            },
            1 => {
                // I/O APIC: ID, reserved, 32-bit MMIO address, GSI base.
                if (entry_len < 12) return error.BadMadt;
                if (parsed.ioapic_count >= max_ioapics) return error.TooManyEntries;
                parsed.ioapics[parsed.ioapic_count] = .{
                    .id = table[offset + 2],
                    .address = readU32(table, offset + 4),
                    .gsi_base = readU32(table, offset + 8),
                };
                parsed.ioapic_count += 1;
            },
            2 => {
                // Interrupt Source Override: bus, source, GSI, flags.
                if (entry_len < 10) return error.BadMadt;
                if (parsed.iso_count >= max_isos) return error.TooManyEntries;
                const flags = readU16(table, offset + 8);
                parsed.isos[parsed.iso_count] = .{
                    .bus = table[offset + 2],
                    .source = table[offset + 3],
                    .gsi = readU32(table, offset + 4),
                    .polarity = decodePolarity(flags),
                    .trigger = decodeTrigger(flags),
                };
                parsed.iso_count += 1;
            },
            5 => {
                // Local APIC Address Override: reserved, 64-bit address.
                if (entry_len < 12) return error.BadMadt;
                parsed.lapic_address_override = readU64(table, offset + 4);
            },
            9 => {
                // Processor Local x2APIC: reserved, x2APIC ID, flags, UID.
                if (entry_len < 16) return error.BadMadt;
                if (parsed.local_apic_count >= max_local_apics) return error.TooManyEntries;
                const flags = readU32(table, offset + 8);
                parsed.local_apics[parsed.local_apic_count] = .{
                    .id = readU32(table, offset + 4),
                    .enabled = (flags & 1) != 0,
                    .x2apic = true,
                };
                parsed.local_apic_count += 1;
                if ((flags & 1) != 0) parsed.enabled_local_apics += 1;
            },
            else => {},
        }

        offset += entry_len;
    }

    info = parsed;
}

fn decodePolarity(flags: u16) Polarity {
    return switch (flags & 0x3) {
        0x3 => .active_low,
        else => .active_high,
    };
}

fn decodeTrigger(flags: u16) Trigger {
    return switch ((flags >> 2) & 0x3) {
        0x3 => .level,
        else => .edge,
    };
}

fn checksum(base: [*]const u8, len: usize) u8 {
    var sum: u8 = 0;
    for (base[0..len]) |byte| sum +%= byte;
    return sum;
}

fn rangeValid(phys: u64, len: u64) bool {
    if (phys == 0 or phys >= pmm.max_physical_address) return false;
    return len <= pmm.max_physical_address - phys;
}

fn physicalToVirtual(phys: u64) ?[*]const u8 {
    if (!rangeValid(phys, 1)) return null;
    return @ptrFromInt(vmm.hhdmOffset() + phys);
}

fn readU16(base: [*]const u8, offset: usize) u16 {
    const value: *align(1) const u16 = @ptrCast(base + offset);
    return value.*;
}

fn readU32(base: [*]const u8, offset: usize) u32 {
    const value: *align(1) const u32 = @ptrCast(base + offset);
    return value.*;
}

fn readU64(base: [*]const u8, offset: usize) u64 {
    const value: *align(1) const u64 = @ptrCast(base + offset);
    return value.*;
}
