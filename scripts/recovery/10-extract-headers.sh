#!/bin/bash
# Stage 1 — save every place a VeraCrypt header could still be, before anything
# else touches the disk. Each file is 131072 bytes, the exact layout VeraCrypt
# accepts in "Restore Volume Header from file": 64 KiB standard header followed
# by 64 KiB hidden-volume header.
#
# Usage: sudo ./10-extract-headers.sh [recovery-dir]

DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${1:-$PWD/vc-recovery}"
. "$DIR/lib.sh"
require_root; require_tools dd sha256sum

SRC=$(state_get SRC);  [ -n "$SRC" ] || die "Run 00-assess.sh first."
SIZE=$(state_get SRC_SIZE)
LAST=$(state_get DATA_LAST_SECTOR)
assert_ro "$SRC"

OUT="$RECOVERY_DIR/header-candidates"; mkdir -p "$OUT"

grab() { # label, byte offset
  local label=$1 off=$2
  [ "$off" -ge 0 ] || return 0
  local f="$OUT/${label}_off${off}.vcbak"
  dd if="$SRC" of="$f" bs=512 skip=$(( off / 512 )) count=256 status=none 2>/dev/null || return 0
  local nz; nz=$(tr -d '\000' < "$f" | wc -c)
  printf '   %-34s %6d/131072 non-zero  %s\n' "$(basename "$f")" "$nz" \
    "$([ "$nz" -gt 120000 ] && echo VIABLE || echo 'likely destroyed')"
}

head1 "Header candidates"
# Offsets are computed, never assumed: the head of the disk, the standard 1 MiB
# partition alignment, the tail of surviving data, and the tail of the disk.
grab disk-start 0
grab align-1MiB 1048576
grab data-tail  $(( LAST * 512 + 512 - 131072 ))
grab disk-tail  $(( SIZE - 131072 ))

( cd "$OUT" && sha256sum *.vcbak > SHA256SUMS.txt )
head1 "Saved"
say "$OUT  (+ SHA256SUMS.txt)"
say ""
say "Copy this directory somewhere off this machine now. It is 512 KiB and it is"
say "the difference between a recoverable volume and a permanent loss."
say ""
say "Next: sudo $DIR/20-sweep-offsets.sh"
