//! Minimal block-device interface shared by drivers and filesystems.
//!
//! The interface is deliberately small: fixed-size sector reads and optional
//! writes at an LBA. `fat.zig` is written against it and can be host-tested
//! with an in-memory device, while `virtio_blk.zig` provides the kernel-side
//! implementation.
//!
//! Range checks live here so every backend sees the same rules: buffers must be
//! a whole number of sectors, and when the device reports a capacity no access
//! may run past it. A `sector_count` of zero means "capacity unknown".

pub const Device = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, lba: u64, buffer: []u8) bool,
    write_fn: ?*const fn (context: *anyopaque, lba: u64, buffer: []const u8) bool = null,
    sector_size: u32 = 512,
    sector_count: u64 = 0,

    pub fn read(self: Device, lba: u64, buffer: []u8) bool {
        if (!self.valid(lba, buffer.len)) return false;
        return self.read_fn(self.context, lba, buffer);
    }

    pub fn write(self: Device, lba: u64, buffer: []const u8) bool {
        const write_fn = self.write_fn orelse return false;
        if (!self.valid(lba, buffer.len)) return false;
        return write_fn(self.context, lba, buffer);
    }

    pub fn isWritable(self: Device) bool {
        return self.write_fn != null;
    }

    fn valid(self: Device, lba: u64, length: usize) bool {
        if (self.sector_size == 0) return false;
        if (length == 0 or length % self.sector_size != 0) return false;
        if (self.sector_count != 0) {
            const sectors = length / self.sector_size;
            if (lba > self.sector_count or sectors > self.sector_count - lba) return false;
        }
        return true;
    }
};
