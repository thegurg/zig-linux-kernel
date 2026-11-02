//! Host-side test root. Only pure, platform-independent modules may be
//! imported here; kernel subsystems are exercised through the QEMU smoke test.

const std = @import("std");

test "host test harness works" {
    try std.testing.expectEqual(@as(u32, 42), 40 + 2);
}
