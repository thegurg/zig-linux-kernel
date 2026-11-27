//! UDP datagram framing with the IPv4 pseudo-header checksum.

const std = @import("std");
const types = @import("types.zig");
const checksum = @import("checksum.zig");

pub const header_len = 8;
const protocol_udp: u8 = 17;

pub const View = struct {
    source_port: u16,
    destination_port: u16,
    payload: []const u8,
};

pub fn parse(packet: []const u8) ?View {
    if (packet.len < header_len) return null;
    const length = std.mem.readInt(u16, packet[4..6], .big);
    if (length < header_len or length > packet.len) return null;
    return .{
        .source_port = std.mem.readInt(u16, packet[0..2], .big),
        .destination_port = std.mem.readInt(u16, packet[2..4], .big),
        .payload = packet[header_len..length],
    };
}

pub fn build(
    out: []u8,
    source_ip: types.Ipv4,
    destination_ip: types.Ipv4,
    source_port: u16,
    destination_port: u16,
    payload: []const u8,
) ?[]const u8 {
    const total = header_len + payload.len;
    if (total > 0xffff or out.len < total) return null;
    std.mem.writeInt(u16, out[0..2], source_port, .big);
    std.mem.writeInt(u16, out[2..4], destination_port, .big);
    std.mem.writeInt(u16, out[4..6], @intCast(total), .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    @memcpy(out[header_len..total], payload);

    const value = checksumFor(source_ip, destination_ip, out[0..total]);
    std.mem.writeInt(u16, out[6..8], if (value == 0) 0xffff else value, .big);
    return out[0..total];
}

/// Validate a received datagram. A zero checksum is legal for IPv4 and is
/// treated as "not supplied".
pub fn checksumValid(source_ip: types.Ipv4, destination_ip: types.Ipv4, packet: []const u8) bool {
    if (packet.len < header_len) return false;
    const stored = std.mem.readInt(u16, packet[6..8], .big);
    if (stored == 0) return true;
    const length = std.mem.readInt(u16, packet[4..6], .big);
    if (length < header_len or length > packet.len) return false;
    return checksumFor(source_ip, destination_ip, packet[0..length]) == stored;
}

fn checksumFor(source_ip: types.Ipv4, destination_ip: types.Ipv4, packet: []const u8) u16 {
    var total: u32 = 0;
    total += checksum.sum(&source_ip);
    total += checksum.sum(&destination_ip);
    total += @as(u32, protocol_udp);
    total += @as(u32, @intCast(packet.len));
    total += checksum.sum(packet[0..6]);
    total += checksum.sum(packet[8..]);
    return ~checksum.fold(total);
}

test "datagram round trip and pseudo-header checksum" {
    const source = types.Ipv4{ 10, 0, 2, 15 };
    const destination = types.Ipv4{ 10, 0, 2, 3 };
    var buffer: [128]u8 = undefined;
    const packet = build(&buffer, source, destination, 49160, 53, "query").?;
    const view = parse(packet).?;
    try std.testing.expectEqual(@as(u16, 49160), view.source_port);
    try std.testing.expectEqual(@as(u16, 53), view.destination_port);
    try std.testing.expectEqualSlices(u8, "query", view.payload);
    try std.testing.expect(checksumValid(source, destination, packet));
}

test "rejects a corrupt datagram checksum" {
    const source = types.Ipv4{ 10, 0, 2, 15 };
    const destination = types.Ipv4{ 10, 0, 2, 3 };
    var buffer: [128]u8 = undefined;
    _ = build(&buffer, source, destination, 1, 2, "x").?;
    buffer[8] ^= 0x40;
    try std.testing.expect(!checksumValid(source, destination, &buffer));
}
