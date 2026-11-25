//! Legacy virtio-blk polling driver over the PCI I/O BAR.
//!
//! M18 intentionally implements the legacy (virtio 0.9.5) interface: the test
//! harness creates the virtio-blk device with `disable-modern=on`, and the
//! driver uses BAR0 as an I/O port window. Modern virtio 1.0 uses a completely
//! different register layout and capability walk; it is tracked for a later
//! milestone.
//!
//! One request is outstanding at a time. The virtqueue lives in a physically
//! contiguous PMM allocation, and each request transfers exactly one 512-byte
//! sector through a page-aligned bounce buffer. This is slower than a real
//! driver but keeps the DMA-address and descriptor logic easy to audit. Reads
//! and writes share the same descriptor chain; only the request type and the
//! device-write flag on the data descriptor differ.

const std = @import("std");
const pci = @import("pci.zig");
const pmm = @import("../memory/pmm.zig");
const vmm = @import("../memory/vmm.zig");
const port = @import("../arch/x86_64/port.zig");
const sync = @import("../sync.zig");
const block = @import("../fs/block.zig");

pub const sector_size: u32 = 512;
pub const max_queue_size: u16 = 512;
const max_ring_pages = 8;
const request_timeout_spins = 100_000_000;

const reg_host_features: u16 = 0x00;
const reg_guest_features: u16 = 0x04;
const reg_queue_address: u16 = 0x08;
const reg_queue_size: u16 = 0x0c;
const reg_queue_select: u16 = 0x0e;
const reg_queue_notify: u16 = 0x10;
const reg_status: u16 = 0x12;
const reg_config: u16 = 0x14;

const status_acknowledge: u8 = 1;
const status_driver: u8 = 2;
const status_driver_ok: u8 = 4;
const status_failed: u8 = 128;

const desc_flag_next: u16 = 1;
const desc_flag_write: u16 = 2;

const blk_t_in: u32 = 0;
const blk_t_out: u32 = 1;
const blk_s_ok: u8 = 0;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const UsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const Error = error{
    NotFound,
    ModernOnly,
    NoIoBar,
    BadQueueSize,
    QueueTooLarge,
    OutOfMemory,
    RingNotContiguous,
    DeviceTimeout,
    DeviceFailed,
    IoError,
    BadRequest,
    NotInitialized,
};

pub const Info = struct {
    capacity_sectors: u64,
    queue_size: u16,
    io_base: u16,
    ring_pages: usize,
    host_features: u32,
};

var enabled = false;
var io_base: u16 = 0;
var capacity_sectors: u64 = 0;
var queue_size: u16 = 0;
var host_features: u32 = 0;
var ring_phys: u64 = 0;
var ring_pages: usize = 0;
var ring: [*]u8 = undefined;
var desc_offset: usize = 0;
var avail_offset: usize = 0;
var used_offset: usize = 0;
// Number of completed requests the driver has consumed. The device owns the
// used-ring index, so comparing against this counter (instead of sampling the
// device index right before the notification) is what makes completion
// unambiguous when the device finishes before the driver polls.
var used_seen: u16 = 0;

var request_lock: sync.IrqSpinLock = .{};
var request_header: [16]u8 align(16) = @splat(0);
var request_status: u8 align(16) = 0xff;
var bounce: [sector_size]u8 align(512) = @splat(0);
var adapter_context: u8 = 0;

pub fn init() Error!Info {
    if (enabled) return info();

    const device = pci.find(pci.virtio_vendor_id, pci.virtio_legacy_blk_device_id) orelse {
        if (pci.find(pci.virtio_vendor_id, pci.virtio_modern_blk_device_id) != null) {
            return error.ModernOnly;
        }
        return error.NotFound;
    };

    const bar = device.bar(0) orelse return error.NoIoBar;
    if (!bar.is_io or bar.base == 0 or bar.base > 0xffff) return error.NoIoBar;
    io_base = @intCast(bar.base);

    // I/O port access, bus-master DMA, and no INTx. The driver polls.
    pci.enable(device, true, false, true, false);

    reset();
    setStatus(status_acknowledge);
    setStatus(status_acknowledge | status_driver);

    host_features = port.inl(io_base + reg_host_features);
    // Only feature bits 0..31 are visible in the legacy interface. We do not
    // need indirect descriptors, event suppression, or block size hints, so a
    // zero guest-feature set is a valid minimal negotiation.
    port.outl(io_base + reg_guest_features, 0);

    port.outw(io_base + reg_queue_select, 0);
    queue_size = port.inw(io_base + reg_queue_size);
    if (queue_size == 0) return fail(error.BadQueueSize);
    if (queue_size > max_queue_size) return fail(error.QueueTooLarge);
    if (!layoutQueue(queue_size)) return fail(error.BadQueueSize);

    // Allocate the descriptor table, available ring and used ring as one
    // physically contiguous region, then verify the HHDM mapping is contiguous
    // too so the device's DMA addresses match the driver's virtual addresses.
    const pages_needed = @max(@as(usize, 1), (ringBytes(queue_size) + vmm.page_size - 1) / vmm.page_size);
    if (pages_needed > max_ring_pages) return fail(error.QueueTooLarge);
    ring_phys = pmm.allocContiguous(pages_needed) orelse return fail(error.OutOfMemory);
    ring_pages = pages_needed;
    ring = @ptrFromInt(vmm.hhdmOffset() + ring_phys);
    @memset(ring[0 .. ring_pages * @as(usize, @intCast(vmm.page_size))], 0);
    used_seen = 0;

    var page: usize = 0;
    while (page < ring_pages) : (page += 1) {
        const virt = @intFromPtr(ring) + page * @as(usize, @intCast(vmm.page_size));
        const expected = ring_phys + @as(u64, page) * vmm.page_size;
        if (vmm.translate(virt) != expected) return fail(error.RingNotContiguous);
    }

    port.outl(io_base + reg_queue_address, @truncate(ring_phys >> 12));
    setStatus(status_acknowledge | status_driver | status_driver_ok);

    capacity_sectors = @as(u64, port.inl(io_base + reg_config)) |
        (@as(u64, port.inl(io_base + reg_config + 4)) << 32);

    enabled = true;
    return info();
}

pub fn info() Info {
    return .{
        .capacity_sectors = capacity_sectors,
        .queue_size = queue_size,
        .io_base = io_base,
        .ring_pages = ring_pages,
        .host_features = host_features,
    };
}

pub fn blockDevice() block.Device {
    return .{
        .context = @ptrCast(&adapter_context),
        .read_fn = readAdapter,
        .write_fn = writeAdapter,
        .sector_size = sector_size,
        .sector_count = capacity_sectors,
    };
}

pub fn readSectors(lba: u64, buffer: []u8) bool {
    return transfer(blk_t_in, lba, buffer);
}

pub fn writeSectors(lba: u64, buffer: []const u8) bool {
    // `transfer` needs mutable access only to copy out of the bounce buffer.
    // Writes copy into it first, so a const slice is sufficient here.
    if (!enabled) return false;
    if (buffer.len == 0 or buffer.len % @as(usize, sector_size) != 0) return false;
    if (!rangeValid(lba, buffer.len)) return false;

    const guard = request_lock.acquire();
    defer guard.release();

    const sectors = buffer.len / @as(usize, sector_size);
    var index: usize = 0;
    while (index < sectors) : (index += 1) {
        const source = buffer[index * @as(usize, sector_size) ..][0..sector_size];
        @memcpy(bounce[0..], source);
        if (!submit(blk_t_out, lba + index)) return false;
    }
    return true;
}

fn transfer(op: u32, lba: u64, buffer: []u8) bool {
    if (!enabled) return false;
    if (buffer.len == 0 or buffer.len % @as(usize, sector_size) != 0) return false;
    if (!rangeValid(lba, buffer.len)) return false;

    const guard = request_lock.acquire();
    defer guard.release();

    const sectors = buffer.len / @as(usize, sector_size);
    var index: usize = 0;
    while (index < sectors) : (index += 1) {
        if (!submit(op, lba + index)) return false;
        if (op == blk_t_in) {
            @memcpy(buffer[index * @as(usize, sector_size) ..][0..sector_size], bounce[0..]);
        }
    }
    return true;
}

fn rangeValid(lba: u64, length: usize) bool {
    const sectors: u64 = @intCast(length / @as(usize, sector_size));
    return lba <= capacity_sectors and sectors <= capacity_sectors - lba;
}

fn readAdapter(_: *anyopaque, lba: u64, buffer: []u8) bool {
    return readSectors(lba, buffer);
}

fn writeAdapter(_: *anyopaque, lba: u64, buffer: []const u8) bool {
    return writeSectors(lba, buffer);
}

fn submit(op: u32, lba: u64) bool {
    const header_phys = vmm.translate(@intFromPtr(&request_header)) orelse return false;
    const data_phys = vmm.translate(@intFromPtr(&bounce)) orelse return false;
    const status_phys = vmm.translate(@intFromPtr(&request_status)) orelse return false;

    std.mem.writeInt(u32, request_header[0..4], op, .little);
    std.mem.writeInt(u32, request_header[4..8], 0, .little);
    std.mem.writeInt(u64, request_header[8..16], lba, .little);
    request_status = 0xff;

    const desc = descTable();
    desc[0] = .{ .addr = header_phys, .len = 16, .flags = desc_flag_next, .next = 1 };
    desc[1] = .{
        .addr = data_phys,
        .len = sector_size,
        .flags = desc_flag_next | (if (op == blk_t_in) desc_flag_write else 0),
        .next = 2,
    };
    desc[2] = .{ .addr = status_phys, .len = 1, .flags = desc_flag_write, .next = 0 };

    const avail_index = availIndexPtr();
    const slot = @atomicLoad(u16, avail_index, .monotonic) % queue_size;
    availRingPtr()[slot] = 0;
    asm volatile ("mfence" ::: .{ .memory = true });
    @atomicStore(u16, avail_index, @atomicLoad(u16, avail_index, .monotonic) +% 1, .release);
    asm volatile ("mfence" ::: .{ .memory = true });
    port.outw(io_base + reg_queue_notify, 0);

    const used_index = usedIndexPtr();
    var spins: usize = 0;
    while (@atomicLoad(u16, used_index, .acquire) == used_seen) : (spins += 1) {
        if (spins >= request_timeout_spins) return false;
        asm volatile ("pause" ::: .{ .memory = true });
    }

    const used_slot = used_seen % queue_size;
    const used = usedRingPtr();
    if (used[used_slot].id != 0) return false;
    const status = @as(*volatile u8, &request_status).*;
    if (status != blk_s_ok) return false;
    used_seen +%= 1;
    return true;
}

fn reset() void {
    port.outb(io_base + reg_status, 0);
    var spins: usize = 0;
    while (port.inb(io_base + reg_status) != 0) : (spins += 1) {
        if (spins >= 1_000_000) return;
        port.ioWait();
    }
}

fn setStatus(bits: u8) void {
    port.outb(io_base + reg_status, bits);
}

fn fail(err: Error) Error {
    port.outb(io_base + reg_status, status_failed);
    return err;
}

fn ringBytes(size: u16) usize {
    const data = @as(usize, size);
    const desc_bytes = 16 * data;
    const avail_bytes = 4 + 2 * data + 2;
    const used_chunk = usedOffset(size) + 6 + 8 * data + 2;
    return @max(used_chunk, desc_bytes + avail_bytes);
}

fn usedOffset(size: u16) usize {
    const desc_bytes = 16 * @as(usize, size);
    const avail_end = alignForward(desc_bytes + 4 + 2 * @as(usize, size) + 2, vmm.page_size);
    return avail_end;
}

fn layoutQueue(size: u16) bool {
    if (size == 0) return false;
    desc_offset = 0;
    avail_offset = alignForward(16 * @as(usize, size), 2);
    used_offset = usedOffset(size);
    const total = used_offset + 6 + 8 * @as(usize, size) + 2;
    return total <= max_ring_pages * @as(usize, @intCast(vmm.page_size));
}

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn descTable() *volatile [max_queue_size]Desc {
    return @ptrFromInt(@intFromPtr(ring) + desc_offset);
}

fn availRingPtr() *volatile [max_queue_size]u16 {
    return @ptrFromInt(@intFromPtr(ring) + avail_offset + 4);
}

fn availIndexPtr() *u16 {
    return @ptrFromInt(@intFromPtr(ring) + avail_offset + 2);
}

fn usedIndexPtr() *u16 {
    return @ptrFromInt(@intFromPtr(ring) + used_offset + 2);
}

fn usedRingPtr() *volatile [max_queue_size]UsedElem {
    return @ptrFromInt(@intFromPtr(ring) + used_offset + 4);
}
