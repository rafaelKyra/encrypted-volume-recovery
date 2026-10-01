#!/bin/bash
# Stage 4 — repair the filesystem inside the volume, on the CLONE only.
#
# Usage: sudo ./40-repair-clone.sh [recovery-dir]
#
# A wiped partition table often takes the front of the filesystem with it. For
# ext2/3/4 that usually means the primary group descriptor table, which the
# kernel refuses to mount ("Structure needs cleaning") even when every byte of
# file data is present. The fix is to rebuild the primary metadata from one of
# the backup superblocks the filesystem keeps scattered across the volume.
#
# This writes. That is precisely why it happens on the clone: if the repair
# makes things worse, re-clone from the untouched original and try differently.

DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${1:-$PWD/vc-recovery}"
. "$DIR/lib.sh"
require_root; require_tools veracrypt losetup e2fsck dumpe2fs

SRC=$(state_get SRC); DST=$(state_get DST)
OFF=$(state_get VOL_OFFSET); SPAN=$(state_get VOL_SPAN); HDR=$(state_get HDR_SHA)
[ -n "$DST" ] || die "Run 30-clone.sh first."
[ -n "$OFF" ] || die "Run 20-sweep-offsets.sh first."

head1 "Safety"
assert_ro "$SRC"; say "original still read-only: yes"
got=$(dd if="$DST" bs=512 skip=$((OFF/512)) count=256 status=none | sha256sum | cut -d' ' -f1)
[ "$got" = "$HDR" ] || die "Header on $DST is not the expected one. Refusing."
say "clone carries the expected volume header: yes"

LP=$(losetup -f --show -o "$OFF" --sizelimit "$SPAN" "$DST") || die "losetup failed."
say "loop: $LP (writable, backed by the clone)"
read -rsp "   Volume password (not echoed): " PW; echo
vc_try "$LP" "$PW" || { unset PW; losetup -d "$LP"; die "Volume did not unlock on the clone."; }
unset PW
DM=$(vc_mapper_for "$LP"); [ -b "$DM" ] || die "No decrypted device."
say "volume open: $DM"

FSTYPE=$(blkid -o value -s TYPE "$DM" 2>/dev/null)
say "filesystem: ${FSTYPE:-unknown}"
case "$FSTYPE" in
  ext2|ext3|ext4) : ;;
  "") say "blkid cannot identify it; trying ext tools anyway." ;;
  *) say "Not an ext filesystem. e2fsck does not apply — see references/methodology.md"
     say "for how to approach ntfs (ntfsfix/chkdsk) and other layouts."; ;;
esac

head1 "Snapshot of current metadata"
dd if="$DM" of="$RECOVERY_DIR/clone-metadata-before-fsck.bin" bs=1M count=64 status=none
say "saved 64 MiB to $RECOVERY_DIR/clone-metadata-before-fsck.bin"

head1 "Locating a usable backup superblock"
BS=$(dumpe2fs -h "$DM" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2);print $2}')
BS=${BS:-4096}
SB=""
for cand in 32768 98304 163840 229376 8193 24577; do
  if dd if="$DM" bs=1 skip=$(( cand * BS + 56 )) count=2 status=none 2>/dev/null \
     | od -An -tx1 | tr -d ' \n' | grep -qi '53ef'; then SB=$cand; break; fi
done
[ -n "$SB" ] || die "No backup superblock found. Stop and read references/methodology.md."
say "block size: $BS,  backup superblock at block $SB"

head1 "e2fsck (this takes a while on a large filesystem)"
e2fsck -f -y -b "$SB" -B "$BS" "$DM" 2>&1 | tee "$RECOVERY_DIR/fsck-clone.log" | tail -25
RC=${PIPESTATUS[0]}
say ""
say "exit code $RC — 0 means clean, 1 means errors were fixed (both are success),"
say "2 means fixed but a reboot is wanted, 4 or more means unfixed problems."

head1 "Can the kernel mount it?"
MP=/mnt/vc-clone-check; mkdir -p "$MP"
if mount -o ro "$DM" "$MP" 2>/dev/null; then
  N=$(ls -1 "$MP" | wc -l)
  say "MOUNTED. entries in root: $N"
  df -h "$MP" | sed 's/^/   /'
  say "orphans in lost+found: $(ls -1 "$MP/lost+found" 2>/dev/null | wc -l)"
  say ""
  say "Root listing (names are yours; nothing here is recorded anywhere):"
  ls -la "$MP" | head -25 | sed 's/^/   /'
  umount "$MP"
  state_set CLONE_REPAIRED yes
  say ""
  say "Look at real files before going further. A filesystem that mounts is not"
  say "yet proof the contents are sound — open a few large archives and let their"
  say "own checksums tell you (unzip -t, tar -tf, 7z t)."
  say ""
  say "Next: sudo $DIR/50-repair-original.sh"
else
  say "Still refuses to mount. Read $RECOVERY_DIR/fsck-clone.log."
  say "Do NOT proceed to stage 5 — the original stays locked."
fi
vc_close "$LP"; sleep 2; losetup -d "$LP" 2>/dev/null
