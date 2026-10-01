#!/bin/bash
# Stage 0 — protect the original and map what survived. Reads only.
#
# Usage: sudo ./00-assess.sh /dev/<original-disk> [recovery-dir]
#
# The first thing this does is lock the disk read-only at the kernel level.
# Every later stage refuses to run unless that lock is still in place, so a
# mistyped device name cannot destroy the only intact copy of the data.

DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${2:-$PWD/vc-recovery}"
. "$DIR/lib.sh"

SRC_IN="${1:?Usage: sudo $0 /dev/<original-disk> [recovery-dir]}"
require_root
require_tools blockdev dd gzip
[ -b "$SRC_IN" ] || die "$SRC_IN is not a block device."

SRC=$(stable_path "$SRC_IN")
mkdir -p "$RECOVERY_DIR"

head1 "Locking the original read-only"
blockdev --setro "$SRC"
assert_ro "$SRC"
say "$SRC is now read-only (kernel flag). This is lost on reboot — re-apply it."

SIZE=$(dev_size "$SRC"); SS=$(sector_size "$SRC"); TOTAL=$(( SIZE / 512 ))
head1 "Geometry"
say "stable path : $SRC"
say "size        : $SIZE bytes"
say "sector size : $SS (logical)"
say "sectors     : $TOTAL"
state_set SRC "$SRC"; state_set SRC_SIZE "$SIZE"

head1 "Is the bulk of the disk still encrypted data?"
# A VeraCrypt volume is indistinguishable from random noise. If samples across
# the disk are high-entropy, the payload survived; if they are zeros, the data
# was discarded (a TRIM-backed format on an SSD does this) and no header in the
# world will bring it back.
datapoints=0; randompoints=0
for pct in 1 5 10 20 30 40 50 60 70 80 90 95 99; do
  off=$(( SIZE / 100 * pct )); off=$(( off - off % 4096 ))
  p=$(nonzero_pct "$SRC" "$off" 65536)
  datapoints=$((datapoints+1))
  [ "$p" -gt 95 ] && randompoints=$((randompoints+1))
  printf '   %3s%%  non-zero: %3s%%\n' "$pct" "$p"
done
say ""
if [ "$randompoints" -eq "$datapoints" ]; then
  say "VERDICT: payload intact across the whole disk."
elif [ "$randompoints" -eq 0 ]; then
  say "VERDICT: the disk reads as zeros. The data is gone, most likely discarded"
  say "by TRIM during the format. Stop here; recovery is not possible."
else
  say "VERDICT: mixed. $randompoints of $datapoints samples look like data."
  say "Partial damage — map the boundaries below before spending time on a clone."
fi

head1 "Where does surviving data begin and end?"
# Partitioning tools zero a band at each end of the disk. The exact width of
# those bands tells you which header copies were destroyed.
FIRST=$(first_data_sector "$SRC" 0 "$TOTAL")
LAST=$(last_data_sector "$SRC" "$TOTAL")
say "first sector with data : $FIRST  (byte $(( FIRST * 512 )))"
say "last  sector with data : $LAST  (byte $(( LAST * 512 )))"
say "zeroed at the head     : $(( FIRST * 512 )) bytes"
say "zeroed at the tail     : $(( SIZE - LAST * 512 - 512 )) bytes"
state_set DATA_FIRST_SECTOR "$FIRST"; state_set DATA_LAST_SECTOR "$LAST"

head1 "Fine map of the first 128 KiB"
# A surviving island here often sits exactly where a header would be for a
# partition aligned at that sector, which is what stage 2 sweeps.
for s in $(seq 0 255); do
  p=$(nonzero_pct "$SRC" $((s*512)) 512)
  if [ "$p" = "0" ]; then m="....."; else m="DATA "; fi
  printf '%s' "$m"
  [ $(( (s+1) % 32 )) -eq 0 ] && printf '  <- sector %d\n' "$s"
done

head1 "Disk health"
if command -v smartctl >/dev/null; then
  smartctl -H "$SRC" 2>/dev/null | grep -iE 'overall|SMART support' | sed 's/^/   /'
  smartctl -A "$SRC" 2>/dev/null | awk '/Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Percentage Used|Media and Data/ {print "   "$0}'
else
  say "smartctl not installed — skipping."
fi

head1 "Next"
say "State written to $STATE"
say "Run: sudo $DIR/10-extract-headers.sh"
