#!/bin/bash
# Stage 3 — clone the original onto a scratch disk with ddrescue.
#
# Usage: sudo ./30-clone.sh /dev/<destination-disk> [recovery-dir]
#
# ddrescue rather than dd for two reasons that matter here. Its mapfile records
# exactly which ranges succeeded, so an interrupted run resumes from where it
# stopped instead of starting over — on a terabyte that is the difference
# between a retry and a lost afternoon. And an unreadable sector is logged and
# retried separately rather than aborting the copy, so one bad spot on a failing
# disk does not cost you the other 999 GB.
#
# Everything after this stage happens on the clone. The original is never
# written to until the clone has been repaired AND verified AND frozen.

DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${2:-$PWD/vc-recovery}"
. "$DIR/lib.sh"
require_root; require_tools ddrescue blockdev sha256sum

DST_IN="${1:?Usage: sudo $0 /dev/<destination-disk> [recovery-dir]}"
SRC=$(state_get SRC); [ -n "$SRC" ] || die "Run 00-assess.sh first."
assert_ro "$SRC"
[ -b "$DST_IN" ] || die "$DST_IN is not a block device."
DST=$(stable_path "$DST_IN")
[ "$(readlink -f "$DST")" != "$(readlink -f "$SRC")" ] || die "Source and destination are the same disk."

SSIZE=$(dev_size "$SRC"); DSIZE=$(dev_size "$DST")
head1 "Check"
say "source      : $SRC  ($SSIZE bytes, read-only)"
say "destination : $DST  ($DSIZE bytes)"
[ "$DSIZE" -ge "$SSIZE" ] || die "Destination is smaller by $(( SSIZE - DSIZE )) bytes."

head1 "What is on the destination now"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DST" 2>/dev/null | sed 's/^/   /'
say ""
say "This will overwrite ALL of it, irreversibly."
read -rp "   Type the destination path to confirm: " OK
[ "$OK" = "$DST_IN" ] || [ "$OK" = "$DST" ] || die "Confirmation did not match. Nothing written."

MAP="$RECOVERY_DIR/clone.mapfile"
mkdir -p "$RECOVERY_DIR"
state_set DST "$DST"

head1 "Cloning"
say "mapfile: $MAP  (delete it only if you want to start over from zero)"
say "Safe to interrupt with Ctrl-C and re-run this script to resume."
say ""
ddrescue -f -n "$SRC" "$DST" "$MAP"
RC=$?

head1 "Result"
ddrescue --version >/dev/null
grep -E '^0x' "$MAP" | sed 's/^/   /' | head -20
say "exit code: $RC"

head1 "Verifying the copy"
ok=0; bad=0
for pct in 0 1 5 10 20 30 40 50 60 70 80 90 95 99; do
  blk=$(( SSIZE / 100 * pct / 1048576 ))
  a=$(dd if="$SRC" bs=1M skip=$blk count=16 status=none | sha256sum | cut -c1-24)
  b=$(dd if="$DST" bs=1M skip=$blk count=16 status=none | sha256sum | cut -c1-24)
  if [ "$a" = "$b" ]; then ok=$((ok+1)); else bad=$((bad+1)); printf '   %3s%% MISMATCH\n' "$pct"; fi
done
say "$ok regions match, $bad differ"
[ "$bad" -eq 0 ] || die "The copy does not match the source. Do not proceed."

HDR=$(state_get HDR_SHA); OFF=$(state_get VOL_OFFSET)
if [ -n "$HDR" ] && [ -n "$OFF" ]; then
  got=$(dd if="$DST" bs=512 skip=$((OFF/512)) count=256 status=none | sha256sum | cut -d' ' -f1)
  [ "$got" = "$HDR" ] && say "volume header on the clone: identical" \
                      || die "The header on the clone does not match. Do not proceed."
fi

say ""
say "Next: sudo $DIR/40-repair-clone.sh"
