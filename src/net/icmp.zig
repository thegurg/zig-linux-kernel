//! ICMP echo request/reply framing.

const std = @import("std");
const checksum = @import("checksum.zig");

pub const echo_reply: u8 = 0;
pub const echo_request: u8 = 8;
pub const header_len = 8;

pub const View = struct {
    message_type: u8,
    code: u8,
    id: u16,
    sequence: u16,
    data: []const u8,
};

pub fn parse(packet: []const u8) ?View {
    if (packet.len < header_len) return null;
    if (checksum.onesComplement(packet) != 0) return null;
    return .{
        .message_type = packet[0],
        .code = packet[1],
        .id = std.mem.readInt(u16, packet[4..6], .big),
        .sequence = std.mem.readInt(u16, packet[6..8], .big),
        .data = packet[header_len..],
    };
}

pub fn build(
    out: []u8,
    message_type: u8,
    code: u8,
    id: u16,
    sequence: u16,
    data: []const u8,
) ?[]const u8 {
    const total = header_len + data.len;
    if (out.len < total) return null;
    out[0] = message_type;
    out[1] = code;
    std.mem.writeInt(u16, out[2..4], 0, .big);
    std.mem.writeInt(u16, out[4..6], id, .big);
    std.mem.writeInt(u16, out[6..8], sequence, .big);
    @memcpy(out[header_len..total], data);
    const value = checksum.onesComplement(out[0..total]);
    std.mem.writeInt(u16, out[2..4], value, .big);
    return out[0..total];
}

test "echo round trip and checksum" {
    var buffer: [64]u8 = undefined;
    const packet = build(&buffer, echo_request, 0, 0x4d19, 7, "ping payload").?;
    const view = parse(packet).?;
    try std.testing.expectEqual(echo_request, view.message_type);
    try std.testing.expectEqual(@as(u16, 0x4d19), view.id);
    try std.testing.expectEqual(@as(u16, 7), view.sequence);
    try std.testing.expectEqualSlices(u8, "ping payload", view.data);
}

test "rejects a corrupt echo checksum" {
    var buffer: [64]u8 = undefined;
    _ = build(&buffer, echo_request, 0, 1, 1, "x").?;
    buffer[3] ^= 1;
    try std.testing.expect(parse(&buffer) == null);
}
