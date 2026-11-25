//! Storage bring-up shared by normal boot and the M18 selftest.
//!
//! The sequence is intentionally non-fatal: a machine without a legacy
//! virtio-blk device still boots, and the caller can inspect which layers came
//! up. The VFS is reset and mounted only once per call; a second call rebuilds
//! the same mounts from the current device state.

const pci = @import("drivers/pci.zig");
const virtio_blk = @import("drivers/virtio_blk.zig");
const fat = @import("fs/fat.zig");
const tar = @import("fs/tar.zig");
const vfs = @import("fs/vfs.zig");
const initramfs = @import("initramfs.zig");

pub const Status = struct {
    pci_devices: usize = 0,
    virtio: bool = false,
    fat: bool = false,
    initramfs: bool = false,
    blk: ?virtio_blk.Info = null,
    virtio_error: ?anyerror = null,
    fat_error: ?anyerror = null,
    initramfs_bytes: usize = 0,
};

var volume: fat.Volume = undefined;
var archive_data: []const u8 = &.{};

pub fn init() Status {
    var status = Status{};
    status.pci_devices = pci.init();

    if (pci.find(pci.virtio_vendor_id, pci.virtio_legacy_blk_device_id) == null) {
        return status;
    }

    const info = virtio_blk.init() catch |err| {
        status.virtio_error = err;
        return status;
    };
    status.virtio = true;
    status.blk = info;

    fat.mount(&volume, virtio_blk.blockDevice()) catch |err| {
        status.fat_error = err;
        return status;
    };
    status.fat = true;

    vfs.reset();
    _ = vfs.mount("/", fat.vfsBackend(&volume));

    if (initramfs.find()) |found| {
        archive_data = found.data;
        status.initramfs = vfs.mount("/initramfs", tar.vfsBackend(&archive_data));
        status.initramfs_bytes = found.data.len;
    }

    return status;
}

pub fn fatVolume() ?*fat.Volume {
    return &volume;
}

pub fn archive() ?[]const u8 {
    if (archive_data.len == 0) return null;
    return archive_data;
}
