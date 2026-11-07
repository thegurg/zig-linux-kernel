//! Host-side test root. Only pure, platform-independent modules may be
//! imported here; kernel subsystems are exercised through the QEMU smoke test.

const std = @import("std");

// Importing a module from a test block makes its own tests part of the host
// test binary. `limine.zig` only contains structure definitions and compile-time
// markers, so it does not depend on kernel or architecture state.
test {
    _ = @import("limine.zig");
}

test "host test harness works" {
    try std.testing.expectEqual(@as(u32, 42), 40 + 2);
}
