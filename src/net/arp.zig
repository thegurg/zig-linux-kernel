//! ARP (RFC 826) request and reply framing for Ethernet/IPv4.

const std = @import("std");
const types = @import("types.zig");

pub const packet_len = 28;
pub const hardware_ethernet: u16 = 1;
pub const protocol_ipv4: u16 = 0x0800;
pub const operation_request: u16 = 1;
pub const operation_reply: u16 = 2;

pub const Packet = struct {
    operation: u16,
    sender_mac: types.Mac,
    sender_ip: types.Ipv4,
    target_mac: types.Mac,
    target_ip: types.Ipv4,
};

pub fn parse(payload: []const u8) ?Packet {
    if (payload.len < packet_len) return null;
    if (std.mem.readInt(u16, payload[0..2], .big) != hardware_ethernet) return null;
    if (std.mem.readInt(u16, payload[2..4], .big) != protocol_ipv4) return null;
    if (payload[4] != 6 or payload[5] != 4) return null;
    return .{
        .operation = std.mem.readInt(u16, payload[6..8], .big),
        .sender_mac = types.macFromSlice(payload[8..14]).?,
        .sender_ip = types.ipv4FromSlice(payload[14..18]).?,
        .target_mac = types.macFromSlice(payload[18..24]).?,
        .target_ip = types.ipv4FromSlice(payload[24..28]).?,
    };
}

pub fn build(
    out: []u8,
    operation: u16,
    sender_mac: types.Mac,
    sender_ip: types.Ipv4,
    target_mac: types.Mac,
    target_ip: types.Ipv4,
) ?[]const u8 {
    if (out.len < packet_len) return null;
    std.mem.writeInt(u16, out[0..2], hardware_ethernet, .big);
    std.mem.writeInt(u16, out[2..4], protocol_ipv4, .big);
    out[4] = 6;
    out[5] = 4;
    std.mem.writeInt(u16, out[6..8], operation, .big);
    @memcpy(out[8..14], &sender_mac);
    @memcpy(out[14..18], &sender_ip);
    @memcpy(out[18..24], &target_mac);
    @memcpy(out[24..28], &target_ip);
    return out[0..packet_len];
}

test "request and reply round trip" {
    var buffer: [packet_len]u8 = undefined;
    const sender_mac = types.Mac{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const target_mac = types.mac_broadcast;
    const sender_ip = types.Ipv4{ 10, 0, 2, 15 };
    const target_ip = types.Ipv4{ 10, 0, 2, 2 };

    const bytes = build(&buffer, operation_request, sender_mac, sender_ip, target_mac, target_ip).?;
    const parsed = parse(bytes).?;
    try std.testing.expectEqual(operation_request, parsed.operation);
    try std.testing.expectEqualSlices(u8, &sender_mac, &parsed.sender_mac);
    try std.testing.expectEqualSlices(u8, &sender_ip, &parsed.sender_ip);
    try std.testing.expectEqualSlices(u8, &target_mac, &parsed.target_mac);
    try std.testing.expectEqualSlices(u8, &target_ip, &parsed.target_ip);
}

test "rejects a truncated packet" {
    try std.testing.expect(parse(&[_]u8{ 0, 1, 8, 0 }) == null);
}
