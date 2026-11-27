#!/usr/bin/env python3
"""Deterministic DNS stub for the M19 smoke test.

QEMU user-mode networking maps the guest's 10.0.2.2 (the gateway alias) to the
host. The selftest sends a DNS A query for example.com to 10.0.2.2:5353, and
this process answers with a fixed address. That keeps the network test
hermetic: it does not need the host resolver or internet access.

Usage: tools/dns_stub.py [--port 5353] [--address 93.184.216.34]
"""

import argparse
import socket
import struct
import sys


def parse_question_end(message: bytes) -> int:
    offset = 12
    while offset < len(message):
        length = message[offset]
        if length == 0:
            return offset + 1
        if (length & 0xC0) != 0:
            raise ValueError("compressed query name")
        offset += 1 + length
    raise ValueError("truncated query name")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5353)
    parser.add_argument("--address", default="93.184.216.34")
    args = parser.parse_args()

    address = socket.inet_aton(args.address)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", args.port))
    print(f"dns_stub: listening on 127.0.0.1:{args.port}", flush=True)

    while True:
        message, peer = sock.recvfrom(1500)
        try:
            if len(message) < 12:
                continue
            question_end = parse_question_end(message)
            if question_end + 4 > len(message):
                continue
            question = message[12 : question_end + 4]
            header = bytearray(message[:12])
            header[2] = 0x81  # response, recursion desired
            header[3] = 0x80  # recursion available, no error
            struct.pack_into(">H", header, 6, 1)  # one answer
            answer = (
                b"\xc0\x0c"  # pointer to the question name
                + struct.pack(">HHIH", 1, 1, 60, 4)
                + address
            )
            sock.sendto(bytes(header) + question + answer, peer)
        except (ValueError, OSError):
            continue


if __name__ == "__main__":
    sys.exit(main())
