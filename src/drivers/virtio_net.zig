//! Legacy virtio-net polling driver over the PCI I/O BAR.
//!
//! M19 uses the legacy (virtio 0.9.5) interface with two split virtqueues:
//! queue 0 receives and queue 1 transmits. The harness creates the device with
//! `disable-modern=on`, so the legacy `0x1000` device ID and the I/O BAR layout
//! are available. Only `VIRTIO_NET_F_MAC` is negotiated; every packet carries
//! the 10-byte legacy virtio-net header, and all completions are polled.
//!
//! The receive path keeps a small fixed ring of 2 KiB buffers and republishes
//! each buffer as soon as its completed frame has been copied out. The transmit
//! path has one outstanding request and one static bounce buffer.

const std = @import("std");
const pci = @import("pci.zig");
const pmm = @import("../memory/pmm.zig");
const vmm = @import("../memory/vmm.zig");
const port = @import("../arch/x86_64/port.zig");
const sync = @import("../sync.zig");

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

const net_f_mac: u32 = 1 << 5;

const desc_flag_next: u16 = 1;
const desc_flag_write: u16 = 2;

/// Legacy virtio-net header without MRG_RXBUF. The driver does not negotiate
/// mergeable buffers, so every TX and RX packet is prefixed by ten bytes.
const net_header_len = 10;
const rx_buffer_size = 2048;
const max_rx_buffers = 16;
const max_ethernet_frame = 1514;
const tx_buffer_size = 2048;

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

const Layout = struct {
    desc_offset: usize,
    avail_offset: usize,
    used_offset: usize,
    total_bytes: usize,
};

const Queue = struct {
    size: u16 = 0,
    ring_phys: u64 = 0,
    ring_pages: usize = 0,
    ring: [*]u8 = undefined,
    layout: Layout = .{ .desc_offset = 0, .avail_offset = 0, .used_offset = 0, .total_bytes = 0 },
    used_seen: u16 = 0,
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
    NoMac,
    IoError,
    NotInitialized,
};

pub const Info = struct {
    mac: [6]u8,
    rx_queue_size: u16,
    tx_queue_size: u16,
    io_base: u16,
    rx_ring_pages: usize,
    tx_ring_pages: usize,
    host_features: u32,
};

var enabled = false;
var io_base: u16 = 0;
var mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
var host_features: u32 = 0;
var rx_queue: Queue = .{};
var tx_queue: Queue = .{};

var rx_buffer_phys: u64 = 0;
var rx_buffer_pages: usize = 0;
var rx_buffer_count: u16 = 0;
var rx_buffers: [*]u8 = undefined;

var tx_buffer: [tx_buffer_size]u8 align(16) = @splat(0);
var rx_lock: sync.IrqSpinLock = .{};
var tx_lock: sync.IrqSpinLock = .{};

pub fn init() Error!Info {
    if (enabled) return info();

    const device = pci.find(pci.virtio_vendor_id, pci.virtio_legacy_net_device_id) orelse {
        if (pci.find(pci.virtio_vendor_id, pci.virtio_modern_net_device_id) != null) {
            return error.ModernOnly;
        }
        return error.NotFound;
    };

    const bar = device.bar(0) orelse return error.NoIoBar;
    if (!bar.is_io or bar.base == 0 or bar.base > 0xffff) return error.NoIoBar;
    io_base = @intCast(bar.base);

    // I/O port access and bus-master DMA; interrupts stay disabled while the
    // driver polls both queues.
    pci.enable(device, true, false, true, false);

    reset();
    setStatus(status_acknowledge);
    setStatus(status_acknowledge | status_driver);

    host_features = port.inl(io_base + reg_host_features);
    if ((host_features & net_f_mac) == 0) return fail(error.NoMac);
    port.outl(io_base + reg_guest_features, net_f_mac);

    setupQueue(0, &rx_queue) catch |err| return fail(err);
    setupQueue(1, &tx_queue) catch |err| return fail(err);

    for (0..6) |index| mac[index] = port.inb(io_base + reg_config + @as(u16, @intCast(index)));

    rx_buffer_count = @min(rx_queue.size, max_rx_buffers);
    if (rx_buffer_count == 0) return fail(error.BadQueueSize);
    const rx_bytes = @as(usize, rx_buffer_count) * rx_buffer_size;
    rx_buffer_pages = (rx_bytes + vmm.page_size - 1) / vmm.page_size;
    rx_buffer_phys = pmm.allocContiguous(rx_buffer_pages) orelse return fail(error.OutOfMemory);
    rx_buffers = @ptrFromInt(vmm.hhdmOffset() + rx_buffer_phys);
    @memset(rx_buffers[0 .. rx_buffer_pages * @as(usize, @intCast(vmm.page_size))], 0);

    var page: usize = 0;
    while (page < rx_buffer_pages) : (page += 1) {
        const virt = @intFromPtr(rx_buffers) + page * @as(usize, @intCast(vmm.page_size));
        const expected = rx_buffer_phys + @as(u64, page) * vmm.page_size;
        if (vmm.translate(virt) != expected) return fail(error.RingNotContiguous);
    }

    const desc = descTable(&rx_queue);
    const avail = availRingPtr(&rx_queue);
    var index: u16 = 0;
    while (index < rx_buffer_count) : (index += 1) {
        desc[index] = .{
            .addr = rx_buffer_phys + @as(u64, index) * rx_buffer_size,
            .len = rx_buffer_size,
            .flags = desc_flag_write,
            .next = 0,
        };
        avail[index] = index;
    }
    @atomicStore(u16, availIndexPtr(&rx_queue), rx_buffer_count, .release);

    setStatus(status_acknowledge | status_driver | status_driver_ok);
    asm volatile ("mfence" ::: .{ .memory = true });
    port.outw(io_base + reg_queue_notify, 0);

    enabled = true;
    return info();
}

pub fn info() Info {
    return .{
        .mac = mac,
        .rx_queue_size = rx_queue.size,
        .tx_queue_size = tx_queue.size,
        .io_base = io_base,
        .rx_ring_pages = rx_queue.ring_pages,
        .tx_ring_pages = tx_queue.ring_pages,
        .host_features = host_features,
    };
}

pub fn macAddress() [6]u8 {
    return mac;
}

/// Transmit one Ethernet frame (header included, no virtio-net header).
pub fn transmit(frame: []const u8) bool {
    if (!enabled) return false;
    if (frame.len < 14 or frame.len > max_ethernet_frame) return false;

    const guard = tx_lock.acquire();
    defer guard.release();

    const wire_len = net_header_len + frame.len;
    if (wire_len > tx_buffer.len) return false;
    @memset(tx_buffer[0..net_header_len], 0);
    @memcpy(tx_buffer[net_header_len..wire_len], frame);

    const data_phys = vmm.translate(@intFromPtr(&tx_buffer)) orelse return false;
    const queue = &tx_queue;
    descTable(queue)[0] = .{
        .addr = data_phys,
        .len = @intCast(wire_len),
        .flags = 0,
        .next = 0,
    };

    const avail = availIndexPtr(queue);
    const slot = @atomicLoad(u16, avail, .monotonic) % queue.size;
    availRingPtr(queue)[slot] = 0;
    asm volatile ("mfence" ::: .{ .memory = true });
    @atomicStore(u16, avail, @atomicLoad(u16, avail, .monotonic) +% 1, .release);
    asm volatile ("mfence" ::: .{ .memory = true });
    port.outw(io_base + reg_queue_notify, 1);

    const used = usedIndexPtr(queue);
    var spins: usize = 0;
    while (@atomicLoad(u16, used, .acquire) == queue.used_seen) : (spins += 1) {
        if (spins >= request_timeout_spins) return false;
        asm volatile ("pause" ::: .{ .memory = true });
    }

    const element = usedRingPtr(queue)[queue.used_seen % queue.size];
    if (element.id != 0) return false;
    queue.used_seen +%= 1;
    return true;
}

/// Poll one received Ethernet frame. Returns null when no frame is pending.
pub fn pollRx(buffer: []u8) ?usize {
    if (!enabled) return null;

    const guard = rx_lock.acquire();
    defer guard.release();

    const queue = &rx_queue;
    while (true) {
        const used_index = @atomicLoad(u16, usedIndexPtr(queue), .acquire);
        if (used_index == queue.used_seen) return null;

        const element = usedRingPtr(queue)[queue.used_seen % queue.size];
        queue.used_seen +%= 1;

        if (element.id >= rx_buffer_count) continue;
        const descriptor: u16 = @intCast(element.id);
        const total = @min(element.len, rx_buffer_size);
        recycleRx(descriptor);
        if (total <= net_header_len) continue;

        const frame_len = total - net_header_len;
        const copy = @min(frame_len, buffer.len);
        const source = rxBuffer(descriptor);
        @memcpy(buffer[0..copy], source[net_header_len..][0..copy]);
        return copy;
    }
}

fn setupQueue(index: u16, queue: *Queue) Error!void {
    port.outw(io_base + reg_queue_select, index);
    queue.size = port.inw(io_base + reg_queue_size);
    if (queue.size == 0) return error.BadQueueSize;
    if (queue.size > max_queue_size) return error.QueueTooLarge;

    queue.layout = layout(queue.size) orelse return error.QueueTooLarge;
    queue.ring_pages = (queue.layout.total_bytes + vmm.page_size - 1) / vmm.page_size;
    if (queue.ring_pages > max_ring_pages) return error.QueueTooLarge;
    queue.ring_phys = pmm.allocContiguous(queue.ring_pages) orelse return error.OutOfMemory;
    queue.ring = @ptrFromInt(vmm.hhdmOffset() + queue.ring_phys);
    queue.used_seen = 0;
    @memset(queue.ring[0 .. queue.ring_pages * @as(usize, @intCast(vmm.page_size))], 0);

    var page: usize = 0;
    while (page < queue.ring_pages) : (page += 1) {
        const virt = @intFromPtr(queue.ring) + page * @as(usize, @intCast(vmm.page_size));
        const expected = queue.ring_phys + @as(u64, page) * vmm.page_size;
        if (vmm.translate(virt) != expected) return error.RingNotContiguous;
    }

    port.outl(io_base + reg_queue_address, @truncate(queue.ring_phys >> 12));
}

fn layout(size: u16) ?Layout {
    if (size == 0) return null;
    const desc_bytes = 16 * @as(usize, size);
    const avail_offset = alignForward(desc_bytes, 2);
    const used_offset = alignForward(avail_offset + 4 + 2 * @as(usize, size) + 2, vmm.page_size);
    const total = used_offset + 6 + 8 * @as(usize, size) + 2;
    if (total > max_ring_pages * @as(usize, @intCast(vmm.page_size))) return null;
    return .{
        .desc_offset = 0,
        .avail_offset = avail_offset,
        .used_offset = used_offset,
        .total_bytes = total,
    };
}

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn recycleRx(descriptor: u16) void {
    const queue = &rx_queue;
    const avail = availIndexPtr(queue);
    const index = @atomicLoad(u16, avail, .monotonic);
    availRingPtr(queue)[index % queue.size] = descriptor;
    asm volatile ("mfence" ::: .{ .memory = true });
    @atomicStore(u16, avail, index +% 1, .release);
    asm volatile ("mfence" ::: .{ .memory = true });
    port.outw(io_base + reg_queue_notify, 0);
}

fn rxBuffer(index: u16) [*]u8 {
    return rx_buffers + @as(usize, index) * rx_buffer_size;
}

fn descTable(queue: *Queue) *volatile [max_queue_size]Desc {
    return @ptrFromInt(@intFromPtr(queue.ring) + queue.layout.desc_offset);
}

fn availRingPtr(queue: *Queue) *volatile [max_queue_size]u16 {
    return @ptrFromInt(@intFromPtr(queue.ring) + queue.layout.avail_offset + 4);
}

fn availIndexPtr(queue: *Queue) *u16 {
    return @ptrFromInt(@intFromPtr(queue.ring) + queue.layout.avail_offset + 2);
}

fn usedIndexPtr(queue: *Queue) *u16 {
    return @ptrFromInt(@intFromPtr(queue.ring) + queue.layout.used_offset + 2);
}

fn usedRingPtr(queue: *Queue) *volatile [max_queue_size]UsedElem {
    return @ptrFromInt(@intFromPtr(queue.ring) + queue.layout.used_offset + 4);
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
