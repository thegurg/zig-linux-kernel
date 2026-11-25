//! Minimal mount table and file API used by the kernel's filesystem backends.
//!
//! A backend is two function pointers: `open` resolves a path relative to the
//! mount point, and `read` copies bytes from an opaque entry token. Files are
//! stateless apart from a caller-owned offset, so `open` does not allocate and a
//! `File` value can be copied freely.
//!
//! Mount matching uses the longest matching prefix, so `/` (the FAT root) and
//! `/initramfs` (a tar archive) can coexist. This is intentionally not a POSIX
//! VFS: there are no inodes, permissions, writes, or directory streams yet.

const std = @import("std");

pub const max_mounts = 8;
pub const max_prefix = 32;

pub const Entry = struct {
    /// Backend-private identity for the file.
    token: u64,
    size: u64,
};

pub const Backend = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque, path: []const u8) ?Entry,
    read_fn: *const fn (context: *anyopaque, entry: Entry, offset: u64, buffer: []u8) usize,
};

pub const File = struct {
    backend: *const Backend,
    entry: Entry,
    offset: u64 = 0,

    pub fn read(self: *File, buffer: []u8) usize {
        if (self.offset >= self.entry.size or buffer.len == 0) return 0;
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), self.entry.size - self.offset));
        const bytes = self.backend.read_fn(self.backend.context, self.entry, self.offset, buffer[0..wanted]);
        self.offset += bytes;
        return bytes;
    }

    /// Read the whole file. Returns null when the buffer is too small or the
    /// backend produced a short read.
    pub fn readAll(self: *File, buffer: []u8) ?usize {
        if (@as(u64, buffer.len) < self.entry.size) return null;
        const bytes = self.read(buffer[0..@intCast(self.entry.size)]);
        if (@as(u64, bytes) != self.entry.size) return null;
        return bytes;
    }
};

const Mount = struct {
    prefix: [max_prefix]u8 = @splat(0),
    prefix_len: usize = 0,
    backend: Backend = undefined,
    used: bool = false,
};

var mounts: [max_mounts]Mount = @splat(.{});
var mount_count: usize = 0;

pub fn reset() void {
    mounts = @splat(.{});
    mount_count = 0;
}

/// Mount `backend` at `prefix` (for example `/` or `/initramfs`). The prefix is
/// copied, so the caller's slice need not outlive the mount. Returns false when
/// the prefix is invalid or the table is full.
pub fn mount(prefix: []const u8, backend: Backend) bool {
    if (mount_count >= max_mounts) return false;
    if (prefix.len == 0 or prefix[0] != '/' or prefix.len > max_prefix) return false;

    // Normalise trailing separators, keeping the root prefix as "/".
    var length = prefix.len;
    while (length > 1 and prefix[length - 1] == '/') length -= 1;
    if (length == 0) return false;

    var entry = Mount{ .backend = backend, .used = true, .prefix_len = length };
    @memcpy(entry.prefix[0..length], prefix[0..length]);
    mounts[mount_count] = entry;
    mount_count += 1;
    return true;
}

pub fn count() usize {
    return mount_count;
}

pub fn open(path: []const u8) ?File {
    const resolved = resolve(path) orelse return null;
    return resolved.file;
}

pub fn exists(path: []const u8) bool {
    return open(path) != null;
}

const Resolved = struct {
    file: File,
};

fn resolve(path: []const u8) ?Resolved {
    if (path.len == 0 or path[0] != '/') return null;

    var best: ?*Mount = null;
    var best_length: usize = 0;
    for (mounts[0..mount_count]) |*candidate| {
        if (!candidate.used) continue;
        const prefix = candidate.prefix[0..candidate.prefix_len];
        if (!prefixMatches(path, prefix)) continue;
        if (best == null or prefix.len > best_length) {
            best = candidate;
            best_length = prefix.len;
        }
    }

    const chosen = best orelse return null;
    var relative = path[chosen.prefix_len..];
    relative = std.mem.trimStart(u8, relative, "/");
    if (relative.len == 0) return null;

    const entry = chosen.backend.open_fn(chosen.backend.context, relative) orelse return null;
    return .{ .file = .{ .backend = &chosen.backend, .entry = entry } };
}

fn prefixMatches(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 1 and prefix[0] == '/') return true;
    if (path.len < prefix.len) return false;
    if (!std.mem.eql(u8, path[0..prefix.len], prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

test "longest prefix wins and file offsets advance" {
    reset();
    defer reset();

    var root = FakeBackend{ .contents = "root-file" };
    var nested = FakeBackend{ .contents = "nested-file" };
    try std.testing.expect(mount("/", root.backend()));
    try std.testing.expect(mount("/initramfs", nested.backend()));

    var root_file = open("/HELLO.TXT").?;
    try std.testing.expectEqualStrings("HELLO.TXT", root.last_path);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 9), root_file.read(&buffer));
    try std.testing.expectEqualStrings("root-file", buffer[0..9]);
    try std.testing.expectEqual(@as(usize, 0), root_file.read(&buffer));

    var nested_file = open("/initramfs/HELLO.TXT").?;
    try std.testing.expectEqualStrings("HELLO.TXT", nested.last_path);
    const read = nested_file.readAll(&buffer).?;
    try std.testing.expectEqualStrings("nested-file", buffer[0..read]);

    try std.testing.expect(open("/initramfs/missing") == null);
    try std.testing.expect(open("relative") == null);
}

test "mount rejects invalid prefixes" {
    reset();
    defer reset();
    var backend = FakeBackend{ .contents = "x" };
    try std.testing.expect(!mount("", backend.backend()));
    try std.testing.expect(!mount("root", backend.backend()));
    try std.testing.expect(mount("/", backend.backend()));
    try std.testing.expect(mount("/a", backend.backend()));
    try std.testing.expectEqual(@as(usize, 2), count());
}

const FakeBackend = struct {
    contents: []const u8,
    last_path: []const u8 = "",

    fn backend(self: *FakeBackend) Backend {
        return .{
            .context = @ptrCast(self),
            .open_fn = openImpl,
            .read_fn = readImpl,
        };
    }

    fn openImpl(context: *anyopaque, path: []const u8) ?Entry {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, "HELLO.TXT")) return null;
        self.last_path = path;
        return .{ .token = 0, .size = self.contents.len };
    }

    fn readImpl(context: *anyopaque, entry: Entry, offset: u64, buffer: []u8) usize {
        _ = entry;
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (offset >= self.contents.len) return 0;
        const start: usize = @intCast(offset);
        const bytes = @min(buffer.len, self.contents.len - start);
        @memcpy(buffer[0..bytes], self.contents[start..][0..bytes]);
        return bytes;
    }
};
