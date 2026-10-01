# Methodology

Background for judgement calls the scripts cannot make for you.

## Contents
- [On-disk layout of a VeraCrypt volume](#on-disk-layout-of-a-veracrypt-volume)
- [Reading the damage pattern](#reading-the-damage-pattern)
- [Why the offset sweep is the right instrument](#why-the-offset-sweep-is-the-right-instrument)
- [Choosing candidate offsets](#choosing-candidate-offsets)
- [When the sweep finds nothing](#when-the-sweep-finds-nothing)
- [Filesystems other than ext](#filesystems-other-than-ext)
- [Repairing without a spare disk](#repairing-without-a-spare-disk)
- [Deciding when recovery is genuinely impossible](#deciding-when-recovery-is-genuinely-impossible)

## On-disk layout of a VeraCrypt volume

Offsets are relative to the start of the volume, not the disk:

| Range | Contents |
|---|---|
| `0` – `65535` | Standard volume header. First 64 bytes salt, next 448 the encrypted header holding the master keys. The remainder is random filler. |
| `65536` – `131071` | Hidden-volume header, or random filler when there is none. |
| `131072` – `end-131072` | Data area. |
| last `131072` bytes | Embedded backup headers: standard first, hidden second. |

Two consequences worth internalising. Only the **first 512 bytes** of the header
region carry anything irreplaceable — surviving bytes further into the first
64 KiB are filler and prove nothing. And the backup header is inside the volume,
so a whole-device volume keeps it at the very end of the disk, exactly where
partitioning tools write their backup table.

## Reading the damage pattern

Map where zeros begin and end; the widths tell you what was lost.

A Windows "Initialize Disk" typically zeroes the first 1 MiB and roughly 1 MiB at
the tail, then writes a protective MBR at sector 0, a GPT header at sector 1, and
partition entries in sectors 2–33.

An empty partition array is a useful tell: a CRC over 128 zeroed entries is a
fixed value, and `sgdisk -p` showing no partitions on a disk that certainly had
one means the table was recreated rather than a partition merely deleted.

Surviving islands near the head deserve attention. Data at sector 34 onward,
with zeros before and after, is what remains when the zeroed band does not cover
the first usable sector — and that is precisely where a header would sit for a
partition starting there. Sweep it.

## Why the offset sweep is the right instrument

A VeraCrypt header is indistinguishable from random data: no magic number, no
signature, nothing to scan for. The only test is attempting to unlock. Recovery
therefore reduces to a search over candidate offsets, with the password as the
oracle.

This is also why signature-scanning tools (PhotoRec, TestDisk) do not help find
the volume. They look for known patterns; there are none. They become useful only
after the volume is unlocked, if the filesystem inside is beyond repair.

## Choosing candidate offsets

Ordered by hit rate:

1. **`2048` sectors (1 MiB)** — the default alignment for every modern
   partitioner. The most likely answer by a wide margin.
2. **`34`, `63`, `56`, `32` sectors** — older or unusual alignments. Sector 34 is
   the first usable LBA under GPT and often coincides with a surviving island.
3. **Every sector of a surviving island** near the head. Cheap in parallel and it
   covers alignments you have not thought of.
4. **`0`** — a whole-device volume. Worth including, though if the first megabyte
   was zeroed this will fail.

Bound each candidate's `--sizelimit` by where data actually ends, not by the disk
size. The tail is zeroed, and including it means VeraCrypt sees a volume whose
declared size disagrees with the device.

## When the sweep finds nothing

Work through the cheap explanations before concluding the header is gone:

- **A PIM was set.** A non-default PIM changes the iteration count, and a wrong
  one fails identically to a wrong password. Ask; if uncertain, sweep a few
  plausible values (`--pim=N`) at the most likely offset rather than all offsets.
- **A keyfile was used.** Without it no password works. Look for it before
  anything else.
- **Trailing whitespace** on a pasted password.
- **TrueCrypt-format volume.** Modern VeraCrypt refuses these; `--truecrypt`
  exists on some builds, otherwise an older binary is needed.
- **Keyboard layout.** A password typed on a different layout than the one used
  at creation produces different bytes.

Only after all of those: if the volume covered the whole device and both header
regions fall inside zeroed bands, the master keys are gone. Say so plainly and
without hedging. The data is present but permanently sealed, and a saved header
backup file is the only thing that would change that.

## Filesystems other than ext

The volume-level work is identical; only the repair differs.

- **NTFS** — `ntfsfix` handles minor issues but is not `chkdsk`. For real damage,
  attach the unlocked mapper device to a Windows VM and run `chkdsk /f`, or use
  `ntfsrecover`. `$MFT` and its mirror `$MFTMirr` are the structures to check.
- **exFAT/FAT** — `fsck.exfat` / `fsck.fat`. Both keep a second FAT copy; the
  backup boot sector sits at sector 12 for exFAT, sector 6 for FAT32.
- **Btrfs** — `btrfs rescue super-recover`, then `btrfs check`. Never
  `--repair` before trying the read-only check and superblock recovery.
- **XFS** — `xfs_repair -n` first; XFS keeps per-allocation-group superblocks.
- **LVM inside the volume** — `pvscan`, `vgscan` on the mapper device, then
  `vgcfgrestore` from `/etc/lvm/archive` if metadata is damaged.

If no repair path works, file-carving on the unlocked mapper device (PhotoRec)
recovers contents without names or structure. It is a last resort, not a step.

## Repairing without a spare disk

When no second disk of adequate size exists, a device-mapper snapshot gives you
the same protection: the origin stays read-only and writes land in a
copy-on-write file, so `e2fsck` can do its work and the original is never
touched.

```bash
# Origin read-only; COW file sized for changed blocks only (metadata repair is
# usually well under a gigabyte, but size it generously).
truncate -s 8G /path/on/another/fs/cow.img
COW=$(losetup -f --show /path/on/another/fs/cow.img)
SECTORS=$(blockdev --getsz /dev/mapper/<unlocked-volume>)
dmsetup create vcsnap --table \
  "0 $SECTORS snapshot /dev/mapper/<unlocked-volume> $COW P 8"
e2fsck -f -y -b 32768 -B 4096 /dev/mapper/vcsnap
mount -o ro /dev/mapper/vcsnap /mnt/check
```

This is faster than cloning a terabyte and equally safe for testing a repair. It
is not a backup, though: the snapshot disappears with the COW file, so it does
not replace a clone before writing to the original.

## Deciding when recovery is genuinely impossible

Two findings are conclusive, and both are worth stating early rather than after
hours of work:

**The disk reads as zeros.** A quick format on an SSD issues TRIM for the
formatted region, and the controller returns zeros thereafter. The ciphertext is
gone, not merely unreachable. Sample across the whole disk in stage 0; if
high-entropy data is absent, stop.

**A whole-device volume with both header regions zeroed.** The master keys are
256 random bits that existed only in those two places. No amount of compute
substitutes for them.

Everything else — a wiped partition table, a corrupted filesystem, an unmountable
volume, a disk showing as RAW — is recoverable, and worth the effort.
