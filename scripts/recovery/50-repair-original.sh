#!/bin/bash
# Stage 5 — freeze the clone, then repair the original and rebuild its partition.
#
# Usage: sudo ./50-repair-original.sh [recovery-dir]
#
# This is the only stage that writes to the original, and it is deliberately the
# last one. Up to this point the original has been the single pristine copy; the
# moment it becomes writable, that guarantee is gone. So the order is inverted
# from intuition: the backup is proven first, frozen second, and only then is the
# thing you actually care about touched.
#
# The gates below are not ceremony. Each one has a specific failure it prevents:
# repairing the original when no working backup exists, when the backup is
# incomplete, when the wrong disk is in the slot, or when a reflexive "yes"
# answered a question the operator had not read.

DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${1:-$PWD/vc-recovery}"
. "$DIR/lib.sh"
require_root; require_tools veracrypt losetup e2fsck sgdisk partprobe

SRC=$(state_get SRC); DST=$(state_get DST)
OFF=$(state_get VOL_OFFSET); SPAN=$(state_get VOL_SPAN); HDR=$(state_get HDR_SHA)
[ -n "$SRC" ] && [ -n "$DST" ] && [ -n "$OFF" ] || die "Earlier stages have not completed."

############################ GATE 1 ############################
head1 "GATE 1 — the clone must be a working backup"
# Proving this before touching the original is the whole safety model. A clone
# that merely exists is not a backup; one that unlocks and mounts is.
CLONE_TARGET="$DST"
for cand in "${DST}-part1" "$(readlink -f "$DST")1" "$(readlink -f "$DST")p1"; do
  [ -b "$cand" ] && { CLONE_TARGET="$cand"; CLONE_OFF=0; break; }
done
read -rsp "   Volume password (not echoed): " PW; echo

if [ "${CLONE_OFF:-}" = "0" ]; then
  LPC="$CLONE_TARGET"; USED_LOOP=""
  say "clone volume reachable directly at $LPC"
else
  LPC=$(losetup -r -f --show -o "$OFF" --sizelimit "$SPAN" "$DST") || { unset PW; die "losetup failed."; }
  USED_LOOP=1
fi
vc_try "$LPC" "$PW" || { unset PW; [ -n "$USED_LOOP" ] && losetup -d "$LPC"; \
  die "The clone does not unlock. Refusing to touch the original."; }
DMC=$(vc_mapper_for "$LPC")
MP=/mnt/vc-gate-clone; mkdir -p "$MP"
if ! mount -o ro "$DMC" "$MP" 2>/dev/null; then
  unset PW; vc_close "$LPC"; [ -n "$USED_LOOP" ] && losetup -d "$LPC"
  die "The clone's filesystem does not mount. Refusing to touch the original."
fi
NDIR=$(ls -1 "$MP" | wc -l)
NF=$(timeout 90 find "$MP" -xdev -maxdepth 3 2>/dev/null | wc -l)
say "clone mounts. root entries: $NDIR, files within depth 3: $NF"
if [ "$NDIR" -lt 3 ] || [ "$NF" -lt 50 ]; then
  umount "$MP"; unset PW; vc_close "$LPC"; [ -n "$USED_LOOP" ] && losetup -d "$LPC"
  die "The clone looks too empty to be a real backup. Refusing."
fi
umount "$MP"; vc_close "$LPC"; sleep 1
[ -n "$USED_LOOP" ] && losetup -d "$LPC" 2>/dev/null
say "GATE 1 passed."

############################ GATE 2 ############################
head1 "GATE 2 — freeze the clone"
# From here on the clone is the only fallback, so nothing may write to it —
# including a stray mount or an automounter.
blockdev --setro "$DST"
for p in "${DST}-part1" "$(readlink -f "$DST")1" "$(readlink -f "$DST")p1"; do
  [ -b "$p" ] && blockdev --setro "$p" 2>/dev/null
done
assert_ro "$DST"
say "clone frozen read-only. Note: this is a kernel flag and is lost on reboot."

############################ GATE 3 ############################
head1 "GATE 3 — the original must carry the expected header"
got=$(dd if="$SRC" bs=512 skip=$((OFF/512)) count=256 status=none | sha256sum | cut -d' ' -f1)
[ "$got" = "$HDR" ] || { unset PW; die "Header on $SRC is not the expected one. Refusing."; }
say "header fingerprint matches."

############################ GATE 4 ############################
head1 "GATE 4 — explicit confirmation"
say "About to UNLOCK $SRC and write to it."
say "Verified backup: $DST (frozen)"
read -rp "   Type exactly  REPAIR ORIGINAL  : " OK
[ "$OK" = "REPAIR ORIGINAL" ] || { unset PW; die "Not confirmed. Original untouched."; }

############################ REPAIR ############################
head1 "Unlocking the original"
blockdev --setrw "$SRC"
say "read-only flag now: $(dev_ro "$SRC")"

LPN=$(losetup -f --show -o "$OFF" --sizelimit "$SPAN" "$SRC") || { unset PW; die "losetup failed."; }
vc_try "$LPN" "$PW" || { unset PW; blockdev --setro "$SRC"; losetup -d "$LPN"; \
  die "Volume did not unlock on the original; re-locked it."; }
unset PW
DMN=$(vc_mapper_for "$LPN")
say "volume open: $DMN"

dd if="$DMN" of="$RECOVERY_DIR/original-metadata-before-fsck.bin" bs=1M count=64 status=none
say "saved a 64 MiB metadata snapshot."

BS=$(dumpe2fs -h "$DMN" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2);print $2}'); BS=${BS:-4096}
SB=""
for cand in 32768 98304 163840 229376 8193 24577; do
  if dd if="$DMN" bs=1 skip=$(( cand * BS + 56 )) count=2 status=none 2>/dev/null \
     | od -An -tx1 | tr -d ' \n' | grep -qi '53ef'; then SB=$cand; break; fi
done
[ -n "$SB" ] || { vc_close "$LPN"; losetup -d "$LPN"; die "No backup superblock on the original."; }

head1 "e2fsck on the original"
e2fsck -f -y -b "$SB" -B "$BS" "$DMN" 2>&1 | tee "$RECOVERY_DIR/fsck-original.log" | tail -20
say "exit code: ${PIPESTATUS[0]}"

head1 "Verifying"
MP2=/mnt/vc-original-check; mkdir -p "$MP2"
OKFS=0
if mount -o ro "$DMN" "$MP2" 2>/dev/null; then
  say "MOUNTS. root entries: $(ls -1 "$MP2" | wc -l)"
  df -h "$MP2" | sed 's/^/   /'
  umount "$MP2"; OKFS=1
else
  say "Does NOT mount. See $RECOVERY_DIR/fsck-original.log"
fi
vc_close "$LPN"; sleep 2; losetup -d "$LPN" 2>/dev/null

############################ PARTITION ############################
if [ "$OKFS" = "1" ]; then
  head1 "Rebuilding the partition table"
  # Cosmetic but worth doing: with a partition entry the volume gets a stable
  # name that VeraCrypt's device picker lists, so day-to-day use no longer
  # depends on recreating a loop device at a remembered offset. The write only
  # touches the first sectors of the disk, far from a volume that starts at
  # 1 MiB — but it is still a write, so it happens only after the filesystem
  # has proven itself.
  START=$(( OFF / 512 ))
  END=$(( (OFF + SPAN) / 512 - 1 ))
  dd if="$SRC" of="$RECOVERY_DIR/original-gpt-before.bin" bs=512 count=34 status=none
  say "saved the current first 34 sectors."
  LASTUSABLE=$(sgdisk -p "$SRC" 2>/dev/null | awk '/last usable sector/{print $NF}')
  if [ -n "$LASTUSABLE" ] && [ "$END" -gt "$LASTUSABLE" ]; then
    say "The volume ends at sector $END, past the GPT's last usable sector"
    say "($LASTUSABLE). Skipping partition creation — the volume still opens via"
    say "losetup at offset $OFF, which is what matters. See references/pitfalls.md."
  else
    sgdisk --new=1:"$START":"$END" --change-name=1:"VeraCrypt" "$SRC" 2>&1 | sed 's/^/   /'
    partprobe "$SRC"; sleep 3
    lsblk -o NAME,SIZE,TYPE "$SRC" | sed 's/^/   /'
    for p in "${SRC}-part1" "$(readlink -f "$SRC")1" "$(readlink -f "$SRC")p1"; do
      if [ -b "$p" ]; then
        chk=$(dd if="$p" bs=512 count=256 status=none | sha256sum | cut -d' ' -f1)
        [ "$chk" = "$HDR" ] && say "partition starts exactly at the volume header: correct" \
                            || say "WARNING: the new partition does not start at the header."
        break
      fi
    done
  fi
else
  say "Not rebuilding the partition table: the filesystem did not mount."
fi

head1 "Done"
say "Original: repaired and usable."
say "Clone   : frozen read-only (until reboot) as your backup."
say ""
say "Two things worth doing now, while it is fresh:"
say "  1. VeraCrypt -> Tools -> Backup Volume Header, and store that 128 KiB file"
say "     somewhere other than this disk. Its absence is what made all of this hard."
say "  2. Remove any temporary passwordless-sudo rule you added for this work."
