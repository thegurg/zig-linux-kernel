//! Read-only FAT16/FAT32 driver.
//!
//! The driver parses the BPB from sector 0, walks directory entries (including
//! VFAT long file names), follows cluster chains, and reads file contents at an
//! arbitrary offset. It never writes and never allocates: every buffer it needs
//! is a 512-byte stack buffer supplied by the caller's call chain.
//!
//! Deliberate limits, all reported as errors rather than guesses:
//! - 512-byte logical sectors only (`UnsupportedSectorSize`);
//! - FAT12 volumes are rejected (`UnsupportedFat12`);
//! - paths are ASCII and use `/` or `\\` separators; `..` is not resolved.
//!
//! `mount` leaves the caller-owned `Volume` valid for as long as the backing
//! block device stays alive. The module has no kernel dependencies, so the host
//! unit tests build FAT16 and FAT32 images in memory and exercise the same code
//! the kernel runs.

const std = @import("std");
const block = @import("block.zig");
const vfs = @import("vfs.zig");

pub const sector_size: u32 = 512;
pub const max_lfn_chars = 255;

pub const Error = error{
    IoError,
    NotFat,
    UnsupportedSectorSize,
    UnsupportedFat12,
    Corrupt,
    NotFound,
    NotAFile,
    NotADirectory,
    UnsupportedPath,
    BufferTooSmall,
};

pub const FatType = enum { fat16, fat32 };

pub const Volume = struct {
    device: block.Device,
    bytes_per_sector: u16 = 0,
    sectors_per_cluster: u8 = 0,
    reserved_sectors: u16 = 0,
    fat_count: u8 = 0,
    root_entry_count: u16 = 0,
    total_sectors: u32 = 0,
    fat_sectors: u32 = 0,
    root_dir_sectors: u32 = 0,
    first_data_sector: u32 = 0,
    root_cluster: u32 = 0,
    cluster_count: u32 = 0,
    fat_type: FatType = .fat16,
};

pub const Entry = struct {
    first_cluster: u32,
    size: u32,
    attributes: u8,

    pub fn isDirectory(self: Entry) bool {
        return (self.attributes & attribute_directory) != 0;
    }
};

const attribute_read_only: u8 = 0x01;
const attribute_directory: u8 = 0x10;
const attribute_volume_id: u8 = 0x08;
const attribute_lfn: u8 = 0x0f;

const DirRef = union(enum) {
    root,
    cluster: u32,
};

pub fn mount(volume: *Volume, device: block.Device) Error!void {
    if (device.sector_size != sector_size) return error.UnsupportedSectorSize;

    var boot: [sector_size]u8 = undefined;
    if (!device.read(0, boot[0..])) return error.IoError;
    if (boot[510] != 0x55 or boot[511] != 0xaa) return error.NotFat;

    const bytes_per_sector = std.mem.readInt(u16, boot[11..13], .little);
    const sectors_per_cluster = boot[13];
    const reserved_sectors = std.mem.readInt(u16, boot[14..16], .little);
    const fat_count = boot[16];
    const root_entry_count = std.mem.readInt(u16, boot[17..19], .little);
    const total16 = std.mem.readInt(u16, boot[19..21], .little);
    const fat16 = std.mem.readInt(u16, boot[22..24], .little);
    const total32 = std.mem.readInt(u32, boot[32..36], .little);
    const fat32 = std.mem.readInt(u32, boot[36..40], .little);
    const root_cluster = std.mem.readInt(u32, boot[44..48], .little);

    if (bytes_per_sector != sector_size) return error.UnsupportedSectorSize;
    if (sectors_per_cluster == 0 or !std.math.isPowerOfTwo(sectors_per_cluster)) return error.NotFat;
    if (reserved_sectors == 0 or fat_count == 0) return error.NotFat;

    const total_sectors: u32 = if (total16 != 0) total16 else total32;
    const fat_sectors: u32 = if (fat16 != 0) fat16 else fat32;
    if (total_sectors == 0 or fat_sectors == 0) return error.NotFat;

    const root_dir_sectors: u32 = (@as(u32, root_entry_count) * 32 + sector_size - 1) / sector_size;
    const first_data_sector: u32 = @as(u32, reserved_sectors) +
        @as(u32, fat_count) * fat_sectors +
        root_dir_sectors;
    if (first_data_sector >= total_sectors) return error.NotFat;

    const data_sectors = total_sectors - first_data_sector;
    const cluster_count = data_sectors / sectors_per_cluster;
    if (cluster_count < 1) return error.NotFat;

    const fat_type: FatType = if (fat16 != 0) .fat16 else .fat32;
    if (fat_type == .fat16 and cluster_count < 4085) return error.UnsupportedFat12;
    if (fat_type == .fat32 and cluster_count < 65525) return error.Corrupt;
    if (fat_type == .fat32 and root_cluster < 2) return error.Corrupt;

    volume.* = .{
        .device = device,
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sectors = reserved_sectors,
        .fat_count = fat_count,
        .root_entry_count = root_entry_count,
        .total_sectors = total_sectors,
        .fat_sectors = fat_sectors,
        .root_dir_sectors = root_dir_sectors,
        .first_data_sector = first_data_sector,
        .root_cluster = if (fat_type == .fat32) root_cluster else 0,
        .cluster_count = cluster_count,
        .fat_type = fat_type,
    };
}

/// Look up a file or directory. Returns null when the path does not exist.
pub fn find(volume: *const Volume, path: []const u8) Error!?Entry {
    var rest = std.mem.trim(u8, path, "/\\");
    if (rest.len == 0) return null;

    var current: DirRef = switch (volume.fat_type) {
        .fat16 => .root,
        .fat32 => .{ .cluster = volume.root_cluster },
    };

    while (true) {
        const separator = std.mem.indexOfAny(u8, rest, "/\\");
        const name = if (separator) |index| rest[0..index] else rest;
        const last = separator == null;

        if (name.len == 0) return null;
        if (std.mem.eql(u8, name, ".")) {
            if (last) return null;
        } else if (std.mem.eql(u8, name, "..")) {
            return error.UnsupportedPath;
        } else {
            const entry = try lookupIn(volume, current, name) orelse return null;
            if (last) return entry;
            if (!entry.isDirectory()) return error.NotADirectory;
            if (entry.first_cluster < 2) return error.Corrupt;
            current = .{ .cluster = entry.first_cluster };
        }

        rest = std.mem.trimStart(u8, rest[separator.? + 1 ..], "/\\");
        if (rest.len == 0) return null;
    }
}

/// Read up to `buffer.len` bytes at `offset`. Returns the byte count; a short
/// read means the file ended or the device failed.
pub fn readAt(volume: *const Volume, entry: Entry, offset: u64, buffer: []u8) usize {
    if (offset >= entry.size or buffer.len == 0) return 0;

    const cluster_bytes = @as(u64, volume.sectors_per_cluster) * sector_size;
    var remaining: usize = @intCast(@min(@as(u64, buffer.len), @as(u64, entry.size) - offset));

    var cluster = entry.first_cluster;
    if (cluster < 2) return 0;

    var skip = offset / cluster_bytes;
    while (skip > 0) : (skip -= 1) {
        cluster = nextCluster(volume, cluster) catch return 0;
        if (cluster < 2) return 0;
    }

    var cluster_offset: u64 = offset % cluster_bytes;
    var written: usize = 0;
    while (remaining > 0) {
        if (cluster < 2 or cluster >= volume.cluster_count + 2) break;

        const sector_in_cluster: u32 = @intCast(cluster_offset / sector_size);
        const in_sector: usize = @intCast(cluster_offset % sector_size);
        const lba = clusterToLba(volume, cluster) + sector_in_cluster;

        var sector: [sector_size]u8 = undefined;
        if (!volume.device.read(lba, sector[0..])) break;

        const count: usize = @min(remaining, @as(usize, sector_size) - in_sector);
        @memcpy(buffer[written..][0..count], sector[in_sector..][0..count]);
        written += count;
        remaining -= count;
        cluster_offset += count;

        if (cluster_offset >= cluster_bytes) {
            cluster_offset = 0;
            cluster = nextCluster(volume, cluster) catch break;
        }
    }

    // A truncated read is still a read of the bytes that arrived; the caller
    // can detect the shortfall by comparing against the entry size.
    return written;
}

/// Read a whole file into `buffer`. Returns null if the buffer is too small.
pub fn readAll(volume: *const Volume, entry: Entry, buffer: []u8) ?usize {
    if (buffer.len < entry.size) return null;
    const read = readAt(volume, entry, 0, buffer);
    if (read != @as(usize, entry.size)) return null;
    return read;
}

pub fn clusterBytes(volume: *const Volume) u64 {
    return @as(u64, volume.sectors_per_cluster) * sector_size;
}

fn lookupIn(volume: *const Volume, dir: DirRef, name: []const u8) Error!?Entry {
    var scanner = Lookup{ .target = name };

    switch (dir) {
        .root => {
            // FAT16 root directory: a fixed region between the FATs and data.
            var lba: u32 = @as(u32, volume.reserved_sectors) + @as(u32, volume.fat_count) * volume.fat_sectors;
            var remaining = volume.root_dir_sectors;
            while (remaining > 0) : (remaining -= 1) {
                var sector: [sector_size]u8 = undefined;
                if (!volume.device.read(lba, sector[0..])) return error.IoError;
                if (scanner.scan(sector[0..])) return scanner.found;
                lba += 1;
            }
        },
        .cluster => |start| {
            var cluster = start;
            var visited: u32 = 0;
            while (cluster >= 2 and cluster < volume.cluster_count + 2) {
                visited += 1;
                if (visited > volume.cluster_count) return error.Corrupt;

                const base = clusterToLba(volume, cluster);
                var sector_index: u32 = 0;
                while (sector_index < volume.sectors_per_cluster) : (sector_index += 1) {
                    var sector: [sector_size]u8 = undefined;
                    if (!volume.device.read(base + sector_index, sector[0..])) return error.IoError;
                    if (scanner.scan(sector[0..])) return scanner.found;
                }
                cluster = try nextCluster(volume, cluster);
            }
        },
    }

    return null;
}

const Lookup = struct {
    target: []const u8,
    lfn: [max_lfn_chars]u16 = undefined,
    lfn_len: usize = 0,
    lfn_next: u8 = 0,
    found: ?Entry = null,

    /// Scan one 512-byte directory sector. Returns true when `found` is set.
    fn scan(self: *Lookup, sector: []const u8) bool {
        var index: usize = 0;
        while (index + 32 <= sector.len) : (index += 32) {
            const raw = sector[index..][0..32];
            if (raw[0] == 0x00) return false; // end of directory
            if (raw[0] == 0xe5) {
                self.resetLfn();
                continue;
            }

            const attributes = raw[11];
            if (attributes == attribute_lfn) {
                self.feedLfn(raw);
                continue;
            }
            if ((attributes & attribute_volume_id) != 0) {
                self.resetLfn();
                continue;
            }

            if (self.matches(raw)) {
                const cluster_high: u32 = if (attributes == attribute_lfn) 0 else std.mem.readInt(u16, raw[20..22], .little);
                const cluster_low = std.mem.readInt(u16, raw[26..28], .little);
                self.found = .{
                    .first_cluster = (cluster_high << 16) | cluster_low,
                    .size = std.mem.readInt(u32, raw[28..32], .little),
                    .attributes = attributes,
                };
                return true;
            }
            self.resetLfn();
        }
        return false;
    }

    fn feedLfn(self: *Lookup, raw: []const u8) void {
        const sequence = raw[0];
        const number = sequence & 0x1f;
        if (number == 0) {
            self.resetLfn();
            return;
        }

        if ((sequence & 0x40) != 0) {
            self.lfn_len = @min(@as(usize, number) * 13, max_lfn_chars);
            self.lfn_next = number - 1;
        } else if (number != self.lfn_next) {
            self.resetLfn();
            return;
        } else {
            self.lfn_next = number - 1;
        }

        const base = (@as(usize, number) - 1) * 13;
        copyLfnChars(self.lfn[0..], base, raw[1..11]);
        copyLfnChars(self.lfn[0..], base + 5, raw[14..26]);
        copyLfnChars(self.lfn[0..], base + 11, raw[28..32]);
    }

    fn resetLfn(self: *Lookup) void {
        self.lfn_len = 0;
        self.lfn_next = 0;
    }

    fn matches(self: *Lookup, raw: []const u8) bool {
        if (self.lfn_len != 0) {
            const name_len = lfnLength(self.lfn[0..self.lfn_len]);
            if (name_len == self.target.len) {
                var index: usize = 0;
                while (index < name_len) : (index += 1) {
                    const codepoint = self.lfn[index];
                    if (codepoint > 0x7f) return false;
                    if (upper(@intCast(codepoint)) != upper(self.target[index])) return false;
                }
                return true;
            }
            return false;
        }

        var short: [13]u8 = undefined;
        const short_len = formatShortName(raw, short[0..]);
        if (short_len != self.target.len) return false;
        for (short[0..short_len], self.target) |a, b| {
            if (upper(a) != upper(b)) return false;
        }
        return true;
    }
};

fn copyLfnChars(destination: []u16, offset: usize, source: []const u8) void {
    var index: usize = 0;
    while (index + 1 < source.len and offset + index / 2 < destination.len) : (index += 2) {
        destination[offset + index / 2] = std.mem.readInt(u16, source[index..][0..2], .little);
    }
}

fn lfnLength(chars: []const u16) usize {
    for (chars, 0..) |codepoint, index| {
        if (codepoint == 0 or codepoint == 0xffff) return index;
    }
    return chars.len;
}

fn formatShortName(raw: []const u8, output: []u8) usize {
    var length: usize = 0;
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const byte = if (index == 0 and raw[0] == 0x05) 0xe5 else raw[index];
        if (byte == ' ') continue;
        if (length < output.len) {
            output[length] = byte;
            length += 1;
        }
    }
    var extension_length: usize = 0;
    index = 8;
    while (index < 11) : (index += 1) {
        if (raw[index] != ' ') extension_length += 1;
    }
    if (extension_length != 0 and length < output.len) {
        output[length] = '.';
        length += 1;
        index = 8;
        while (index < 11) : (index += 1) {
            if (raw[index] == ' ') continue;
            if (length < output.len) {
                output[length] = raw[index];
                length += 1;
            }
        }
    }
    return length;
}

fn upper(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - ('a' - 'A') else byte;
}

fn clusterToLba(volume: *const Volume, cluster: u32) u32 {
    return volume.first_data_sector + (cluster - 2) * volume.sectors_per_cluster;
}

fn nextCluster(volume: *const Volume, cluster: u32) Error!u32 {
    const entry_size: u64 = if (volume.fat_type == .fat16) 2 else 4;
    const offset = @as(u64, cluster) * entry_size;
    const sector = @as(u32, volume.reserved_sectors) + @as(u32, @intCast(offset / sector_size));
    const index: usize = @intCast(offset % sector_size);

    var buffer: [sector_size]u8 = undefined;
    if (!volume.device.read(sector, buffer[0..])) return error.IoError;

    const value: u32 = switch (volume.fat_type) {
        .fat16 => std.mem.readInt(u16, buffer[index..][0..2], .little),
        .fat32 => std.mem.readInt(u32, buffer[index..][0..4], .little) & 0x0fff_ffff,
    };

    const end: u32 = if (volume.fat_type == .fat16) 0xfff8 else 0x0fff_fff8;
    const bad: u32 = if (volume.fat_type == .fat16) 0xfff7 else 0x0fff_fff7;
    if (value == bad) return error.Corrupt;
    if (value >= end) return end; // caller sees >= cluster_count+2 and stops
    if (value < 2) return end;
    return value;
}

/// Adapter for the minimal VFS. The token packs the first cluster and size so a
/// stateless read can be resumed at any offset.
pub fn vfsBackend(volume: *Volume) vfs.Backend {
    return .{
        .context = @ptrCast(volume),
        .open_fn = vfsOpen,
        .read_fn = vfsRead,
    };
}

fn vfsOpen(context: *anyopaque, path: []const u8) ?vfs.Entry {
    const volume: *Volume = @ptrCast(@alignCast(context));
    const entry = (find(volume, path) catch return null) orelse return null;
    if (entry.isDirectory()) return null;
    return .{
        .token = (@as(u64, entry.first_cluster) << 32) | entry.size,
        .size = entry.size,
    };
}

fn vfsRead(context: *anyopaque, entry: vfs.Entry, offset: u64, buffer: []u8) usize {
    const volume: *Volume = @ptrCast(@alignCast(context));
    const fat_entry = Entry{
        .first_cluster = @truncate(entry.token >> 32),
        .size = @truncate(entry.token),
        .attributes = 0,
    };
    return readAt(volume, fat_entry, offset, buffer);
}

test "mount and read FAT16 files and subdirectories" {
    const allocator = std.testing.allocator;
    const image = try buildFat16(allocator);
    defer allocator.free(image);

    var disk = MemoryDisk{ .data = image };
    var volume: Volume = undefined;
    try mount(&volume, disk.device());
    try std.testing.expectEqual(FatType.fat16, volume.fat_type);
    try std.testing.expect(volume.cluster_count >= 4085);

    const hello = (try find(&volume, "/HELLO.TXT")).?;
    try std.testing.expect(!hello.isDirectory());
    var buffer: [64]u8 = undefined;
    const read = readAll(&volume, hello, &buffer).?;
    try std.testing.expectEqualStrings("hello from fat\n", buffer[0..read]);

    const nested = (try find(&volume, "SUB/NESTED.TXT")).?;
    var nested_buffer: [64]u8 = undefined;
    const nested_read = readAll(&volume, nested, &nested_buffer).?;
    try std.testing.expectEqualStrings("nested file contents", nested_buffer[0..nested_read]);

    try std.testing.expect((try find(&volume, "MISSING.TXT")) == null);
    try std.testing.expectError(error.NotADirectory, find(&volume, "HELLO.TXT/NESTED.TXT"));
}

test "read a file spanning multiple clusters at an offset" {
    const allocator = std.testing.allocator;
    const image = try buildFat16(allocator);
    defer allocator.free(image);

    var disk = MemoryDisk{ .data = image };
    var volume: Volume = undefined;
    try mount(&volume, disk.device());

    const big = (try find(&volume, "BIG.BIN")).?;
    try std.testing.expectEqual(@as(u32, 1300), big.size);

    var buffer: [1300]u8 = undefined;
    const read = readAll(&volume, big, &buffer).?;
    try std.testing.expectEqual(@as(usize, 1300), read);
    for (buffer, 0..) |byte, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index % 251)), byte);
    }

    var tail: [64]u8 = undefined;
    const tail_read = readAt(&volume, big, 1200, &tail);
    try std.testing.expectEqual(@as(usize, 64), tail_read);
    try std.testing.expectEqual(@as(u8, @intCast(1200 % 251)), tail[0]);
}

test "mount and read a FAT32 volume" {
    const allocator = std.testing.allocator;
    const image = try buildFat32(allocator);
    defer allocator.free(image);

    var disk = MemoryDisk{ .data = image };
    var volume: Volume = undefined;
    try mount(&volume, disk.device());
    try std.testing.expectEqual(FatType.fat32, volume.fat_type);

    const hello = (try find(&volume, "HELLO.TXT")).?;
    var buffer: [64]u8 = undefined;
    const read = readAll(&volume, hello, &buffer).?;
    try std.testing.expectEqualStrings("hello fat32\n", buffer[0..read]);
}

test "reject a volume without a boot signature" {
    var sector: [512]u8 = @splat(0);
    var disk = MemoryDisk{ .data = sector[0..] };
    var volume: Volume = undefined;
    try std.testing.expectError(error.NotFat, mount(&volume, disk.device()));
}

const MemoryDisk = struct {
    data: []u8,

    fn device(self: *MemoryDisk) block.Device {
        return .{
            .context = @ptrCast(self),
            .read_fn = read,
            .write_fn = write,
            .sector_size = sector_size,
            .sector_count = self.data.len / sector_size,
        };
    }

    fn read(context: *anyopaque, lba: u64, buffer: []u8) bool {
        const self: *MemoryDisk = @ptrCast(@alignCast(context));
        const start: usize = @intCast(lba * sector_size);
        if (start > self.data.len or buffer.len > self.data.len - start) return false;
        @memcpy(buffer, self.data[start..][0..buffer.len]);
        return true;
    }

    fn write(context: *anyopaque, lba: u64, buffer: []const u8) bool {
        const self: *MemoryDisk = @ptrCast(@alignCast(context));
        const start: usize = @intCast(lba * sector_size);
        if (start > self.data.len or buffer.len > self.data.len - start) return false;
        @memcpy(self.data[start..][0..buffer.len], buffer);
        return true;
    }
};

// ---------------------------------------------------------------------------
// Test image builders. These produce valid FAT16/FAT32 volumes in memory with a
// fixed layout, so the host tests do not depend on external tools or fixtures.
// ---------------------------------------------------------------------------

const ImageSpec = struct {
    total_sectors: u32,
    sectors_per_cluster: u8,
    reserved: u16,
    fat_count: u8,
    root_entries: u16,
    fat_type: FatType,
    root_cluster: u32,
    fat_sectors: u32,
    root_dir_sectors: u32,
    first_data_sector: u32,
};

fn fat16Spec() ImageSpec {
    const total: u32 = 5000;
    const reserved: u16 = 1;
    const fat_count: u8 = 2;
    const root_entries: u16 = 32;
    const root_dir_sectors: u32 = (@as(u32, root_entries) * 32 + sector_size - 1) / sector_size;
    // Two bytes per cluster, two FATs, plus reserved and root directory.
    var fat_sectors: u32 = 1;
    while (true) : (fat_sectors += 1) {
        const data = total - reserved - 2 * fat_sectors - root_dir_sectors;
        const clusters = data;
        if (clusters >= 4085 and clusters <= 65524 and (clusters + 2) * 2 <= fat_sectors * sector_size) break;
    }
    return .{
        .total_sectors = total,
        .sectors_per_cluster = 1,
        .reserved = reserved,
        .fat_count = fat_count,
        .root_entries = root_entries,
        .fat_type = .fat16,
        .root_cluster = 0,
        .fat_sectors = fat_sectors,
        .root_dir_sectors = root_dir_sectors,
        .first_data_sector = reserved + 2 * fat_sectors + root_dir_sectors,
    };
}

fn fat32Spec() ImageSpec {
    const total: u32 = 70000;
    const reserved: u16 = 32;
    const fat_count: u8 = 2;
    const root_entries: u16 = 0;
    const root_dir_sectors: u32 = 0;
    const sectors_per_cluster: u8 = 1;
    var fat_sectors: u32 = 1;
    while (true) : (fat_sectors += 1) {
        const data = total - reserved - 2 * fat_sectors - root_dir_sectors;
        const clusters = data / sectors_per_cluster;
        if (clusters >= 65525 and (clusters + 2) * 4 <= fat_sectors * sector_size) break;
    }
    return .{
        .total_sectors = total,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved = reserved,
        .fat_count = fat_count,
        .root_entries = root_entries,
        .fat_type = .fat32,
        .root_cluster = 2,
        .fat_sectors = fat_sectors,
        .root_dir_sectors = root_dir_sectors,
        .first_data_sector = reserved + 2 * fat_sectors,
    };
}

fn buildFat16(allocator: std.mem.Allocator) ![]u8 {
    const spec = fat16Spec();
    const image = try allocator.alloc(u8, @as(usize, spec.total_sectors) * sector_size);
    @memset(image, 0);
    writeBootSector(image, spec);

    // Clusters: 2 = HELLO.TXT, 3 = SUB, 4 = NESTED.TXT, 5..7 = BIG.BIN.
    setFatEntry(image, spec, 2, 0xffff);
    setFatEntry(image, spec, 3, 0xffff);
    setFatEntry(image, spec, 4, 0xffff);
    setFatEntry(image, spec, 5, 6);
    setFatEntry(image, spec, 6, 7);
    setFatEntry(image, spec, 7, 0xffff);

    const root_offset = @as(usize, spec.reserved + @as(u32, spec.fat_count) * spec.fat_sectors) * sector_size;
    var root_index: usize = 0;
    writeShortEntry(image, root_offset, &root_index, "HELLO   TXT", 0x20, 2, "hello from fat\n".len);
    writeShortEntry(image, root_offset, &root_index, "SUB        ", 0x10, 3, 0);
    writeShortEntry(image, root_offset, &root_index, "BIG     BIN", 0x20, 5, 1300);

    writeFile(image, spec, 2, "hello from fat\n");
    writeFile(image, spec, 4, "nested file contents");

    var big: [1300]u8 = undefined;
    for (&big, 0..) |*byte, index| byte.* = @intCast(index % 251);
    writeFile(image, spec, 5, &big);

    // Directory cluster 3 with one short entry.
    const sub_offset = clusterOffset(spec, 3);
    var sub_index: usize = 0;
    writeShortEntry(image, sub_offset, &sub_index, "NESTED  TXT", 0x20, 4, "nested file contents".len);

    return image;
}

fn buildFat32(allocator: std.mem.Allocator) ![]u8 {
    const spec = fat32Spec();
    const image = try allocator.alloc(u8, @as(usize, spec.total_sectors) * sector_size);
    @memset(image, 0);
    writeBootSector(image, spec);

    setFatEntry(image, spec, 2, 0x0fff_ffff);
    setFatEntry(image, spec, 3, 0x0fff_ffff);

    const root_offset = clusterOffset(spec, 2);
    var root_index: usize = 0;
    writeShortEntry(image, root_offset, &root_index, "HELLO   TXT", 0x20, 3, "hello fat32\n".len);
    writeFile(image, spec, 3, "hello fat32\n");

    return image;
}

fn writeBootSector(image: []u8, spec: ImageSpec) void {
    const boot = image[0..sector_size];
    boot[0] = 0xeb;
    boot[1] = 0x3c;
    boot[2] = 0x90;
    @memcpy(boot[3..11], "ZIGKERNL");
    std.mem.writeInt(u16, boot[11..13], @intCast(sector_size), .little);
    boot[13] = spec.sectors_per_cluster;
    std.mem.writeInt(u16, boot[14..16], spec.reserved, .little);
    boot[16] = spec.fat_count;
    std.mem.writeInt(u16, boot[17..19], spec.root_entries, .little);
    if (spec.fat_type == .fat16) {
        std.mem.writeInt(u16, boot[19..21], @intCast(spec.total_sectors), .little);
        std.mem.writeInt(u16, boot[22..24], @intCast(spec.fat_sectors), .little);
    } else {
        std.mem.writeInt(u16, boot[19..21], 0, .little);
        std.mem.writeInt(u16, boot[22..24], 0, .little);
        std.mem.writeInt(u32, boot[32..36], spec.total_sectors, .little);
        std.mem.writeInt(u32, boot[36..40], spec.fat_sectors, .little);
        std.mem.writeInt(u32, boot[44..48], spec.root_cluster, .little);
        boot[66] = 0x29;
    }
    boot[510] = 0x55;
    boot[511] = 0xaa;
}

fn setFatEntry(image: []u8, spec: ImageSpec, cluster: u32, value: u32) void {
    var copy: u8 = 0;
    while (copy < spec.fat_count) : (copy += 1) {
        const fat_start = (@as(usize, spec.reserved) + @as(usize, copy) * spec.fat_sectors) * sector_size;
        if (spec.fat_type == .fat16) {
            std.mem.writeInt(u16, image[fat_start + @as(usize, cluster) * 2 ..][0..2], @truncate(value), .little);
        } else {
            std.mem.writeInt(u32, image[fat_start + @as(usize, cluster) * 4 ..][0..4], value, .little);
        }
    }
}

fn clusterOffset(spec: ImageSpec, cluster: u32) usize {
    return (@as(usize, spec.first_data_sector) +
        @as(usize, cluster - 2) * @as(usize, spec.sectors_per_cluster)) * @as(usize, sector_size);
}

fn writeShortEntry(
    image: []u8,
    directory_offset: usize,
    index: *usize,
    name: []const u8,
    attributes: u8,
    cluster: u32,
    size: usize,
) void {
    const offset = directory_offset + index.* * 32;
    @memset(image[offset..][0..32], 0);
    @memcpy(image[offset..][0..11], name[0..11]);
    image[offset + 11] = attributes;
    std.mem.writeInt(u16, image[offset + 20 ..][0..2], @truncate(cluster >> 16), .little);
    std.mem.writeInt(u16, image[offset + 26 ..][0..2], @truncate(cluster & 0xffff), .little);
    std.mem.writeInt(u32, image[offset + 28 ..][0..4], @intCast(size), .little);
    index.* += 1;
}

fn writeFile(image: []u8, spec: ImageSpec, first_cluster: u32, contents: []const u8) void {
    var cluster = first_cluster;
    var offset: usize = 0;
    const bytes_per_cluster = @as(usize, spec.sectors_per_cluster) * sector_size;
    while (offset < contents.len) {
        const destination = clusterOffset(spec, cluster);
        const count = @min(contents.len - offset, bytes_per_cluster);
        @memcpy(image[destination..][0..count], contents[offset..][0..count]);
        offset += count;
        if (offset < contents.len) cluster += 1;
    }
}
