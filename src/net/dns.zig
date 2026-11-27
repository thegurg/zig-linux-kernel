//! Minimal DNS query encoder and A-record decoder.
//!
//! The live query is sent through QEMU user-mode networking; the encoder and
//! decoder are pure and covered by host tests so the wire format is checked
//! even when the host resolver is unavailable.

const std = @import("std");
const types = @import("types.zig");

pub const Error = error{
    NameTooLong,
    BufferTooSmall,
};

const header_len = 12;
const type_a: u16 = 1;
const class_in: u16 = 1;

pub fn buildQuery(out: []u8, id: u16, name: []const u8) Error![]const u8 {
    if (out.len < header_len + 5) return error.BufferTooSmall;

    var offset: usize = header_len;
    var labels: usize = 0;
    var iterator = std.mem.splitScalar(u8, name, '.');
    while (iterator.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.NameTooLong;
        if (offset + 1 + label.len + 1 + 4 > out.len) return error.BufferTooSmall;
        out[offset] = @intCast(label.len);
        offset += 1;
        @memcpy(out[offset .. offset + label.len], label);
        offset += label.len;
        labels += 1;
        if (labels > 127) return error.NameTooLong;
    }
    if (labels == 0) return error.NameTooLong;

    out[offset] = 0;
    offset += 1;
    if (offset + 4 > out.len) return error.BufferTooSmall;
    std.mem.writeInt(u16, out[offset..][0..2], type_a, .big);
    std.mem.writeInt(u16, out[offset + 2 ..][0..2], class_in, .big);
    offset += 4;

    std.mem.writeInt(u16, out[0..2], id, .big);
    std.mem.writeInt(u16, out[2..4], 0x0100, .big); // recursion desired
    std.mem.writeInt(u16, out[4..6], 1, .big); // questions
    std.mem.writeInt(u16, out[6..8], 0, .big); // answers
    std.mem.writeInt(u16, out[8..10], 0, .big); // authority
    std.mem.writeInt(u16, out[10..12], 0, .big); // additional
    return out[0..offset];
}

pub fn firstAddress(response: []const u8) ?types.Ipv4 {
    if (response.len < header_len) return null;
    const flags = std.mem.readInt(u16, response[2..4], .big);
    if ((flags & 0x8000) == 0) return null; // not a response
    if ((flags & 0x000f) != 0) return null; // non-zero rcode

    const questions = std.mem.readInt(u16, response[4..6], .big);
    const answers = std.mem.readInt(u16, response[6..8], .big);

    var offset: usize = header_len;
    var index: usize = 0;
    while (index < questions) : (index += 1) {
        if (index >= 128) return null;
        offset = skipName(response, offset) orelse return null;
        if (offset + 4 > response.len) return null;
        offset += 4;
    }

    index = 0;
    while (index < answers) : (index += 1) {
        if (index >= 128) return null;
        offset = skipName(response, offset) orelse return null;
        if (offset + 10 > response.len) return null;
        const record_type = std.mem.readInt(u16, response[offset..][0..2], .big);
        const record_class = std.mem.readInt(u16, response[offset + 2 ..][0..2], .big);
        const data_len = std.mem.readInt(u16, response[offset + 8 ..][0..2], .big);
        offset += 10;
        if (offset + data_len > response.len) return null;
        if (record_type == type_a and record_class == class_in and data_len == 4) {
            return types.ipv4FromSlice(response[offset .. offset + 4]);
        }
        offset += data_len;
    }
    return null;
}

fn skipName(packet: []const u8, start: usize) ?usize {
    var offset = start;
    var steps: usize = 0;
    while (steps < 128) : (steps += 1) {
        if (offset >= packet.len) return null;
        const length = packet[offset];
        if ((length & 0xc0) == 0xc0) {
            if (offset + 1 >= packet.len) return null;
            return offset + 2;
        }
        if ((length & 0xc0) != 0) return null;
        if (length == 0) return offset + 1;
        offset += 1 + @as(usize, length);
    }
    return null;
}

test "build a query with labels" {
    var buffer: [256]u8 = undefined;
    const query = try buildQuery(&buffer, 0x1234, "example.com");
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, query[0..2], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, query[4..6], .big));
    const expected = [_]u8{
        0x07, 'e', 'x', 'a', 'm',  'p',  'l',  'e',
        0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00,
        0x01,
    };
    try std.testing.expectEqualSlices(u8, &expected, query[12..]);
}

test "decode an answer through a compression pointer" {
    const response = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x07, 'e',  'x',  'a',
        'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01, 0xc0, 0x0c, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00,
        0x04, 93,   184,  216,  34,
    };
    const address = firstAddress(&response).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 93, 184, 216, 34 }, &address);
}

test "reject a truncated answer" {
    const response = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0xc0,
    };
    try std.testing.expect(firstAddress(&response) == null);
}
