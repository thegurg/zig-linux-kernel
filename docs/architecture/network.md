# Networking

**Purpose:** describe the M19 network path: the legacy virtio-net polling
driver, Ethernet/ARP/IPv4/ICMP/UDP, loopback, the fixed UDP socket table, and
the DNS encoder/query used by the smoke test.

**Implementation status:** M19 is **IMPLEMENTED** for a single legacy virtio-net
device, static IPv4 configuration, ARP, ICMP echo, UDP, loopback, and a minimal
DNS client. TCP, DHCP, IPv6, fragmentation, routing protocols, modern virtio,
MSI-X interrupts, and user-visible socket syscalls are **PLANNED** or
**DEFERRED** as noted below.

## Status at a glance

| Feature | Status | Source |
| --- | --- | --- |
| Legacy virtio-net (device ID `0x1000`) polling | **IMPLEMENTED** | [`src/drivers/virtio_net.zig`](../../src/drivers/virtio_net.zig) |
| Separate receive and transmit split virtqueues | **IMPLEMENTED** | [`src/drivers/virtio_net.zig`](../../src/drivers/virtio_net.zig) |
| Legacy 10-byte virtio-net header | **IMPLEMENTED** | [`src/drivers/virtio_net.zig`](../../src/drivers/virtio_net.zig) |
| MAC feature negotiation and config read | **IMPLEMENTED** | [`src/drivers/virtio_net.zig`](../../src/drivers/virtio_net.zig) |
| Modern virtio 1.0 and MSI-X | **PLANNED** | The driver returns `ModernOnly` rather than guessing. |
| Ethernet II framing | **IMPLEMENTED** | [`src/net/ethernet.zig`](../../src/net/ethernet.zig) |
| ARP request/reply and cache | **IMPLEMENTED** | [`src/net/arp.zig`](../../src/net/arp.zig) |
| IPv4 header/checksum, no fragmentation | **IMPLEMENTED** | [`src/net/ipv4.zig`](../../src/net/ipv4.zig) |
| ICMP echo request/reply | **IMPLEMENTED** | [`src/net/icmp.zig`](../../src/net/icmp.zig) |
| UDP datagrams and checksum | **IMPLEMENTED** | [`src/net/udp.zig`](../../src/net/udp.zig) |
| Loopback delivery | **IMPLEMENTED** | [`src/net/net.zig`](../../src/net/net.zig) |
| Fixed UDP socket table | **IMPLEMENTED** | [`src/net/net.zig`](../../src/net/net.zig) |
| DNS A query encoder and answer parser | **IMPLEMENTED** | [`src/net/dns.zig`](../../src/net/dns.zig) |
| Deterministic host DNS stub for the smoke test | **IMPLEMENTED** | [`tools/dns_stub.py`](../../tools/dns_stub.py) |
| Static IPv4 configuration (`10.0.2.15/24`) | **IMPLEMENTED** | [`src/network.zig`](../../src/network.zig) |
| DHCP, TCP, IPv6, fragmentation, routing protocols | **PLANNED** | Not implemented. |
| User `socket`/`send`/`recv` syscalls | **PLANNED** | The stack is kernel-side only. |

## Boot wiring

[`src/network.zig`](../../src/network.zig) mirrors the storage bring-up: normal
boot calls it after the storage summary and logs a non-fatal status line.

```text
network: pci=<n> device=<0|1> configured=<0|1> mac=<mac> ip=<ip>
```

The sequence is:

1. Enumerate PCI with the legacy `0xCF8`/`0xCFC` mechanism.
2. Find vendor `0x1af4`, legacy virtio-net device `0x1000`.
3. `virtio_net.init()` enables I/O and bus-master access, resets the device,
   negotiates `VIRTIO_NET_F_MAC`, sets up both queues, reads the MAC, primes the
   receive ring, and sets `DRIVER_OK`.
4. `net.init()` installs the device callbacks and the static configuration.

A machine without the test NIC still boots; `device=0` is reported and the
network stack is left uninitialized. The selftest calls the same `init()` and
then exercises the stack.

The QEMU harness creates the NIC with `disable-modern=on`:

```text
-netdev user,id=net0
-device virtio-net-pci,netdev=net0,disable-modern=on
```

QEMU user-mode networking supplies the fixed addresses used by M19:

| Setting | Value |
| --- | --- |
| Guest address | `10.0.2.15/24` |
| Gateway / host alias | `10.0.2.2` |
| DNS server advertised by QEMU | `10.0.2.3` |
| DNS stub used by the test | `10.0.2.2:5353` |

## Legacy virtio-net driver

The register layout is the common legacy virtio PCI layout from M18: host and
guest features at `0x00`/`0x04`, the selected queue's address and size at
`0x08`/`0x0c`, queue select at `0x0e`, notify at `0x10`, status at `0x12`, and
device-specific configuration at `0x14`.

Only `VIRTIO_NET_F_MAC` (bit 5) is negotiated. The MAC is read from the six
bytes at `0x14`. Mergeable receive buffers, checksum offload, segmentation
offload, and event suppression are not negotiated, so every packet uses the
legacy 10-byte virtio-net header:

| Byte | Field |
| --- | --- |
| 0 | flags (zero) |
| 1 | GSO type (zero) |
| 2-3 | header length (zero) |
| 4-5 | GSO size (zero) |
| 6-7 | checksum start (zero) |
| 8-9 | checksum offset (zero) |

The receive queue is queue 0. The driver allocates one physically contiguous
pool of sixteen 2 KiB buffers and one descriptor per buffer. All descriptors are
marked device-write only, published in the available ring, and the queue is
notified after `DRIVER_OK`. `pollRx` consumes the used ring, copies the frame
that follows the 10-byte header, and immediately republishes the descriptor.
Frames larger than 2 KiB are dropped by the device or truncated by the copy.

The transmit queue is queue 1. One zeroed 10-byte header plus the Ethernet frame
is copied into a static 2 KiB buffer, described by a single readable descriptor,
published, and polled to completion. One request is outstanding at a time.

Both queues use a driver-side count of consumed completions rather than
sampling the device's used index immediately before notifying. This matters when
the device completes a request before the driver starts polling: the count
makes that completion observable instead of making the driver wait for the next
one.

The descriptor table, available ring, and page-aligned used ring are laid out
exactly as in the M18 block driver. For the tested queue size of 256, each ring
occupies three pages.

## Ethernet and ARP

[`src/net/ethernet.zig`](../../src/net/ethernet.zig) parses and writes the
14-byte Ethernet II header and recognizes IPv4 (`0x0800`) and ARP (`0x0806`).
The stack accepts frames addressed to the device MAC or the broadcast address;
it does not join multicast groups.

[`src/net/arp.zig`](../../src/net/arp.zig) implements Ethernet/IPv4 ARP
requests and replies. The cache holds eight entries and learns the sender on
both request and reply. `net.arpResolve` consults the cache, broadcasts a
request, and polls until the reply arrives or the timeout expires. Replies to
requests for the guest address are sent directly to the requesting MAC. Cache
entries do not age out; a full table replaces slot 0.

## IPv4, ICMP, and UDP

IPv4 parsing requires version 4, an IHL of at least 20 bytes, a total length
within the frame, a valid header checksum, and a zero fragment offset. Sending
uses a 20-byte header, `DF`, TTL 64, and a monotonically incremented
identification field. There is no fragmentation, reassembly, or option
processing.

ICMP implements echo request and echo reply only. Every message's checksum is
validated on receive and computed on send. The stack answers echo requests for
the guest address and uses the Ethernet source MAC directly for the reply, so
answering a request never recurses into ARP resolution.

UDP validates the length, accepts a zero checksum, and otherwise verifies the
IPv4 pseudo-header checksum. `udpSend` always computes a checksum. Datagrams
larger than 1472 bytes are rejected.

The UDP socket table has eight fixed slots, each with one pending datagram of up
to 1472 bytes. `udpBind` reserves a port, `udpRecv` polls the device until the
slot is ready or the timeout expires, and `udpUnbind` clears the slot. The table
is protected by an IRQ-safe spinlock; packet transmission has a separate lock.

## Loopback

`127.0.0.0/8` and the guest's own address are delivered internally without
touching the NIC. The packet is built normally, including the IPv4 and UDP
checksums, and handed to the same receive dispatcher. ICMP echo to `127.0.0.1`
therefore exercises the request path, reply path, and checksum code, while UDP
to `127.0.0.1` exercises socket delivery.

## Config and route selection

`src/network.zig` installs `10.0.2.15/24`, gateway `10.0.2.2`, and DNS
`10.0.2.3`. For a destination inside the subnet, `net.sendIpv4` resolves the
destination directly. For any other destination it resolves the gateway and
still puts the final destination in the IPv4 header. There is no dynamic
routing table, metric, or interface selection.

## DNS

[`src/net/dns.zig`](../../src/net/dns.zig) builds a single-question A/IN query
and walks the answer section of a response, including compression pointers. It
returns the first A record. `net.dnsQuery` uses the configured DNS server and
port 53; `net.dnsQueryTo` is the same path with an explicit server and port.

The smoke test does not depend on the host resolver or internet access. The
harness starts [`tools/dns_stub.py`](../../tools/dns_stub.py) on the host, which
answers any query on `127.0.0.1:5353` with `93.184.216.34`. QEMU user-mode
networking maps the guest's `10.0.2.2` host alias to that listener, so the guest
sends a real UDP DNS query through the virtio-net device and the stack parses a
real response.

## Validation

The M19 selftest asserts:

- PCI enumeration finds the legacy virtio-net device and an I/O BAR;
- the negotiated MAC is reported and both 256-entry queues have three-page
  rings;
- the static address, gateway, and DNS configuration are reported;
- an ARP request to the gateway receives a reply and populates the cache;
- an ICMP echo to the gateway receives a matching echo reply;
- an ICMP echo to `127.0.0.1` is answered through loopback;
- a UDP datagram sent to a bound port through loopback is received intact;
- a DNS query to the deterministic stub returns `93.184.216.34`.

The default KVM run logs:

```text
selftest: checking M19 virtio-net and network stack
m19: pci devices=8
m19: pci virtio-net bus=0 slot=4 fn=0 io=0x60e0 irq=10
m19: virtio-net mac=52:54:00:12:34:56 rxq=256 txq=256 io=0x60e0 ring_pages=3/3
m19: ipv4 address=10.0.2.15 gateway=10.0.2.2 dns=10.0.2.3
m19: arp gateway mac=52:55:0a:00:02:02
m19: icmp echo reply gateway=10.0.2.2
m19: icmp loopback reply=1
m19: udp loopback port=49160 bytes=21
m19: dns query name=example.com status=ok address=93.184.216.34
selftest: M19 checks passed
```

Host tests cover Ethernet framing, ARP round trips, IPv4 checksums and subnet
matching, ICMP checksums, UDP pseudo-header checksums, DNS query encoding, DNS
answer decompression, and checksum rejection.

## Limitations

- Polling only; MSI-X and virtio interrupts are not used. One transmit request is
  outstanding at a time.
- Legacy virtio only; a modern-only device produces `ModernOnly`.
- One device, static IPv4 configuration, no DHCP, no TCP, no IPv6, no
  fragmentation/reassembly, and no dynamic routing.
- The ARP cache is small and never ages; there is no neighbour unreachability
  detection.
- The UDP table has eight fixed slots with one pending datagram each; there is
  no flow control, no ICMP port-unreachable generation, and no retransmission.
- DNS supports A/IN queries only and sends one attempt.
- The ring-3 ABI still has no socket syscalls: networking is exercised by the
  kernel selftest, not by user programs.
- The virtqueue layout helpers are duplicated between the block and network
  drivers. A third legacy virtio device should factor them into a shared module.
