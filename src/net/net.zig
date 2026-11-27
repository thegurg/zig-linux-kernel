//! Minimal IPv4 network core for the M19 virtio-net path.
//!
//! The stack is deliberately small: Ethernet II, ARP, IPv4, ICMP echo, UDP, a
//! loopback path, and a fixed table of UDP sockets. There is no TCP, DHCP,
//! fragmentation, routing protocol, or retransmission. The single network
//! device is supplied by the caller as a pair of transmit/receive callbacks, so
//! the packet code stays independent of the virtio register layout.

const std = @import("std");
const types = @import("types.zig");
const ethernet = @import("ethernet.zig");
const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const udp = @import("udp.zig");
const dns = @import("dns.zig");
const time = @import("../time.zig");
const sync = @import("../sync.zig");

pub const Mac = types.Mac;
pub const Ipv4 = types.Ipv4;
pub const Datagram = struct {
    source: Ipv4,
    source_port: u16,
    len: usize,
};

pub const Device = struct {
    context: *anyopaque,
    mac: Mac,
    transmit_fn: *const fn (*anyopaque, frame: []const u8) bool,
    receive_fn: *const fn (*anyopaque, frame: []u8) ?usize,
};

pub const Config = struct {
    ip: Ipv4,
    netmask: Ipv4,
    gateway: Ipv4,
    dns: Ipv4,
};

pub const Info = struct {
    mac: Mac,
    ip: Ipv4,
    netmask: Ipv4,
    gateway: Ipv4,
    dns: Ipv4,
};

pub const DnsError = error{
    NotInitialized,
    NoDns,
    BindFailed,
    SendFailed,
    Timeout,
    NoAnswer,
    NameTooLong,
};

pub const max_frame = 1600;
pub const max_udp_payload = 1472;
const max_sockets = 8;
const arp_entries = 8;
const default_arp_timeout_ns: u64 = 1_000_000_000;

const ArpEntry = struct {
    ip: Ipv4 = types.ipv4_unspecified,
    mac: Mac = types.mac_zero,
    valid: bool = false,
};

const Socket = struct {
    port: u16 = 0,
    used: bool = false,
    ready: bool = false,
    source: Ipv4 = types.ipv4_unspecified,
    source_port: u16 = 0,
    length: usize = 0,
    data: [max_udp_payload]u8 = undefined,
};

var device: Device = undefined;
var device_ready = false;
var config: Config = undefined;

var arp_table: [arp_entries]ArpEntry = @splat(.{});
var sockets: [max_sockets]Socket = @splat(.{});
var next_identification: u16 = 1;

var pending_icmp: bool = false;
var pending_identification: u16 = 0;
var pending_sequence: u16 = 0;
var pending_reply: bool = false;

var state_lock: sync.IrqSpinLock = .{};
var send_lock: sync.IrqSpinLock = .{};

pub fn init(dev: Device, cfg: Config) void {
    const guard = state_lock.acquire();
    defer guard.release();

    device = dev;
    config = cfg;
    device_ready = true;
    next_identification = 1;
    pending_icmp = false;
    pending_reply = false;
    arp_table = @splat(.{});
    sockets = @splat(.{});
}

pub fn ready() bool {
    return device_ready;
}

pub fn info() Info {
    return .{
        .mac = if (device_ready) device.mac else types.mac_zero,
        .ip = if (device_ready) config.ip else types.ipv4_unspecified,
        .netmask = if (device_ready) config.netmask else types.ipv4_unspecified,
        .gateway = if (device_ready) config.gateway else types.ipv4_unspecified,
        .dns = if (device_ready) config.dns else types.ipv4_unspecified,
    };
}

pub fn isLocal(address: Ipv4) bool {
    if (!device_ready) return false;
    return types.ipv4Eql(address, config.ip) or
        types.ipv4IsLoopback(address) or
        types.ipv4IsBroadcast(address);
}

pub fn macString(buffer: []u8, address: Mac) []const u8 {
    return std.fmt.bufPrint(buffer, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        address[0], address[1], address[2], address[3], address[4], address[5],
    }) catch "??:??:??:??:??:??";
}

pub fn ipv4String(buffer: []u8, address: Ipv4) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
        address[0], address[1], address[2], address[3],
    }) catch "?.?.?.?";
}

/// Poll the device for one frame and dispatch it. Returns the frame length, or
/// zero when the receive queue is empty.
pub fn pollOnce() usize {
    if (!device_ready) return 0;
    var frame: [max_frame]u8 = undefined;
    const length = device.receive_fn(device.context, &frame) orelse return 0;
    if (length > frame.len) return 0;
    handleFrame(frame[0..length]);
    return length;
}

pub fn arpResolve(address: Ipv4, timeout_ns: u64) ?Mac {
    if (!device_ready) return null;
    if (types.ipv4IsUnspecified(address) or types.ipv4IsBroadcast(address)) return null;
    if (types.ipv4Eql(address, config.ip)) return device.mac;
    if (cacheLookup(address)) |found| return found;

    if (!sendArp(arp.operation_request, types.mac_broadcast, types.mac_zero, address)) return null;

    const deadline = time.nowNs() + timeout_ns;
    while (true) {
        if (cacheLookup(address)) |found| return found;
        if (time.nowNs() >= deadline) break;
        _ = pollOnce();
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return cacheLookup(address);
}

pub fn ping(destination: Ipv4, timeout_ns: u64) bool {
    if (!device_ready) return false;

    const identification = nextId();
    const sequence: u16 = 1;
    {
        const guard = state_lock.acquire();
        defer guard.release();
        pending_icmp = true;
        pending_identification = identification;
        pending_sequence = sequence;
        pending_reply = false;
    }

    var payload: [32]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index * 3 + 1);
    var message: [64]u8 = undefined;
    const bytes = icmp.build(&message, icmp.echo_request, 0, identification, sequence, &payload) orelse {
        clearPendingIcmp();
        return false;
    };
    if (!sendIpv4(destination, ipv4.protocol_icmp, bytes)) {
        clearPendingIcmp();
        return false;
    }

    const deadline = time.nowNs() + timeout_ns;
    while (true) {
        if (hasPendingReply()) {
            clearPendingIcmp();
            return true;
        }
        if (time.nowNs() >= deadline) break;
        _ = pollOnce();
        asm volatile ("pause" ::: .{ .memory = true });
    }
    clearPendingIcmp();
    return false;
}

pub fn udpBind(port: u16) bool {
    if (port == 0) return false;
    const guard = state_lock.acquire();
    defer guard.release();

    for (&sockets) |*socket| {
        if (socket.used and socket.port == port) return false;
    }
    for (&sockets) |*socket| {
        if (!socket.used) {
            socket.* = .{};
            socket.used = true;
            socket.port = port;
            return true;
        }
    }
    return false;
}

pub fn udpUnbind(port: u16) void {
    const guard = state_lock.acquire();
    defer guard.release();
    for (&sockets) |*socket| {
        if (socket.used and socket.port == port) {
            socket.* = .{};
            return;
        }
    }
}

pub fn udpSend(source_port: u16, destination: Ipv4, destination_port: u16, payload: []const u8) bool {
    if (!device_ready) return false;
    if (payload.len > max_udp_payload) return false;

    var packet: [max_frame]u8 = undefined;
    const bytes = udp.build(
        &packet,
        config.ip,
        destination,
        source_port,
        destination_port,
        payload,
    ) orelse return false;
    return sendIpv4(destination, ipv4.protocol_udp, bytes);
}

pub fn udpRecv(port: u16, timeout_ns: u64, buffer: []u8) ?Datagram {
    if (!device_ready) return null;
    const deadline = time.nowNs() + timeout_ns;
    while (true) {
        if (takeDatagram(port, buffer)) |datagram| return datagram;
        if (time.nowNs() >= deadline) return null;
        _ = pollOnce();
        asm volatile ("pause" ::: .{ .memory = true });
    }
}

pub fn dnsQuery(name: []const u8, timeout_ns: u64) DnsError!Ipv4 {
    if (!device_ready) return error.NotInitialized;
    if (types.ipv4IsUnspecified(config.dns)) return error.NoDns;
    return dnsQueryTo(config.dns, 53, name, timeout_ns);
}

/// Send a DNS A query to an explicit server and port. The selftest points this
/// at a deterministic host-side stub reached through QEMU user networking, so
/// the test does not depend on the host resolver or internet access.
pub fn dnsQueryTo(server: Ipv4, server_port: u16, name: []const u8, timeout_ns: u64) DnsError!Ipv4 {
    if (!device_ready) return error.NotInitialized;
    if (types.ipv4IsUnspecified(server)) return error.NoDns;

    const port: u16 = 49153;
    if (!udpBind(port)) return error.BindFailed;
    defer udpUnbind(port);

    var query_buffer: [512]u8 = undefined;
    const query = dns.buildQuery(&query_buffer, 0x4d19, name) catch return error.NameTooLong;
    if (!udpSend(port, server, server_port, query)) return error.SendFailed;

    var response: [512]u8 = undefined;
    const datagram = udpRecv(port, timeout_ns, &response) orelse return error.Timeout;
    return dns.firstAddress(response[0..datagram.len]) orelse error.NoAnswer;
}

fn handleFrame(frame: []const u8) void {
    const header = ethernet.parse(frame) orelse return;
    if (!types.macEql(header.destination, device.mac) and
        !types.macEql(header.destination, types.mac_broadcast)) return;

    switch (header.ethertype) {
        ethernet.ethertype_arp => handleArp(frame[ethernet.header_len..]),
        ethernet.ethertype_ipv4 => handleIpv4(frame[ethernet.header_len..], header.source),
        else => {},
    }
}

fn handleArp(payload: []const u8) void {
    const packet = arp.parse(payload) orelse return;
    cacheStore(packet.sender_ip, packet.sender_mac);

    if (packet.operation != arp.operation_request) return;
    if (!types.ipv4Eql(packet.target_ip, config.ip)) return;

    var reply_buffer: [arp.packet_len]u8 = undefined;
    const reply = arp.build(
        &reply_buffer,
        arp.operation_reply,
        device.mac,
        config.ip,
        packet.sender_mac,
        packet.sender_ip,
    ) orelse return;
    _ = sendFrame(packet.sender_mac, ethernet.ethertype_arp, reply);
}

fn handleIpv4(packet: []const u8, source_mac: ?Mac) void {
    const view = ipv4.parse(packet) orelse return;
    const addressed_to_us = types.ipv4Eql(view.destination, config.ip) or
        types.ipv4IsLoopback(view.destination) or
        types.ipv4IsBroadcast(view.destination);
    if (!addressed_to_us) return;

    switch (view.protocol) {
        ipv4.protocol_icmp => handleIcmp(view.payload, view.source, source_mac),
        ipv4.protocol_udp => handleUdp(view.payload, view.source, view.destination),
        else => {},
    }
}

fn handleIcmp(payload: []const u8, source: Ipv4, source_mac: ?Mac) void {
    const message = icmp.parse(payload) orelse return;
    if (message.message_type == icmp.echo_request and message.code == 0) {
        var reply_buffer: [max_frame]u8 = undefined;
        const reply = icmp.build(
            &reply_buffer,
            icmp.echo_reply,
            0,
            message.id,
            message.sequence,
            message.data,
        ) orelse return;
        _ = sendIpv4Via(source, ipv4.protocol_icmp, reply, source_mac);
        return;
    }
    if (message.message_type != icmp.echo_reply or message.code != 0) return;

    const guard = state_lock.acquire();
    defer guard.release();
    if (pending_icmp and
        message.id == pending_identification and
        message.sequence == pending_sequence)
    {
        pending_reply = true;
    }
}

fn handleUdp(payload: []const u8, source: Ipv4, destination: Ipv4) void {
    const view = udp.parse(payload) orelse return;
    if (!udp.checksumValid(source, destination, payload)) return;

    const guard = state_lock.acquire();
    defer guard.release();

    for (&sockets) |*socket| {
        if (!socket.used or socket.port != view.destination_port) continue;
        if (socket.ready) return;
        socket.ready = true;
        socket.source = source;
        socket.source_port = view.source_port;
        socket.length = @min(view.payload.len, max_udp_payload);
        @memcpy(socket.data[0..socket.length], view.payload[0..socket.length]);
        return;
    }
}

fn sendIpv4(destination: Ipv4, protocol: u8, payload: []const u8) bool {
    if (isLocal(destination)) return loopbackIpv4(destination, protocol, payload);

    const next_hop = if (ipv4.sameSubnet(destination, config.ip, config.netmask))
        destination
    else
        config.gateway;
    const next_hop_mac = arpResolve(next_hop, default_arp_timeout_ns) orelse return false;
    return sendIpv4Ethernet(destination, protocol, payload, next_hop_mac);
}

fn sendIpv4Via(destination: Ipv4, protocol: u8, payload: []const u8, via: ?Mac) bool {
    if (via) |address| return sendIpv4Ethernet(destination, protocol, payload, address);
    if (isLocal(destination)) return loopbackIpv4(destination, protocol, payload);
    return sendIpv4(destination, protocol, payload);
}

fn sendIpv4Ethernet(destination: Ipv4, protocol: u8, payload: []const u8, next_hop: Mac) bool {
    var packet: [max_frame]u8 = undefined;
    const bytes = ipv4.build(
        &packet,
        protocol,
        config.ip,
        destination,
        payload,
        nextId(),
    ) orelse return false;
    return sendFrame(next_hop, ethernet.ethertype_ipv4, bytes);
}

fn loopbackIpv4(destination: Ipv4, protocol: u8, payload: []const u8) bool {
    var packet: [max_frame]u8 = undefined;
    const bytes = ipv4.build(
        &packet,
        protocol,
        config.ip,
        destination,
        payload,
        nextId(),
    ) orelse return false;
    handleIpv4(bytes, null);
    return true;
}

fn sendFrame(destination: Mac, ethertype: u16, payload: []const u8) bool {
    if (!device_ready) return false;
    if (ethernet.header_len + payload.len > max_frame) return false;

    var frame: [max_frame]u8 = undefined;
    if (!ethernet.write(&frame, .{
        .destination = destination,
        .source = device.mac,
        .ethertype = ethertype,
    })) return false;
    @memcpy(frame[ethernet.header_len .. ethernet.header_len + payload.len], payload);

    const guard = send_lock.acquire();
    defer guard.release();
    return device.transmit_fn(device.context, frame[0 .. ethernet.header_len + payload.len]);
}

fn sendArp(operation: u16, destination_mac: Mac, target_mac: Mac, target_ip: Ipv4) bool {
    var buffer: [arp.packet_len]u8 = undefined;
    const packet = arp.build(
        &buffer,
        operation,
        device.mac,
        config.ip,
        target_mac,
        target_ip,
    ) orelse return false;
    return sendFrame(destination_mac, ethernet.ethertype_arp, packet);
}

fn cacheLookup(address: Ipv4) ?Mac {
    const guard = state_lock.acquire();
    defer guard.release();
    for (arp_table) |entry| {
        if (entry.valid and types.ipv4Eql(entry.ip, address)) return entry.mac;
    }
    return null;
}

fn cacheStore(address: Ipv4, address_mac: Mac) void {
    if (types.ipv4IsUnspecified(address)) return;
    const guard = state_lock.acquire();
    defer guard.release();

    var empty: ?usize = null;
    for (&arp_table, 0..) |*entry, index| {
        if (entry.valid and types.ipv4Eql(entry.ip, address)) {
            entry.mac = address_mac;
            return;
        }
        if (!entry.valid and empty == null) empty = index;
    }
    const slot = empty orelse 0;
    arp_table[slot] = .{ .ip = address, .mac = address_mac, .valid = true };
}

fn takeDatagram(port: u16, buffer: []u8) ?Datagram {
    const guard = state_lock.acquire();
    defer guard.release();

    for (&sockets) |*socket| {
        if (!socket.used or socket.port != port or !socket.ready) continue;
        const length = @min(socket.length, buffer.len);
        @memcpy(buffer[0..length], socket.data[0..length]);
        socket.ready = false;
        socket.length = 0;
        return .{
            .source = socket.source,
            .source_port = socket.source_port,
            .len = length,
        };
    }
    return null;
}

fn nextId() u16 {
    const value = next_identification;
    next_identification +%= 1;
    return value;
}

fn hasPendingReply() bool {
    const guard = state_lock.acquire();
    defer guard.release();
    return pending_reply;
}

fn clearPendingIcmp() void {
    const guard = state_lock.acquire();
    defer guard.release();
    pending_icmp = false;
    pending_reply = false;
}
