#!/usr/bin/env bash
# File-level checks of the LUKS claims in skills/crypto-luks-header-recovery.
#
# Runs WITHOUT root, on throwaway 64 MB image files in a temp directory: nothing here
# touches a real disk or device-mapper. It does not cover `losetup`, `cryptsetup open`
# or LVM; see tests/README.md for the root-only plan.
#
#   bash tests/test_luks_file_images.sh
#
# Hard checks fail the run. The cryptsetup auto-repair behaviour is version-dependent,
# so it is reported (CHARACTERISATION) and never fails the run.
set -u
command -v cryptsetup >/dev/null || { echo "cryptsetup not installed"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; cd "$T"
PW="throwaway-luks-test-passphrase"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
fmt()  { truncate -s 64M "$2"; printf '%s' "$PW" | cryptsetup luksFormat --type "$1" --batch-mode \
           --key-file=- --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha256 "$2" >/dev/null 2>&1; }
magic(){ head -c 6 "$1" | xxd -p; }
dump() { cryptsetup luksDump "$1" >/dev/null 2>&1; }

echo "cryptsetup: $(cryptsetup --version)"
fmt luks2 l2.img; fmt luks1 l1.img

echo; echo "layout"
check "LUKS2 primary magic at offset 0"            "[ \"\$(grep -abo \$'LUKS\\xba\\xbe' l2.img | head -1 | cut -d: -f1)\" = 0 ]"
check "LUKS2 secondary magic SKUL at offset 16384" "[ \"\$(grep -abo \$'SKUL\\xba\\xbe' l2.img | head -1 | cut -d: -f1)\" = 16384 ]"
check "LUKS1 has no secondary header"              "[ \"\$(grep -abo \$'SKUL\\xba\\xbe' l1.img | wc -l)\" = 0 ]"
check "LUKS2 default payload offset is 16 MiB"     "cryptsetup luksDump l2.img | grep -q 'offset: 16777216'"
check "LUKS1 default payload offset is 4096 sectors" "cryptsetup luksDump l1.img | grep -q 'Payload offset:.*4096'"

echo; echo "damage and recovery"
cp l2.img band.img; dd if=/dev/zero of=band.img bs=1M count=1 conv=notrunc status=none
check "a zeroed first MiB destroys LUKS2 (primary AND secondary)" "! dump band.img"
check "cryptsetup repair cannot rebuild it"       "! (printf 'YES\n' | cryptsetup repair band.img >/dev/null 2>&1; dump band.img)"
cp l1.img one.img; dd if=/dev/zero of=one.img bs=1K count=16 conv=notrunc status=none
check "LUKS1 with a zeroed header is not repairable" "! (printf 'YES\n' | cryptsetup repair one.img >/dev/null 2>&1; dump one.img)"

cryptsetup luksHeaderBackup l2.img --header-backup-file l2.bak >/dev/null 2>&1
check "LUKS2 header backup is 16 MiB"             "[ \"\$(stat -c %s l2.bak)\" = 16777216 ]"
printf 'YES\n' | cryptsetup luksHeaderRestore band.img --header-backup-file l2.bak >/dev/null 2>&1
check "restoring the backup revives the wiped volume" "dump band.img"
check "...and the passphrase still works"         "printf '%s' \"\$PW\" | cryptsetup open --test-passphrase --key-file=- band.img"

echo; echo "CHARACTERISATION (version-dependent, never fails the run)"
fresh(){ cp l2.img "$1"; chmod 644 "$1"; dd if=/dev/zero of="$1" bs=1K count=16 conv=notrunc status=none; }
for cmd in "luksDump" "isLuks" "luksDump --dump-json-metadata"; do
  fresh c.img; cryptsetup $cmd c.img >/dev/null 2>&1
  printf '  primary header zeroed, then `cryptsetup %s`: header %s\n' "$cmd" \
    "$([ "$(magic c.img)" = 4c554b53babe ] && echo REWRITTEN || echo untouched)"
done
fresh c.img; chmod 444 c.img; printf '%s' "$PW" | cryptsetup open --test-passphrase --key-file=- c.img >/dev/null 2>&1
printf '  same, on a file made read-only (chmod 444): header %s\n' \
  "$([ "$(magic c.img)" = 4c554b53babe ] && echo REWRITTEN || echo untouched)"

echo; printf 'passed %d, failed %d\n' "$pass" "$fail"; [ "$fail" = 0 ]
