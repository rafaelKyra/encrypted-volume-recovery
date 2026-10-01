#!/usr/bin/env bash
# Guard rails for the recovery scripts. Run from the plugin root:
#   bash scripts/lint-recovery-scripts.sh
#
# 1. Every shell script parses (bash -n) and the detector compiles.
# 2. Commands that WRITE to a disk may appear only in the stages designed to write:
#      30-clone.sh            ddrescue / dd of=<disk>  (writes the scratch disk)
#    (dd writing to a regular file, e.g. saving header candidates, is not a disk write)
#      40-repair-clone.sh     e2fsck              (repairs the CLONE)
#      50-repair-original.sh  sgdisk --new, e2fsck (repairs the original, behind gates)
#    Any other script that grows a write command fails the lint.
# 3. Every stage after 00 refuses to run on a device that is not read-only (assert_ro).
set -u
cd "$(dirname "$0")/.."
R=scripts/recovery; fail=0
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
ok()  { printf 'ok    %s\n' "$1"; }

for f in $R/*.sh scripts/*.sh tests/*.sh; do
  bash -n "$f" 2>/dev/null && ok "bash -n $f" || bad "syntax: $f"
done
python3 -m py_compile scripts/hidden-container/detect-hidden-container.py 2>/dev/null \
  && ok "py_compile detect-hidden-container.py" || bad "detector does not compile"
rm -rf scripts/hidden-container/__pycache__

# 2. write commands only where allowed
WRITE='(^|[^#a-z_])(sgdisk +--new|sgdisk +-[a-zA-Z]*[nGoZ]|e2fsck|mkfs[.a-z0-9]*|wipefs|ddrescue|dd +[^#]*of=("?\$\{?(SRC|DST|DEV|DISK)|/dev/)|parted +.*mk|sfdisk)'
for f in $R/*.sh; do
  b=$(basename "$f")
  case "$b" in 30-clone.sh|40-repair-clone.sh|50-repair-original.sh|lib.sh) continue;; esac
  if grep -nE "$WRITE" "$f" | grep -vE '^\s*[0-9]+:\s*#' | grep -vE 'say |echo |printf |head1' | grep -q .; then
    bad "write command in a read-only stage: $b"
  else ok "no write commands in $b"; fi
done

# 3. later stages assert read-only
for b in 10-extract-headers.sh 20-sweep-offsets.sh; do
  grep -q 'assert_ro' "$R/$b" && ok "$b asserts read-only" || bad "$b does not call assert_ro"
done
exit $fail
