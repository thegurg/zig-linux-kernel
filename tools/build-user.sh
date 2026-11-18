#!/usr/bin/env bash
# Rebuild the checked-in M16 user ELF fixture.
#
# The kernel embeds src/user/demo.elf with @embedFile. Run this script after
# editing demo.S or demo.ld, then commit the regenerated ELF together with the
# source change. The script uses the host binutils (as/ld) and needs no Zig.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/user/demo.S"
OBJ="$ROOT/src/user/demo.o"
ELF="$ROOT/src/user/demo.elf"
LD="$ROOT/src/user/demo.ld"

as --64 -o "$OBJ" "$SRC"
trap 'rm -f "$OBJ"' EXIT
ld -m elf_x86_64 -nostdlib --build-id=none -T "$LD" -o "$ELF" "$OBJ"
chmod 644 "$ELF"

readelf -h "$ELF" >/dev/null
readelf -l "$ELF"
