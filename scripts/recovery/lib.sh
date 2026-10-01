#!/bin/bash
# Common helpers for VeraCrypt volume recovery.
# Sourced by the numbered scripts. Nothing here is specific to any disk.

set -uo pipefail

RECOVERY_DIR="${RECOVERY_DIR:-$PWD/vc-recovery}"
STATE="$RECOVERY_DIR/recovery.env"

die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
say()  { printf '   %s\n' "$*"; }
head1(){ printf '\n=== %s ===\n' "$*"; }

require_root() { [ "$(id -u)" = 0 ] || die "Run with sudo."; }

require_tools() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] || die "Missing tools: ${missing[*]}
Install with: sudo apt-get install -y gddrescue smartmontools gdisk e2fsprogs"
}

# Resolve a device argument to a stable /dev/disk/by-id path when possible.
# Names like /dev/sdb are reassigned when disks are added or removed; a by-id
# path is tied to the hardware, so a script can never land on the wrong disk.
stable_path() {
  local dev; dev=$(readlink -f "$1")
  local best=""
  for link in /dev/disk/by-id/*; do
    [ -e "$link" ] || continue
    case "$link" in *-part*) continue;; esac
    if [ "$(readlink -f "$link")" = "$dev" ]; then
      # Prefer the longest name: it is the most specific (model + serial).
      [ ${#link} -gt ${#best} ] && best="$link"
    fi
  done
  printf '%s\n' "${best:-$dev}"
}

dev_size()   { blockdev --getsize64 "$1"; }
dev_ro()     { blockdev --getro "$1"; }
sector_size(){ blockdev --getss "$1"; }

assert_ro() {
  [ "$(dev_ro "$1")" = "1" ] || die "$1 is NOT read-only. Refusing to continue.
Lock it with: sudo blockdev --setro $1"
}

# Fraction of a region that is non-zero, 0-100. Zeroed regions are what a
# partitioning tool leaves behind; encrypted data is essentially all non-zero.
nonzero_pct() {
  local dev=$1 off=$2 len=${3:-65536}
  local nz
  nz=$(dd if="$dev" bs=512 skip=$((off/512)) count=$((len/512)) status=none 2>/dev/null \
       | tr -d '\000' | wc -c)
  echo $(( nz * 100 / len ))
}

# Incompressible data is random-looking: either encrypted content or the random
# filler VeraCrypt writes. Distinguishes "real data" from "structured plaintext".
is_random() {
  local dev=$1 off=$2 len=${3:-4096} raw comp
  raw=$(dd if="$dev" bs=512 skip=$((off/512)) count=$((len/512)) status=none 2>/dev/null)
  comp=$(printf '%s' "$raw" | gzip -1 -c | wc -c)
  [ "$comp" -ge $(( len * 97 / 100 )) ]
}

# First sector (512-byte units) holding any non-zero byte, searching forward.
first_data_sector() {
  local dev=$1 from=${2:-0} to=$3 mid
  local lo=$from hi=$to
  # Linear scan is too slow over a terabyte; step coarsely, then bisect.
  local step=$(( (hi - lo) / 512 )); [ "$step" -lt 1 ] && step=1
  local probe=$lo
  while [ "$probe" -lt "$hi" ]; do
    if [ "$(nonzero_pct "$dev" $((probe*512)) 65536)" != "0" ]; then hi=$probe; break; fi
    probe=$(( probe + step ))
  done
  lo=$(( hi - step )); [ "$lo" -lt "$from" ] && lo=$from
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    if [ "$(nonzero_pct "$dev" $((mid*512)) 512)" = "0" ]; then lo=$mid; else hi=$mid; fi
  done
  echo "$hi"
}

# Last sector holding any non-zero byte, by bisection from the tail.
last_data_sector() {
  local dev=$1 total=$2 mid
  local lo=$(( total - 8192 )) hi=$total
  [ "$lo" -lt 0 ] && lo=0
  while [ "$lo" -gt 0 ] && [ "$(nonzero_pct "$dev" $((lo*512)) 512)" = "0" ]; do
    hi=$lo; lo=$(( lo - 8192 )); [ "$lo" -lt 0 ] && lo=0
  done
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    if [ "$(nonzero_pct "$dev" $((mid*512)) 512)" != "0" ]; then lo=$mid; else hi=$mid; fi
  done
  echo "$lo"
}

# Read a value previously recorded by an earlier stage.
state_get() { [ -f "$STATE" ] && grep -m1 "^$1=" "$STATE" | cut -d= -f2- || true; }
state_set() {
  mkdir -p "$RECOVERY_DIR"; touch "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

# Attempt to unlock a VeraCrypt volume exposed at offset 0 of $dev.
# The password arrives on stdin so it never appears in argv (visible in `ps`)
# or in the environment (readable in /proc/PID/environ).
vc_try() {
  local dev=$1 pw=$2
  printf '%s' "$pw" | veracrypt --text --stdin --non-interactive \
      --filesystem=none --protect-hidden=no --pim=0 --keyfiles= "$dev" 2>/dev/null
}

vc_mapper_for() {
  veracrypt --text --list 2>/dev/null | awk -v d="$1" '$2==d{print $3}'
}

vc_close() { veracrypt --text --dismount "$1" 2>/dev/null || true; }

cleanup_loops_on() {
  local backing; backing=$(readlink -f "$1")
  losetup -a | while IFS=: read -r lp rest; do
    case "$rest" in *"$backing"*) losetup -d "$lp" 2>/dev/null;; esac
  done
}
