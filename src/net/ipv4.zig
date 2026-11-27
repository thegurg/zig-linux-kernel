//! IPv4 header parsing and construction.
//!
//! M19 accepts only unfragmented packets with a valid header checksum. Sending
//! always emits a 20-byte header, TTL 64, and a unique identification field.

const std = @import("std");
const types = @import("types.zig");
const checksum = @import("checksum.zig");

pub const header_len = 20;
pub const protocol_icmp: u8 = 1;
pub const protocol_udp: u8 = 17;

pub const View = struct {
    source: types.Ipv4,
    destination: types.Ipv4,
    protocol: u8,
    ttl: u8,
    id: u16,
    payload: []const u8,
};

pub fn parse(packet: []const u8) ?View {
    if (packet.len < header_len) return null;
    if ((packet[0] >> 4) != 4) return null;
    const ihl: usize = @as(usize, packet[0] & 0x0f) * 4;
    if (ihl < header_len or ihl > packet.len) return null;

    const total_len = std.mem.readInt(u16, packet[2..4], .big);
    if (total_len < ihl or total_len > packet.len) return null;
    if (checksum.onesComplement(packet[0..ihl]) != 0) return null;

    const flags_fragment = std.mem.readInt(u16, packet[6..8], .big);
    if ((flags_fragment & 0x1fff) != 0) return null; // fragmentation is unsupported

    return .{
        .source = types.ipv4FromSlice(packet[12..16]).?,
        .destination = types.ipv4FromSlice(packet[16..20]).?,
        .protocol = packet[9],
        .ttl = packet[8],
        .id = std.mem.readInt(u16, packet[4..6], .big),
        .payload = packet[ihl..total_len],
    };
}

pub fn build(
    out: []u8,
    protocol: u8,
    source: types.Ipv4,
    destination: types.Ipv4,
    payload: []const u8,
    id: u16,
) ?[]const u8 {
    const total = header_len + payload.len;
    if (total > 0xffff or out.len < total) return null;

    out[0] = 0x45;
    out[1] = 0;
    std.mem.writeInt(u16, out[2..4], @intCast(total), .big);
    std.mem.writeInt(u16, out[4..6], id, .big);
    std.mem.writeInt(u16, out[6..8], 0x4000, .big); // don't fragment
    out[8] = 64;
    out[9] = protocol;
    std.mem.writeInt(u16, out[10..12], 0, .big);
    @memcpy(out[12..16], &source);
    @memcpy(out[16..20], &destination);
    @memcpy(out[header_len..total], payload);

    const header_checksum = checksum.onesComplement(out[0..header_len]);
    std.mem.writeInt(u16, out[10..12], header_checksum, .big);
    return out[0..total];
}

/// True when `address` is reachable without leaving the configured subnet.
pub fn sameSubnet(address: types.Ipv4, local: types.Ipv4, netmask: types.Ipv4) bool {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        if ((address[index] & netmask[index]) != (local[index] & netmask[index])) return false;
    }
    return true;
}

test "build and parse a UDP-shaped packet" {
    const source = types.Ipv4{ 10, 0, 2, 15 };
    const destination = types.Ipv4{ 10, 0, 2, 2 };
    const payload = "hello";

    var buffer: [64]u8 = undefined;
    const packet = build(&buffer, protocol_udp, source, destination, payload, 0x1234).?;
    const view = parse(packet).?;
    try std.testing.expectEqualSlices(u8, &source, &view.source);
    try std.testing.expectEqualSlices(u8, &destination, &view.destination);
    try std.testing.expectEqual(protocol_udp, view.protocol);
    try std.testing.expectEqual(@as(u16, 0x1234), view.id);
    try std.testing.expectEqualSlices(u8, payload, view.payload);
}

test "rejects a corrupt header checksum" {
    var buffer: [64]u8 = undefined;
    _ = build(&buffer, protocol_icmp, .{ 10, 0, 2, 15 }, .{ 10, 0, 2, 2 }, "x", 1).?;
    buffer[10] ^= 0xff;
    try std.testing.expect(parse(&buffer) == null);
}

test "subnet comparison honours the mask" {
    const mask = types.Ipv4{ 255, 255, 255, 0 };
    try std.testing.expect(sameSubnet(.{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 }, mask));
    try std.testing.expect(!sameSubnet(.{ 10, 0, 3, 2 }, .{ 10, 0, 2, 15 }, mask));
}
