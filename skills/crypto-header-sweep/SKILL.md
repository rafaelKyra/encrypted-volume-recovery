---
name: crypto-header-sweep
description: Find where an encrypted VeraCrypt volume starts when the partition table is gone, by trial-decrypting candidate offsets with a single password entry, and save every place a header could still survive. Use when VeraCrypt reports "Incorrect password or not a VeraCrypt volume" on a disk whose password is known, when a partition vanished from an encrypted disk, when asked where the volume header is, or when a recovery attempt keeps failing and nobody knows whether the header is intact.
---

# Header sweep: find the volume by asking the password

## When to use
- The partition table was destroyed and the volume's start is unknown.
- Manual unlock attempts keep failing and someone is about to declare the header dead.
- A disk must be assessed for recoverability before hours of imaging.

## The rule
A VeraCrypt header is encrypted, so it has **no magic number** and cannot be recognised by looking. The only test is "does the password unlock it here?", which makes recovery a search over candidate offsets, not a lookup. Run that search once, in parallel, with one password entry.

## Recipe
Run `crypto-clone-first-repair` stage 0 first so the disk is read-only.

1. **Understand which case you are in.** Partitioning writes a new table at the head and a backup at the tail, zeroing roughly the first and last megabyte, and nothing in between.
   - *Volume inside a partition aligned at 1 MiB:* its header sits at 1 MiB, exactly where the zeroed band stops. The header survives; the volume is recoverable.
   - *Volume on the whole raw device:* header at byte 0, embedded backup header in the last 128 KiB. Both fall inside the zeroed bands. The master keys existed only there. Without a separately saved header file this is unrecoverable.
   Do **not** decide which case by asking the user: people remember "whole disk" when they picked a partition. Decide it with the sweep.
2. **Save the candidates** before anything else touches the disk:
   `sudo ./scripts/recovery/10-extract-headers.sh`
   Four 128 KiB files (disk start, 1 MiB alignment, tail of the surviving data, disk tail) in exactly the layout VeraCrypt accepts for "Restore Volume Header from file", marked `VIABLE` when mostly non-zero. Copy that directory off the machine at once; it may hold the only copy of the master keys.
3. **Sweep:** `sudo ./scripts/recovery/20-sweep-offsets.sh`
   Candidates are the standard alignments (sectors 2048, 1024, 4096, 8192, 34, 63, 56, 32) plus every sector of any surviving island near the head of the disk. Each candidate is a read-only loop device at that offset; the password is typed once, held in an unexported variable and piped to `veracrypt`, so it stays out of `ps`, `/proc/*/environ`, history and disk. `JOBS=24` sets the parallelism (default: half the cores).
4. **Read the result.** On success the script records the offset and span, shows the filesystem the kernel sees and stores a hash of the first 128 KiB so later stages can prove they are looking at the same volume.

## Pitfalls
- **One message, six causes.** `Operation failed due to one or more of the following` is wrong password, wrong PIM, wrong PRF, not a volume, removed algorithm or TrueCrypt format. It never says the header is gone.
- **Declaring a header dead on input errors** is the costliest mistake. Pastes landing in the shell, `Ctrl+Z`, a PIM prompt answered with text: every one prints the same message. Four manual failures prove nothing.
- **When the sweep finds nothing,** rule out the cheap explanations first: a PIM was set, a keyfile was used, the password has a trailing space from a paste, or the volume is a TrueCrypt volume. The sweep tries the standard header only, with `--pim=0` and no keyfiles.
- **A quick format that reached the volume's first sectors** overwrites the standard header. What survives is the embedded backup header at the end of the volume. The scripts save that region but do not mount with it; see the README ("Planned / unverified").
- **A quick format of an SSD can leave nothing.** It issues TRIM and the controller returns zeros: the ciphertext is gone, not unreachable. Sample the whole disk in stage 0; if no high-entropy data exists, stop.
- Sixteen more entries (GUI cannot see loop devices, PRF pinned to one hash, passwords in shell history, `dd` offsets truncated by block-size arithmetic, `pkill -f` killing its own shell, ...) are in `references/pitfalls.md`; the on-disk layout and how to read a damage pattern are in `references/methodology.md`.

## Verification
- `OFFSET-FOUND.txt` exists and `blkid` on the mapper shows a filesystem. A coherent superblock cannot appear by chance: it also proves the decryption is correct.
- A clean primary superblock followed by garbage is the fingerprint of this damage pattern and a good sign; `Structure needs cleaning` on mount likewise means the kernel got far enough to read the superblock.
- Backup superblocks valid across the whole volume (check several, spread out) are the strongest evidence the filesystem is intact.

Evidence: the sweep method found the offset in a real recovery (see `references/DECISIONS.md`). The packaged `20-sweep-offsets.sh` is a generalisation written afterwards and has not yet run on a disk.
