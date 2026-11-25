//! Bridge between Limine modules and the tar reader.
//!
//! The test flow passes `initramfs.tar` as a module with `MODULE_STRING`
//! `initramfs`. Limine maps it into the HHDM; this module exposes that slice and
//! nothing else, so `fs/tar.zig` stays free of kernel dependencies.

const std = @import("std");
const limine = @import("limine.zig");

pub const Archive = struct {
    data: []const u8,
    path: []const u8,
    label: []const u8,
};

pub fn find() ?Archive {
    const file = limine.findModule("initramfs") orelse return null;
    if (file.size == 0) return null;

    const address: usize = @intCast(file.address);
    const pointer: [*]const u8 = @ptrFromInt(address);
    return .{
        .data = pointer[0..@intCast(file.size)],
        .path = std.mem.span(file.path),
        .label = std.mem.span(file.string),
    };
}

pub fn count() usize {
    return limine.moduleCount();
}
