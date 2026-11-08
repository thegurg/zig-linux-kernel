//! Local APIC (xAPIC and x2APIC) bring-up and inter-processor interrupts.
//!
//! The APIC base and mode come from `IA32_APIC_BASE` (MSR 0x1b), so no ACPI
//! parsing is needed. In xAPIC mode the 4 KiB register window is reached through
//! the HHDM after the containing huge page is marked uncached; in x2APIC mode
//! the same registers are accessed through MSRs.
//!
//! Only what the scheduler needs is implemented: enable the APIC, set the
//! spurious vector, read the local APIC ID, send fixed-delivery IPIs to one CPU
//! or all-but-self, and acknowledge interrupts.

const cpu = @import("cpu.zig");
const vmm = @import("../../memory/vmm.zig");

const ia32_apic_base: u32 = 0x1b;

const apic_id: u32 = 0x020;
const apic_eoi: u32 = 0x0b0;
const apic_tpr: u32 = 0x080;
const apic_spiv: u32 = 0x0f0;
const apic_icr_low: u32 = 0x300;
const apic_icr_high: u32 = 0x310;

const x2apic_id: u32 = 0x802;
const x2apic_eoi: u32 = 0x80b;
const x2apic_tpr: u32 = 0x808;
const x2apic_spiv: u32 = 0x80f;
const x2apic_icr: u32 = 0x830;

const spurious_vector: u8 = 0xff;
const icr_delivery_pending: u32 = 1 << 12;
const icr_shorthand_all_but_self: u32 = 3 << 18;

var initialized = false;
var x2apic = false;
var base_phys: u64 = 0;
var mmio: ?[*]volatile u32 = null;

/// Enable this CPU's local APIC. The first call also records the global mode
/// and base address and marks the MMIO page uncached; later calls only program
/// the per-CPU spurious vector and task priority.
pub fn init() bool {
    var raw = cpu.readMsr(ia32_apic_base);
    const is_x2apic = (raw & (1 << 11)) != 0;

    // EN is per-CPU and firmware may leave an AP's local APIC disabled. Set it
    // before touching either the MMIO window or the x2APIC MSRs.
    if ((raw & (1 << 10)) == 0) {
        raw |= 1 << 10;
        cpu.writeMsr(ia32_apic_base, raw);
    }

    if (!initialized) {
        x2apic = is_x2apic;
        base_phys = raw & 0x000f_ffff_ffff_f000;

        if (!x2apic) {
            if (!vmm.markUncached(base_phys, vmm.page_size)) return false;
            mmio = @ptrFromInt(vmm.hhdmOffset() + base_phys);
        }

        initialized = true;
    } else if (x2apic != is_x2apic or (!x2apic and mmio == null)) {
        return false;
    }

    const spiv = @as(u32, 0x100) | @as(u32, spurious_vector);
    if (x2apic) {
        // Spurious vector 0xff, software-enable bit set, task priority 0.
        cpu.writeMsr(x2apic_spiv, spiv);
        cpu.writeMsr(x2apic_tpr, 0);
    } else {
        write(apic_spiv, spiv);
        write(apic_tpr, 0);
    }
    return true;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn isX2apic() bool {
    return x2apic;
}

/// This CPU's local APIC ID.
pub fn id() u32 {
    if (!initialized) return 0;
    if (x2apic) {
        return @truncate(cpu.readMsr(x2apic_id));
    }
    return read(apic_id) >> 24;
}

/// Acknowledge the interrupt currently being serviced.
pub fn eoi() void {
    if (!initialized) return;
    if (x2apic) {
        cpu.writeMsr(x2apic_eoi, 0);
    } else {
        write(apic_eoi, 0);
    }
}

/// Send a fixed-delivery interrupt to one logical processor.
pub fn sendIpi(destination: u32, vector: u8) void {
    if (!initialized) return;
    if (x2apic) {
        cpu.writeMsr(x2apic_icr, (@as(u64, destination) << 32) | @as(u64, vector));
        return;
    }

    write(apic_icr_high, (destination & 0xff) << 24);
    write(apic_icr_low, @as(u32, vector));
    waitForDelivery();
}

/// Send a fixed-delivery interrupt to every CPU except the sender.
pub fn sendIpiAllButSelf(vector: u8) void {
    if (!initialized) return;
    if (x2apic) {
        cpu.writeMsr(x2apic_icr, icr_shorthand_all_but_self | @as(u32, vector));
        return;
    }

    write(apic_icr_high, 0);
    write(apic_icr_low, @as(u32, vector) | icr_shorthand_all_but_self);
    waitForDelivery();
}

fn waitForDelivery() void {
    var spins: u32 = 0;
    while ((read(apic_icr_low) & icr_delivery_pending) != 0) {
        if (spins >= 1_000_000) return;
        spins += 1;
        asm volatile ("pause");
    }
}

fn read(offset: u32) u32 {
    const window = mmio orelse return 0;
    return window[offset / 4];
}

fn write(offset: u32, value: u32) void {
    const window = mmio orelse return;
    window[offset / 4] = value;
}
