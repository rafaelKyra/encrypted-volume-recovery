# Pitfalls: symptom, cause, fix, guarding test

"Guarding test" names what would catch the problem again. **none** means the entry is
documented knowledge only.

| Symptom | Cause | Fix | Guarding test |
|---|---|---|---|
| `Incorrect password or not a VeraCrypt volume` although the password is right | One message for six causes: password, PIM, PRF, not a volume, removed algorithm, TrueCrypt format. Often a mistyped or mis-pasted entry | Change one variable at a time; sweep with one entry (`--pim=0 --keyfiles=` suppresses the prompts) | none |
| A header declared dead after a few manual tries | Input errors (paste lands in the shell, `Ctrl+Z`, PIM answered with text) print the same message | Use the automated sweep | none |
| `cryptsetup luksDump` on a damaged original changes bytes | LUKS2 tools restore a zeroed primary header from the secondary copy on a writable device; `--readonly` does not stop it | `blockdev --setro` / `losetup -r` first; on files, `chmod 444` | `tests/test_luks_file_images.sh` (characterisation) |
| `cryptsetup repair` says "not a valid LUKS device" | The first MiB was zeroed: both LUKS2 headers sit inside it; LUKS1 has no copy | Restore a header backup file | `tests/test_luks_file_images.sh` |
| A restored old header revives revoked passphrases | A backup holds the keyslots as they were | Re-take the backup after every passphrase change | none |
| `e2fsck -n` reports eleven files on a 1 TB volume | `-n` refuses every repair, so it cannot rebuild the group descriptors | Run the real repair on the clone and measure there | none |
| A wiped-looking region that is not wiped | `dd` offset truncated by block-size arithmetic | `bs=512` with sector arithmetic or `iflag=skip_bytes`; check for a known structure | none |
| SHA-256 `e3b0c442...` on both devices | `iflag=direct` read nothing; that is the hash of zero bytes | Drop `iflag=direct` | none |
| The read-only lock is gone after a reboot | `blockdev --setro` is kernel state | Re-apply first thing after boot; every stage asserts it | `assert_ro` in `scripts/recovery/lib.sh` (runtime gate) |
| The script wrote to the wrong disk | `sdb` became `sdc` | `/dev/disk/by-id/` paths | `stable_path` in `lib.sh` |
| A quick format of an SSD left only zeros | TRIM: the controller returns zeros, the ciphertext is gone | Sample the whole disk first; stop if no high-entropy data | `00-assess.sh` verdict (runtime) |
| Every probe fails with "could not create mount point" | A mount point left by an interrupted scan; read as "wrong key" it makes a whole scan report nothing | Unique mount name per run; stop with an explanation | none (needs zuluCrypt) |
| The hidden-container probe reports "opened mapper" | A mapper for that file is already open | `zuluCrypt-cli -q -d <file>` | none (needs zuluCrypt) |
| A zip, pdf or Office file stops opening after a container was appended | Their index sits at the end and is found by scanning back from EOF | Use a video, audio or image cover | `HostEnd.test_zip_end_is_found_even_when_appended_data_pushes_it_far_from_eof` (recovery side); the creation warning is in the patch |
| The build stops with `Syntax error: "(" unexpected` | A parenthesis in the build path reaches `/bin/sh` unescaped | Build from a clean path | none |
| A setuid helper stops working | AppImage is mounted `nosuid` | Ship a `.deb` | `dpkg-deb -c ... \| grep rwsr` (see the skill) |
| `lost+found` is empty but the user is unsure | A mount proves little | Verify with archive CRCs, a full `find` walk, and matching `e2fsck` counts on both disks | none |
| GUI says "incorrect password" on a loop device | Select Device lists only physical disks; or the whole disk was chosen though the volume starts at 1 MiB | Use Select File with the loop path, or write a partition entry so the volume appears as `sdX1` | transcript |
| `/dev/loopN` number changes | Kernel takes the first free loop | Capture it from `losetup -f --show`; never hard-code | transcript |
| Rewriting the partition table on the original too early | Writing GPT before the filesystem is known good | Write it only after the repaired filesystem mounts | repair script gate |
| A private (`drwx------`) directory looks missing/unreadable in the file manager | Permissions preserved by the repair | List with sudo; not damage | transcript |
| Header backup stored on the encrypted volume it protects | Backup unreachable when needed | Keep it on /boot or external media; protect it, it allows offline guessing but can be re-extracted from an intact volume anyway | advice |

More VeraCrypt-specific entries (GUI cannot see loop devices, PRF pinned to one hash,
passwords landing in shell history, `pkill -f` killing its own shell, stale processes holding
loop devices) are in `skills/crypto-header-sweep/references/pitfalls.md`.
