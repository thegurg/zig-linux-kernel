#!/usr/bin/env python3
"""Build the M18 initramfs tar (ustar) without external tools.

The archive is intentionally tiny and deterministic: two text files, one of
them in a subdirectory. It is passed to the kernel as a Limine module, so the
kernel's tar reader is tested independently from the FAT path.
"""

from __future__ import annotations

import argparse
import io
import tarfile
from pathlib import Path

FILES = {
    "HELLO.TXT": b"hello from initramfs\n",
    "SUB/NESTED.TXT": b"nested initramfs\n",
}


def build(output: Path) -> None:
    with tarfile.open(output, "w", format=tarfile.USTAR_FORMAT) as archive:
        for name, contents in FILES.items():
            info = tarfile.TarInfo(name)
            info.size = len(contents)
            info.mode = 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(contents))
    print(f"mkinitramfs: {output} files={len(FILES)} bytes={output.stat().st_size}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.output)


if __name__ == "__main__":
    main()
