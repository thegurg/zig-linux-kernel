//! Ethernet II framing for the virtio-net path.

const std = @import("std");
const types = @import("types.zig");

pub const header_len = 14;
pub const ethertype_ipv4: u16 = 0x0800;
pub const ethertype_arp: u16 = 0x0806;

pub const Header = struct {
    destination: types.Mac,
    source: types.Mac,
    ethertype: u16,
};

pub fn parse(frame: []const u8) ?Header {
    if (frame.len < header_len) return null;
    return .{
        .destination = types.macFromSlice(frame[0..6]).?,
        .source = types.macFromSlice(frame[6..12]).?,
        .ethertype = std.mem.readInt(u16, frame[12..14], .big),
    };
}

pub fn write(frame: []u8, header: Header) bool {
    if (frame.len < header_len) return false;
    @memcpy(frame[0..6], &header.destination);
    @memcpy(frame[6..12], &header.source);
    std.mem.writeInt(u16, frame[12..14], header.ethertype, .big);
    return true;
}

test "header round trip" {
    var buffer: [header_len]u8 = undefined;
    const header = Header{
        .destination = .{ 1, 2, 3, 4, 5, 6 },
        .source = .{ 7, 8, 9, 10, 11, 12 },
        .ethertype = ethertype_ipv4,
    };
    try std.testing.expect(write(&buffer, header));
    const parsed = parse(&buffer).?;
    try std.testing.expectEqualSlices(u8, &header.destination, &parsed.destination);
    try std.testing.expectEqualSlices(u8, &header.source, &parsed.source);
    try std.testing.expectEqual(ethertype_ipv4, parsed.ethertype);
}
