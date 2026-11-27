//! M19 network bring-up shared by the normal boot path and the selftest.
//!
//! The guest uses QEMU user-mode networking's fixed addresses: 10.0.2.15 on a
//! /24, gateway 10.0.2.2, and DNS 10.0.2.3. A missing legacy virtio-net device
//! is not fatal; `Status` records what came up so a machine without the test
//! fixture still boots.

const pci = @import("drivers/pci.zig");
const virtio_net = @import("drivers/virtio_net.zig");
const net = @import("net/net.zig");
const types = @import("net/types.zig");

pub const guest_ip: types.Ipv4 = .{ 10, 0, 2, 15 };
pub const guest_netmask: types.Ipv4 = .{ 255, 255, 255, 0 };
pub const gateway_ip: types.Ipv4 = .{ 10, 0, 2, 2 };
pub const dns_ip: types.Ipv4 = .{ 10, 0, 2, 3 };

/// Deterministic DNS stub used by the selftest: QEMU user networking forwards
/// guest traffic to the host alias 10.0.2.2, where `tools/dns_stub.py` listens.
pub const stub_dns_ip: types.Ipv4 = gateway_ip;
pub const stub_dns_port: u16 = 5353;

pub const Status = struct {
    pci_devices: usize = 0,
    device: bool = false,
    configured: bool = false,
    info: ?virtio_net.Info = null,
    init_error: ?anyerror = null,
};

var context: u8 = 0;

pub fn init() Status {
    var status = Status{};
    status.pci_devices = pci.init();

    if (pci.find(pci.virtio_vendor_id, pci.virtio_legacy_net_device_id) == null) {
        return status;
    }

    const info = virtio_net.init() catch |err| {
        status.init_error = err;
        return status;
    };
    status.device = true;
    status.info = info;

    net.init(.{
        .context = &context,
        .mac = info.mac,
        .transmit_fn = transmit,
        .receive_fn = receive,
    }, .{
        .ip = guest_ip,
        .netmask = guest_netmask,
        .gateway = gateway_ip,
        .dns = dns_ip,
    });
    status.configured = true;
    return status;
}

fn transmit(_: *anyopaque, frame: []const u8) bool {
    return virtio_net.transmit(frame);
}

fn receive(_: *anyopaque, buffer: []u8) ?usize {
    return virtio_net.pollRx(buffer);
}
