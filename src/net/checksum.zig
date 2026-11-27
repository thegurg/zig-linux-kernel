//! Internet checksum helpers (RFC 1071).
//!
//! `sum` accumulates 16-bit big-endian words and `fold` carries the high half
//! back into the low half. `onesComplement` is the finished checksum used by
//! IPv4 and ICMP. UDP mixes the pseudo-header words into the same accumulator.

pub fn sum(data: []const u8) u32 {
    var total: u32 = 0;
    var index: usize = 0;
    while (index + 1 < data.len) : (index += 2) {
        total += (@as(u32, data[index]) << 8) | data[index + 1];
    }
    if (index < data.len) total += @as(u32, data[index]) << 8;
    return total;
}

pub fn fold(initial: u32) u16 {
    var value = initial;
    while ((value >> 16) != 0) value = (value & 0xffff) + (value >> 16);
    return @truncate(value);
}

pub fn onesComplement(data: []const u8) u16 {
    return ~fold(sum(data));
}

test "checksum matches a known IPv4 header" {
    const std = @import("std");
    // A minimal IPv4 header with the checksum field zeroed.
    const header = [_]u8{
        0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00,
        0x40, 0x06, 0x00, 0x00, 0xac, 0x10, 0x0a, 0x63,
        0xac, 0x10, 0x0a, 0x0c,
    };
    try std.testing.expectEqual(@as(u16, 0xb1e6), onesComplement(&header));
}

test "checksum handles odd lengths" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 0xffff), onesComplement(&[_]u8{0}));
    try std.testing.expectEqual(@as(u16, 0x0000), onesComplement(&[_]u8{ 0xff, 0xff }));
}
