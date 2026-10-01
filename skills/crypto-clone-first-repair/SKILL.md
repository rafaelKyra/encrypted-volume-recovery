---
name: crypto-clone-first-repair
description: Recover an encrypted disk after its partition table or headers were damaged without making things worse - lock the original read-only, image it, repair only the copy, freeze the copy, repair the original last. Use when someone says an encrypted drive was formatted by mistake, a partition vanished from an encrypted disk, a disk shows as RAW or unallocated, VeraCrypt says "Incorrect password or not a VeraCrypt volume" on a disk whose password is known, or when asked to clone a disk before recovery or to repair the only copy of data.
---

# Clone first, repair the copy, touch the original last

## When to use
- An encrypted disk lost its partition table (Windows "Initialize Disk", a quick format of the table, an accidental repartition, a wiped GPT/MBR).
- Someone is about to run a repair tool, `fsck`, `cryptsetup repair` or an unlock attempt on the **only** copy of the data.
- A user asks how to "just clone" or "just mount" such a disk. The ordering and the gates are the substance; do not shortcut them.

## The rule
While the original is the only pristine copy it is also the only thing between the user and permanent loss, so it stays locked until a verified backup exists. Every experiment runs on the clone.

## Recipe
Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/recovery/`, are numbered in execution order and share state through `vc-recovery/recovery.env`. Nothing is hardcoded: devices are arguments, offsets and sizes are measured.

1. **Assess, read-only.** Locks the original with `blockdev --setro` in the first minute and confirms the payload is still there before hours are spent.
   `sudo ./scripts/recovery/00-assess.sh /dev/<original>`
2. **Extract header candidates.** Saves every place a VeraCrypt header could still be (512 KiB in total) before anything else can go wrong. See `crypto-header-sweep`.
   `sudo ./scripts/recovery/10-extract-headers.sh`
3. **Find the volume offset.** The sweep. See `crypto-header-sweep`. For LUKS this stage is a scan instead: see `crypto-luks-header-recovery`.
   `sudo ./scripts/recovery/20-sweep-offsets.sh`
4. **Clone** to a scratch disk with ddrescue, then verify the copy against the source and check the header on the clone.
   `sudo ./scripts/recovery/30-clone.sh /dev/<destination>`
5. **Repair the clone.** All experiments live here. Break it freely; re-clone.
   `sudo ./scripts/recovery/40-repair-clone.sh`
6. **Freeze the clone, then repair the original** - last, and only behind gates. The script refuses unless the clone unlocks, its filesystem mounts and it does not look too empty to be a real backup.
   `sudo ./scripts/recovery/50-repair-original.sh`

Needs `gddrescue`, `gdisk`, `e2fsprogs`, `smartmontools` and, for VeraCrypt volumes, `veracrypt`:
`sudo apt-get install -y gddrescue gdisk e2fsprogs smartmontools`

**Handling the password.** Never take it as an argument or an environment variable: argv is visible in `ps` and the environment in `/proc/PID/environ`. Read it with `read -rs` into an unexported shell variable, pipe it to `veracrypt --stdin`, `unset` it afterwards. `vc_try` in `scripts/recovery/lib.sh` does exactly this. Ask at most once per stage. An agent running this cannot type the user's password and should not try: hand over the command and read the outcome.

## Pitfalls
- **"Read-only-looking" commands can write.** On a LUKS2 image whose primary header was zeroed, `cryptsetup luksDump`, `isLuks`, `luksDump --dump-json-metadata` and `open --test-passphrase` each rewrote the primary header from the secondary copy; `--readonly` did not prevent it, a `chmod 444` file did. Observed with cryptsetup 2.8.4 on a file image (`tests/test_luks_file_images.sh`); behaviour on a block device was not tested. Lock the original at the kernel (`blockdev --setro`) before the first inspection command, not after.
- **`blockdev --setro` does not survive a reboot.** It is kernel state, not a property of the disk. Re-apply it as the first command after boot, and tell the user, or they will trust a frozen backup that has thawed.
- **Device names move.** `sdb` becomes `sdc` when a disk is added. Use `/dev/disk/by-id/` paths; `stable_path` in `lib.sh` resolves them.
- **`e2fsck -n` cannot diagnose this damage.** It refuses every repair, so it cannot rebuild the group descriptors it needs, and a dry run on a fully recoverable 1 TB volume can report eleven files. Run the real repair on the clone and measure there.
- **A read-write mount during verification** replays the ext journal and ends any bit-level comparison. Mount `-o ro`, and for ext `-o ro,noload`.
- More symptom-by-symptom entries are in `skills/crypto-header-sweep/references/pitfalls.md`.

## Verification
A mounting filesystem with plausible names is not proof. Get an independent verdict:
- Archives check themselves: `unzip -t`, `tar -tf`, `7z t` verify a CRC per member.
- `lost+found` should be empty; orphans there are inodes whose names were lost.
- Walk the whole tree with `find`; it surfaces I/O errors a root listing hides.
- Repair both disks independently and compare: `e2fsck` should report identical file and block counts.
- `e2fsck` exit code 1 means errors were found **and fixed**, which is success. 0 is clean, 2 is fixed-but-reboot-preferred, 4 and above are real failures.
- Let the user open their own files before the original is unlocked.

Test status of the scripts: all pass `bash -n`; the method was used end to end on one real volume (see `references/DECISIONS.md`); the packaged scripts themselves have not yet been run on a disk. `tests/` holds the plan.
