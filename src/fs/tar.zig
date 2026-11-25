//! Read-only ustar/PAX-compatible tar reader for the Limine-module initramfs.
//!
//! The reader walks 512-byte headers, validates the ustar checksum, honours the
//! `prefix` field, and returns the data offset of a matching regular file. Data
//! is read in place: nothing is copied or allocated at mount time.
//!
//! Supported: regular files (`typeflag` `'0'` or NUL) and the `ustar` magic.
//! Skipped: directories, links, device nodes, and PAX extended headers. Those
//! entries are simply not visible through `find`.

const std = @import("std");
const vfs = @import("vfs.zig");

pub const block_size: usize = 512;
pub const max_name = 255;

pub const Error = error{
    InvalidArchive,
    NotFound,
    NotAFile,
    BufferTooSmall,
};

pub const Entry = struct {
    /// Offset of the file's first data byte inside the archive.
    token: u64,
    size: u64,
};

pub fn find(archive: []const u8, path: []const u8) Error!?Entry {
    const wanted = normalize(path);
    if (wanted.len == 0) return null;

    var offset: usize = 0;
    while (offset + block_size <= archive.len) {
        const header = archive[offset..][0..block_size];
        if (allZero(header)) break;
        if (!checksumValid(header)) return error.InvalidArchive;

        const size = parseOctal(header[124..136]) orelse return error.InvalidArchive;
        const typeflag = header[156];
        const data_offset = offset + block_size;
        if (size > @as(u64, archive.len - data_offset)) return error.InvalidArchive;

        if (typeflag == '0' or typeflag == 0) {
            var name_buffer: [max_name]u8 = undefined;
            const name = entryName(header, name_buffer[0..]) orelse return error.InvalidArchive;
            if (std.mem.eql(u8, name, wanted)) {
                return .{ .token = data_offset, .size = size };
            }
        }

        const blocks = (size + block_size - 1) / block_size;
        offset = data_offset + blocks * block_size;
    }

    return null;
}

pub fn readAt(archive: []const u8, entry: Entry, offset: u64, buffer: []u8) usize {
    if (offset >= entry.size or buffer.len == 0) return 0;
    const start = entry.token + offset;
    if (start > @as(u64, archive.len)) return 0;

    const available = @min(@as(u64, archive.len) - start, entry.size - offset);
    const count: usize = @intCast(@min(@as(u64, buffer.len), available));
    const begin: usize = @intCast(start);
    @memcpy(buffer[0..count], archive[begin..][0..count]);
    return count;
}

pub fn readAll(archive: []const u8, entry: Entry, buffer: []u8) ?usize {
    if (@as(u64, buffer.len) < entry.size) return null;
    const read = readAt(archive, entry, 0, buffer[0..@intCast(entry.size)]);
    if (@as(u64, read) != entry.size) return null;
    return read;
}

/// Adapter for the minimal VFS. `context` points at a `[]const u8` slice that
/// must outlive the mount.
pub fn vfsBackend(archive: *const []const u8) vfs.Backend {
    return .{
        .context = @ptrCast(@constCast(archive)),
        .open_fn = vfsOpen,
        .read_fn = vfsRead,
    };
}

fn vfsOpen(context: *anyopaque, path: []const u8) ?vfs.Entry {
    const archive: *const []const u8 = @ptrCast(@alignCast(context));
    const entry = (find(archive.*, path) catch return null) orelse return null;
    return .{ .token = entry.token, .size = entry.size };
}

fn vfsRead(context: *anyopaque, entry: vfs.Entry, offset: u64, buffer: []u8) usize {
    const archive: *const []const u8 = @ptrCast(@alignCast(context));
    const tar_entry = Entry{ .token = entry.token, .size = entry.size };
    return readAt(archive.*, tar_entry, offset, buffer);
}

fn normalize(path: []const u8) []const u8 {
    var result = std.mem.trimStart(u8, path, "/");
    while (std.mem.startsWith(u8, result, "./")) result = result[2..];
    return result;
}

fn allZero(block: []const u8) bool {
    for (block) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn checksumValid(header: []const u8) bool {
    const expected = parseOctal(header[148..156]) orelse return false;
    var sum: u64 = 0;
    for (header, 0..) |byte, index| {
        sum += if (index >= 148 and index < 156) ' ' else byte;
    }
    return sum == expected;
}

fn parseOctal(field: []const u8) ?u64 {
    var value: u64 = 0;
    var seen = false;
    for (field) |byte| {
        if (byte == 0 or byte == ' ') {
            if (seen) break;
            continue;
        }
        if (byte < '0' or byte > '7') return null;
        seen = true;
        value = value * 8 + (byte - '0');
    }
    return if (seen) value else 0;
}

fn entryName(header: []const u8, buffer: []u8) ?[]const u8 {
    const name = trimNul(header[0..100]);
    const prefix = trimNul(header[345..500]);
    if (prefix.len == 0) return name;
    if (prefix.len + 1 + name.len > buffer.len) return null;
    @memcpy(buffer[0..prefix.len], prefix);
    buffer[prefix.len] = '/';
    @memcpy(buffer[prefix.len + 1 ..][0..name.len], name);
    return buffer[0 .. prefix.len + 1 + name.len];
}

fn trimNul(field: []const u8) []const u8 {
    var length: usize = 0;
    while (length < field.len and field[length] != 0) length += 1;
    return field[0..length];
}

test "find and read files from a ustar archive" {
    var archive: [4096]u8 = @splat(0);
    var offset: usize = 0;
    offset = writeEntry(archive[0..], offset, "HELLO.TXT", "hello from tar\n");
    _ = writeEntry(archive[0..], offset, "SUB/NESTED.TXT", "nested tar contents");

    const hello = (try find(archive[0..], "/HELLO.TXT")).?;
    var buffer: [64]u8 = undefined;
    const read = readAll(archive[0..], hello, &buffer).?;
    try std.testing.expectEqualStrings("hello from tar\n", buffer[0..read]);

    const nested = (try find(archive[0..], "SUB/NESTED.TXT")).?;
    const nested_read = readAll(archive[0..], nested, &buffer).?;
    try std.testing.expectEqualStrings("nested tar contents", buffer[0..nested_read]);

    try std.testing.expect((try find(archive[0..], "MISSING.TXT")) == null);
}

test "reject a corrupt checksum" {
    var archive: [1024]u8 = @splat(0);
    _ = writeEntry(archive[0..], 0, "HELLO.TXT", "data");
    archive[0] ^= 0xff;
    try std.testing.expectError(error.InvalidArchive, find(archive[0..], "HELLO.TXT"));
}

fn writeEntry(archive: []u8, offset: usize, name: []const u8, contents: []const u8) usize {
    const header = archive[offset..][0..block_size];
    @memset(header, 0);
    @memcpy(header[0..name.len], name);
    writeOctal(header[100..108], 0o644);
    writeOctal(header[108..116], 0);
    writeOctal(header[116..124], 0);
    writeOctal(header[124..136], contents.len);
    writeOctal(header[136..148], 0);
    header[156] = '0';
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");

    // Checksum with the field treated as spaces.
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header) |byte| sum += byte;
    writeOctal(header[148..155], sum);
    header[155] = ' ';

    const data_offset = offset + block_size;
    @memcpy(archive[data_offset..][0..contents.len], contents);
    const blocks = (contents.len + block_size - 1) / block_size;
    return data_offset + blocks * block_size;
}

fn writeOctal(field: []u8, value: u64) void {
    var temp: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(temp[0..], "{o}", .{value}) catch unreachable;
    const width = field.len - 1;
    @memset(field, '0');
    @memcpy(field[width - digits.len ..][0..digits.len], digits);
    field[width] = 0;
}
