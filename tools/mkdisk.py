#!/usr/bin/env python3
"""Build the M18 FAT16 test disk without root, loop devices, or mtools.

Layout (512-byte sectors, one sector per cluster):

    sector 0            boot sector / BPB
    sectors 1..32       FAT #1
    sectors 33..64      FAT #2
    sectors 65..68      root directory (64 entries)
    sector 69..         data clusters

Files are allocated from cluster 2 upward. The last sector is deliberately left
unallocated so the kernel's write/read pattern test can use it without touching
file data.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

SECTOR = 512
TOTAL_SECTORS = 8192
SECTORS_PER_CLUSTER = 1
RESERVED_SECTORS = 1
FAT_COUNT = 2
ROOT_ENTRIES = 64
ROOT_DIR_SECTORS = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR


def choose_fat_sectors() -> int:
    fat = 1
    while True:
        data = TOTAL_SECTORS - RESERVED_SECTORS - FAT_COUNT * fat - ROOT_DIR_SECTORS
        clusters = data // SECTORS_PER_CLUSTER
        if clusters >= 4085 and clusters <= 65524 and (clusters + 2) * 2 <= fat * SECTOR:
            return fat
        fat += 1


FAT_SECTORS = choose_fat_sectors()
FIRST_DATA_SECTOR = RESERVED_SECTORS + FAT_COUNT * FAT_SECTORS + ROOT_DIR_SECTORS


def short_name(name: str) -> bytes:
    base, dot, extension = name.upper().partition(".")
    if len(base) > 8 or len(extension) > 3:
        raise ValueError(f"not an 8.3 name: {name}")
    return base.ljust(8).encode("ascii") + extension.ljust(3).encode("ascii")


class Image:
    def __init__(self) -> None:
        self.data = bytearray(TOTAL_SECTORS * SECTOR)
        self.fat = [0] * ((FAT_SECTORS * SECTOR) // 2)
        self.fat[0] = 0xFFF8
        self.fat[1] = 0xFFFF
        self.next_cluster = 2

    def allocate(self, count: int) -> int:
        if count == 0:
            return 0
        first = self.next_cluster
        for index in range(count):
            cluster = first + index
            self.fat[cluster] = cluster + 1 if index + 1 < count else 0xFFFF
        self.next_cluster += count
        if self.next_cluster > 65524:
            raise ValueError("disk image exhausted its FAT16 clusters")
        return first

    def cluster_offset(self, cluster: int) -> int:
        return (FIRST_DATA_SECTOR + (cluster - 2) * SECTORS_PER_CLUSTER) * SECTOR

    def write_file(self, contents: bytes) -> int:
        count = (len(contents) + SECTOR * SECTORS_PER_CLUSTER - 1) // (SECTOR * SECTORS_PER_CLUSTER)
        first = self.allocate(count)
        offset = 0
        cluster = first
        while offset < len(contents):
            chunk = contents[offset : offset + SECTOR * SECTORS_PER_CLUSTER]
            start = self.cluster_offset(cluster)
            self.data[start : start + len(chunk)] = chunk
            offset += len(chunk)
            cluster += 1
        return first

    def directory_entry(
        self,
        directory_offset: int,
        index: int,
        name: str,
        attributes: int,
        first_cluster: int,
        size: int,
    ) -> None:
        offset = directory_offset + index * 32
        entry = bytearray(32)
        entry[0:11] = short_name(name)
        entry[11] = attributes
        # Fixed timestamp: 2026-01-01 00:00:00.
        struct.pack_into("<H", entry, 14, (46 << 9) | (1 << 5) | 1)
        struct.pack_into("<H", entry, 16, 0)
        struct.pack_into("<H", entry, 18, (46 << 9) | (1 << 5) | 1)
        struct.pack_into("<H", entry, 20, (first_cluster >> 16) & 0xFFFF)
        struct.pack_into("<H", entry, 22, 0)
        struct.pack_into("<H", entry, 24, 0)
        struct.pack_into("<H", entry, 26, first_cluster & 0xFFFF)
        struct.pack_into("<I", entry, 28, size)
        self.data[offset : offset + 32] = entry

    def finish(self, root_offset: int, fat_offset: int) -> None:
        for copy in range(FAT_COUNT):
            start = (RESERVED_SECTORS + copy * FAT_SECTORS) * SECTOR
            raw = b"".join(struct.pack("<H", value) for value in self.fat)
            self.data[start : start + len(raw)] = raw

        boot = bytearray(SECTOR)
        boot[0:3] = b"\xeb\x3c\x90"
        boot[3:11] = b"ZIGKERNL"
        struct.pack_into("<H", boot, 11, SECTOR)
        boot[13] = SECTORS_PER_CLUSTER
        struct.pack_into("<H", boot, 14, RESERVED_SECTORS)
        boot[16] = FAT_COUNT
        struct.pack_into("<H", boot, 17, ROOT_ENTRIES)
        struct.pack_into("<H", boot, 19, TOTAL_SECTORS)
        boot[21] = 0xF8
        struct.pack_into("<H", boot, 22, FAT_SECTORS)
        struct.pack_into("<H", boot, 24, 32)
        struct.pack_into("<H", boot, 26, 64)
        boot[36] = 0x80
        boot[38] = 0x29
        struct.pack_into("<I", boot, 39, 0x5A1C2026)
        boot[43:54] = b"ZIGKERNEL "
        boot[54:62] = b"FAT16   "
        boot[510:512] = b"\x55\xaa"
        self.data[0:SECTOR] = boot
        _ = root_offset, fat_offset


def build(output: Path, init_elf: Path) -> None:
    image = Image()
    root_offset = (RESERVED_SECTORS + FAT_COUNT * FAT_SECTORS) * SECTOR
    fat_offset = RESERVED_SECTORS * SECTOR

    hello = b"hello from fat\n"
    hello_cluster = image.write_file(hello)
    image.directory_entry(root_offset, 0, "HELLO.TXT", 0x20, hello_cluster, len(hello))

    big = bytes(index % 251 for index in range(1300))
    big_cluster = image.write_file(big)
    image.directory_entry(root_offset, 1, "BIG.BIN", 0x20, big_cluster, len(big))

    init_bytes = init_elf.read_bytes()
    init_cluster = image.write_file(init_bytes)
    image.directory_entry(root_offset, 2, "INIT.ELF", 0x20, init_cluster, len(init_bytes))

    nested = b"nested file contents"
    nested_cluster = image.write_file(nested)
    sub_cluster = image.allocate(1)
    image.directory_entry(root_offset, 3, "SUB", 0x10, sub_cluster, 0)
    image.directory_entry(image.cluster_offset(sub_cluster), 0, "NESTED.TXT", 0x20, nested_cluster, len(nested))

    image.finish(root_offset, fat_offset)
    output.write_bytes(image.data)
    print(
        f"mkdisk: {output} sectors={TOTAL_SECTORS} fat_sectors={FAT_SECTORS} "
        f"first_data={FIRST_DATA_SECTOR} clusters_used={image.next_cluster - 2} "
        f"init_bytes={len(init_bytes)}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--init-elf", type=Path, required=True)
    args = parser.parse_args()
    build(args.output, args.init_elf)


if __name__ == "__main__":
    main()
