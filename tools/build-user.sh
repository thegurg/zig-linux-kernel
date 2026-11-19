#!/usr/bin/env bash
# Rebuild the checked-in user ELF fixtures.
#
# The kernel embeds src/user/demo.elf and src/user/proc.elf with @embedFile.
# Run this script after editing either .S or .ld file, then commit the
# regenerated ELF together with the source change. The script uses the host
# binutils (as/ld) and needs no Zig.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/user"

build() {
  local name="$1"
  local obj="$SRC/$name.o"
  local elf="$SRC/$name.elf"
  local ld="$SRC/$name.ld"

  as --64 -o "$obj" "$SRC/$name.S"
  ld -m elf_x86_64 -nostdlib --build-id=none -T "$ld" -o "$elf" "$obj"
  rm -f "$obj"
  chmod 644 "$elf"

  readelf -h "$elf" >/dev/null
  echo "==> src/user/$name.elf"
  readelf -l "$elf"
}

build demo
build proc
