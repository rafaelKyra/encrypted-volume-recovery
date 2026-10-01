#!/bin/bash
# Stage 2 — find the byte offset where the VeraCrypt volume starts.
#
# Usage: sudo ./20-sweep-offsets.sh [recovery-dir]
#   JOBS=24   how many attempts to run at once (default: half the cores)
#
# Why a sweep at all: a destroyed partition table leaves no record of where the
# volume began. The header is encrypted, so it cannot be recognised by a magic
# number — the only test is "does the password unlock it here?". That makes this
# a search over candidate offsets rather than a lookup.
#
# Why one password entry: each attempt runs PBKDF2 across several hash and
# cipher combinations, so a single try costs seconds to a minute. Typing the
# password once per candidate is where recovery attempts actually go wrong —
# mistyped entries, pasted text landing in the shell, prompts answered in the
# wrong order. One entry, many candidates, is both faster and far more reliable.
#
# The password lives in a shell variable that is never exported and reaches
# veracrypt only through a pipe, so it stays out of `ps`, /proc/*/environ,
# shell history, and disk.

DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_DIR="${1:-$PWD/vc-recovery}"
. "$DIR/lib.sh"
require_root; require_tools veracrypt losetup nproc

SRC=$(state_get SRC); [ -n "$SRC" ] || die "Run 00-assess.sh first."
LAST=$(state_get DATA_LAST_SECTOR)
FIRST=$(state_get DATA_FIRST_SECTOR)
assert_ro "$SRC"

END_BYTE=$(( LAST * 512 + 512 ))
JOBS="${JOBS:-$(( $(nproc) / 2 ))}"; [ "$JOBS" -lt 1 ] && JOBS=1
FOUND="$RECOVERY_DIR/OFFSET-FOUND.txt"; rm -f "$FOUND"

# Candidate set, in order of how often each turns out to be right:
#   - standard partition alignments used by every modern partitioner
#   - every sector of any surviving island near the head of the disk, since a
#     header there is exactly what survives when the zeroed band stops short
build_candidates() {
  local -a c=()
  for s in 2048 1024 4096 8192 34 63 56 32; do c+=( $((s*512)) ); done
  if [ "$FIRST" -lt 4096 ]; then
    for s in $(seq "$FIRST" $(( FIRST + 256 )) ); do c+=( $((s*512)) ); done
  fi
  printf '%s\n' "${c[@]}" | awk '!seen[$0]++'
}
mapfile -t OFFSETS < <(build_candidates)
TOTAL=${#OFFSETS[@]}

head1 "Sweep"
say "device     : $SRC"
say "candidates : $TOTAL"
say "parallel   : $JOBS"
say ""
read -rsp "   Volume password (not echoed): " PW; echo; echo

try_one() {
  local off=$1 lp
  [ -f "$FOUND" ] && return 0
  lp=$(losetup -r -f --show -o "$off" --sizelimit $(( END_BYTE - off )) "$SRC" 2>/dev/null) || return 0
  if vc_try "$lp" "$PW"; then
    printf '%s\n' "$off" > "$FOUND"
    printf '\n\n  #### UNLOCKED at offset %s (sector %s) ####\n' "$off" $(( off / 512 ))
    return 0
  fi
  losetup -d "$lp" 2>/dev/null
  printf '.'
}

n=0
for off in "${OFFSETS[@]}"; do
  [ -f "$FOUND" ] && break
  try_one "$off" &
  n=$((n+1))
  if [ $(( n % JOBS )) -eq 0 ]; then wait; printf ' [%d/%d]\n' "$n" "$TOTAL"; fi
done
wait
unset PW
echo

if [ -f "$FOUND" ]; then
  OFF=$(cat "$FOUND")
  LP=$(losetup -a | awk -F: -v o="$OFF" '$0 ~ o {print $1; exit}')
  DM=$(vc_mapper_for "$LP")
  SPAN=$(( END_BYTE - OFF ))
  head1 "Volume parameters — record these"
  say "offset    : $OFF"
  say "span      : $SPAN bytes"
  veracrypt --text --volume-properties --slot="$(veracrypt --text --list 2>/dev/null | awk -v l="$LP" '$2==l{print $1}' | tr -d ':')" 2>/dev/null | sed 's/^/   /'
  state_set VOL_OFFSET "$OFF"; state_set VOL_SPAN "$SPAN"
  if [ -b "$DM" ]; then
    say ""
    say "filesystem seen by the kernel:"
    blkid "$DM" 2>/dev/null | sed 's/^/   /'
    # A header fingerprint lets later stages prove they are looking at the same
    # volume. It is a hash of encrypted bytes, so it reveals nothing by itself.
    state_set HDR_SHA "$(dd if="$SRC" bs=512 skip=$((OFF/512)) count=256 status=none | sha256sum | cut -d' ' -f1)"
  fi
  vc_close "$LP"; sleep 1; losetup -d "$LP" 2>/dev/null
  say ""
  say "Next: sudo $DIR/30-clone.sh /dev/<destination-disk>"
else
  head1 "No candidate accepted the password"
  say "Before concluding the headers are gone, rule out the cheap explanations:"
  say "  - a PIM was set on this volume (try PIM=<n> by editing vc_try in lib.sh)"
  say "  - a keyfile was used"
  say "  - the password has a trailing space from a paste"
  say "  - the volume was created by TrueCrypt (no longer supported)"
  say "See references/pitfalls.md."
fi
