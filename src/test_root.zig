//! Host-side test root. Only pure, platform-independent modules may be
//! imported here; kernel subsystems are exercised through the QEMU smoke test.

const std = @import("std");

// Importing a module from a test block makes its own tests part of the host
// test binary. `limine.zig` only contains structure definitions and compile-time
// markers, so it does not depend on kernel or architecture state.
test {
    _ = @import("limine.zig");
    _ = @import("fs/block.zig");
    _ = @import("fs/fat.zig");
    _ = @import("fs/tar.zig");
    _ = @import("fs/vfs.zig");
    _ = @import("net/arp.zig");
    _ = @import("net/checksum.zig");
    _ = @import("net/dns.zig");
    _ = @import("net/ethernet.zig");
    _ = @import("net/icmp.zig");
    _ = @import("net/ipv4.zig");
    _ = @import("net/udp.zig");
}

test "host test harness works" {
    try std.testing.expectEqual(@as(u32, 42), 40 + 2);
}
