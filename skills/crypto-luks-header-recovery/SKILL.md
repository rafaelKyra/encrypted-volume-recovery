---
name: crypto-luks-header-recovery
description: Locate, inspect and restore a LUKS or LUKS2 header after the partition table was lost or the header was damaged, including LUKS-on-LVM and plain dm-crypt. Use when cryptsetup says "not a valid LUKS device", a LUKS partition vanished, luksDump fails, someone asks where the LUKS header is, how to back up or restore a LUKS header, whether LUKS2 can repair itself, or how LUKS differs from VeraCrypt for recovery.
---

# LUKS header recovery: scan, don't sweep

## When to use
- A LUKS or LUKS2 disk lost its partition table and the volume's start is unknown.
- `cryptsetup luksDump` or `open` reports the device is not LUKS, or the header looks damaged.
- Someone needs a header backup or restore procedure, or must choose between LUKS and VeraCrypt.

## The rule
A LUKS header carries a magic signature, so after a lost table the search is a **scan** for six bytes, not a trial decryption. LUKS2 also keeps a secondary header copy; LUKS1 does not. A header backup file beats every other route.

## Recipe
Everything in `crypto-clone-first-repair` applies unchanged: lock the original read-only first, work on a clone. Stage 2 (the sweep) is replaced by this scan.

1. **Identify.** `sudo cryptsetup luksDump /dev/<partition>` succeeding means LUKS; `blkid` printing `crypto_LUKS` means LUKS. A blank `blkid` proves nothing: a VeraCrypt volume and an empty disk look the same to it. **Run it only on a read-only device or loop** (see Pitfalls).
2. **Scan for the magic** at the usual alignments, then exhaustively if the alignment is unusual:
   ```bash
   dd if=/dev/<disk> bs=1M status=none | grep -abo $'LUKS\xba\xbe' | head
   ```
   Several hits are information: a header at 1 MiB plus a second hit 16 KiB later is one LUKS2 volume (its secondary header carries the magic `SKUL\xba\xbe` at offset 16384), not two volumes.
3. **Inspect without unlocking anything**, through a read-only loop at the hit:
   ```bash
   LOOP=$(sudo losetup -r -f --show -o <offset> /dev/<disk>)
   sudo cryptsetup luksDump "$LOOP"
   ```
   It shows version, cipher, payload offset and which key slots are occupied; an empty slot list means the keyslot area was destroyed even if the header survived. It costs no password attempt.
4. **Open it read-only** while assessing: `sudo cryptsetup open --readonly "$LOOP" recovered`, then `sudo mount -o ro /dev/mapper/recovered /mnt/check`.
5. **Rebuild the partition** if wanted: start sector is the header offset divided by 512; after `partprobe`, `cryptsetup open /dev/<disk>1 recovered` works without a loop device.
6. **If the header is damaged rather than missing,** on LUKS2 `sudo cryptsetup repair /dev/<partition>` rebuilds the primary from the secondary copy.
7. **Back up the header** at the end of any LUKS work, and store it off the disk it describes:
   `sudo cryptsetup luksHeaderBackup /dev/<partition> --header-backup-file <file>`
   Restore with `luksHeaderRestore`. The full text, including LUKS-on-LVM (the Linux installer default), plain dm-crypt and how to advise on LUKS versus VeraCrypt, is in `references/luks.md`.

| | LUKS1 | LUKS2 |
|---|---|---|
| Magic at the start | `LUKS\xba\xbe` | `LUKS\xba\xbe` |
| Secondary header | none | at offset 16384, magic `SKUL\xba\xbe` |
| Default payload offset | 4096 sectors (2 MiB) | 16 MiB |
| Header backup file | about 2 MiB | 16 MiB |
| Repair a damaged header | only from a backup file | `cryptsetup repair`, from the secondary |

## Pitfalls
- **LUKS2 does not protect against a wiped front.** A partitioning tool that zeroes the first megabyte destroys the primary header *and* the secondary one (16 KiB is well inside that band). In testing, `cryptsetup repair` then reported "not a valid LUKS device". The secondary copy covers localised corruption only.
- **Inspection commands can rewrite the header.** With the primary header zeroed, `luksDump`, `isLuks`, `luksDump --dump-json-metadata` and `open --test-passphrase` each silently restored it from the secondary copy; `--readonly` did not prevent that, a read-only file did. That is convenient on a clone and unacceptable on an original you are still diagnosing. Use `losetup -r` or `blockdev --setro` first.
- **Restoring an old header backup revives revoked passphrases** and invalidates ones added since. Re-take the backup after every passphrase change and treat the file as security-sensitive.
- **LUKS1 has no second chance:** a zeroed header is unrecoverable without a backup file.
- **Payload offset matters for reconstruction,** not only for the header: read it from `luksDump` before rebuilding a partition.

## Verification
`bash tests/test_luks_file_images.sh` (no root, throwaway images) re-checks the table above and the destruction, backup and restore claims against the installed cryptsetup, and records the auto-repair behaviour. It passed 11 of 11 on cryptsetup 2.8.4 on 2026-10-01. Not covered, and therefore not claimed: `losetup`, `cryptsetup open` on a loop, LVM on top, behaviour on a real disk.
