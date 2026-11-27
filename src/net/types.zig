//! Small address types shared by the M19 network modules.

pub const Mac = [6]u8;
pub const Ipv4 = [4]u8;

pub const mac_broadcast: Mac = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
pub const mac_zero: Mac = .{ 0, 0, 0, 0, 0, 0 };
pub const ipv4_unspecified: Ipv4 = .{ 0, 0, 0, 0 };
pub const ipv4_broadcast: Ipv4 = .{ 255, 255, 255, 255 };

pub fn macEql(a: Mac, b: Mac) bool {
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

pub fn ipv4Eql(a: Ipv4, b: Ipv4) bool {
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

pub fn ipv4IsUnspecified(address: Ipv4) bool {
    return ipv4Eql(address, ipv4_unspecified);
}

pub fn ipv4IsBroadcast(address: Ipv4) bool {
    return ipv4Eql(address, ipv4_broadcast);
}

pub fn ipv4IsLoopback(address: Ipv4) bool {
    return address[0] == 127;
}

pub fn ipv4IsMulticast(address: Ipv4) bool {
    return (address[0] & 0xf0) == 0xe0;
}

pub fn macFromSlice(slice: []const u8) ?Mac {
    if (slice.len < 6) return null;
    return .{ slice[0], slice[1], slice[2], slice[3], slice[4], slice[5] };
}

pub fn ipv4FromSlice(slice: []const u8) ?Ipv4 {
    if (slice.len < 4) return null;
    return .{ slice[0], slice[1], slice[2], slice[3] };
}
