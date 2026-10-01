# LUKS and dm-crypt

> **Evidence status.** Written 2026-09-28 from a VeraCrypt recovery and general knowledge of
> LUKS; not from a LUKS recovery on real hardware. On 2026-10-01 the file-level claims
> below were re-checked against **cryptsetup 2.8.4 on 64 MB file images, without root**
> (`tests/test_luks_file_images.sh`): magic positions, the LUKS2 secondary header at 16384,
> default payload offsets, `cryptsetup repair`, the effect of a zeroed first megabyte, and
> header backup and restore. One statement was corrected and one finding was added
> (marked *Corrected* and *Added*). **Device-level behaviour (`losetup`, `cryptsetup open`,
> LVM on top) has not been tested.**


Most of this skill's discipline transfers unchanged: lock the original
read-only, image it before touching it, repair the copy, freeze the copy, repair
the original last. What changes is the search problem — and it changes in your
favour.

## Contents
- [The one difference that matters](#the-one-difference-that-matters)
- [Finding a LUKS header after the table is gone](#finding-a-luks-header-after-the-table-is-gone)
- [LUKS1 versus LUKS2](#luks1-versus-luks2)
- [Inspecting what you found](#inspecting-what-you-found)
- [Opening it and reconstructing the partition](#opening-it-and-reconstructing-the-partition)
- [Header backup and restore](#header-backup-and-restore)
- [When the header is damaged rather than missing](#when-the-header-is-damaged-rather-than-missing)
- [What is still fatal](#what-is-still-fatal)
- [LUKS with LVM on top: the Linux default layout](#luks-with-lvm-on-top-the-linux-default-layout)
- [Plain dm-crypt](#plain-dm-crypt)
- [Advising someone on which to use](#advising-someone-on-which-to-use)

## The one difference that matters

A VeraCrypt header is deliberately indistinguishable from random data, which is
why locating a volume requires sweeping candidate offsets with the password as
the only oracle.

LUKS is the opposite: its header begins with the ASCII magic `LUKS` followed by
`0xBA 0xBE`. You can scan a disk for it. No password needed to find it, no sweep,
no guessing at alignments. A wiped partition table on a LUKS disk is a much
smaller problem than the same event on a VeraCrypt disk.

The trade-off is the reverse of what you might expect. That discoverable header
is also a single point of failure sitting at the very front of the partition —
precisely the region a partitioning tool zeroes. LUKS2 mitigates this with a
built-in secondary header copy; LUKS1 does not.

## Finding a LUKS header after the table is gone

Scan for the magic. Candidate offsets are the same alignments as elsewhere, but
you no longer depend on guessing them — a full scan is cheap because you are
matching six bytes, not deriving keys.

```bash
# Quick check at the usual alignments.
for s in 2048 1024 4096 8192 34 63 0; do
  off=$((s*512))
  if dd if=/dev/<disk> bs=1 skip=$off count=6 status=none | grep -q 'LUKS'; then
    echo "LUKS header at byte $off (sector $s)"
  fi
done

# Exhaustive scan when the alignment is unusual. Reports byte offsets.
dd if=/dev/<disk> bs=1M status=none | grep -abo $'LUKS\xba\xbe' | head
```

The `grep -abo` form streams the whole disk and prints byte offsets of every
match, including the LUKS2 secondary header and any stale headers from previous
formats. Treat multiple hits as information: a header at 1 MiB plus a second
16 KiB later is one LUKS2 volume, not two volumes.

`cryptsetup luksDump --header <file>` on a 4 MiB slice starting at each hit tells
you which are real.

## LUKS1 versus LUKS2

| | LUKS1 | LUKS2 |
|---|---|---|
| Magic at partition start | `LUKS\xba\xbe` | `LUKS\xba\xbe` |
| Version field (bytes 6–7) | `0x0001` | `0x0002` |
| Secondary header | none | yes, at offset 16384 (`0x4000`), magic `SKUL\xba\xbe` |
| Default payload offset | ~2 MiB (4096 sectors) | ~16 MiB (32768 sectors) |
| Metadata | fixed binary | binary + JSON, checksummed |
| Recovery from a damaged header | restore from a backup file only | `cryptsetup repair` can rebuild from the secondary copy |

The practical consequence: on LUKS2, a partitioning tool that zeroes the first
megabyte destroys both the primary header and the secondary copy, since 16 KiB is
well inside that band. The secondary copy protects against localised corruption,
not against a wiped front. Do not assume LUKS2 makes you safe here — verify.

## Inspecting what you found

```bash
# Expose the candidate region and inspect without unlocking anything.
LOOP=$(sudo losetup -r -f --show -o <offset> /dev/<disk>)
sudo cryptsetup luksDump "$LOOP"
```

**Use the read-only loop above, not the raw device.** *Added:* on a LUKS2 image whose primary
header had been zeroed, `cryptsetup luksDump`, `luksDump --dump-json-metadata`, `isLuks` and
`open --test-passphrase` each silently rewrote the primary header from the secondary copy;
`--readonly` did not stop it, but a file made read-only (`chmod 444`) did. Observed on a file
image with cryptsetup 2.8.4; on a block device `blockdev --setro` and `losetup -r` should have
the same effect, which was not tested. An inspection command that repairs the original also
destroys the evidence of how it was damaged.

`luksDump` reports the version, cipher, key size, payload offset, and which key
slots are populated. This is the LUKS equivalent of VeraCrypt's volume
properties, and unlike VeraCrypt it costs no password attempt.

Two fields matter for reconstruction. **Payload offset** is where the encrypted
data begins relative to the header, which you need if you later rebuild a
partition. **Key slots** shows which passphrases exist — an empty slot list means
the keyslot area was destroyed even if the header survived.

## Opening it and reconstructing the partition

```bash
sudo cryptsetup open --readonly "$LOOP" recovered
sudo fsck -n /dev/mapper/recovered          # inspect first
sudo mount -o ro /dev/mapper/recovered /mnt/check
```

Keep `--readonly` while assessing. Once you have a verified clone and want to
repair, drop it there — not on the original.

Rebuilding the partition table works exactly as in stage 5 of this skill: start
sector is the header offset divided by 512, end sector is derived from the volume
extent. After `partprobe`, `cryptsetup open /dev/<disk>1 recovered` works directly
with no loop device.

## Header backup and restore

This is the step whose absence makes VeraCrypt recoveries hard, and LUKS makes it
a one-liner. Recommend it at the end of any LUKS work:

```bash
sudo cryptsetup luksHeaderBackup /dev/<partition> \
     --header-backup-file ~/luks-header-<label>.img
```

The file is as large as the header area: **16 MiB for LUKS2** and about 2 MiB (2,068,480 bytes)
for LUKS1. *Corrected: this said "a few megabytes" for LUKS2; measured with cryptsetup 2.8.4
defaults on 2026-10-01.* Store it off the disk it describes.

Restoring it worked even after the first megabyte, which holds both LUKS2 headers, was zeroed:
`luksDump` failed before and succeeded after, and the passphrase was still valid. A header
backup file beats every other recovery route.

```bash
sudo cryptsetup luksHeaderRestore /dev/<partition> \
     --header-backup-file ~/luks-header-<label>.img
```

One caution worth passing on: a header backup remains valid for the passphrases
that existed when it was taken. Restoring an old backup reinstates revoked
passphrases and invalidates ones added since. Treat these files as
security-sensitive and re-take them after any passphrase change.

## When the header is damaged rather than missing

For LUKS2, try the built-in repair before anything else — it rebuilds the primary
header from the secondary copy and re-validates the JSON metadata:

```bash
sudo cryptsetup repair /dev/<partition>
```

Run it on the clone. It writes.

If `luksDump` reads the header but every passphrase fails, suspect the keyslot
area rather than the header. `cryptsetup luksDump --dump-json-metadata` (LUKS2)
shows the keyslot layout and helps distinguish a corrupted slot from a wrong
passphrase.

## What is still fatal

The same logic as VeraCrypt, for the same reason. The master key is random and
stored only in the keyslots, wrapped by your passphrase. If the header and all
keyslots are gone and no backup file exists, the ciphertext is permanently
sealed. A correct passphrase has nothing to unwrap.

And as always: if the disk reads as zeros, TRIM discarded the ciphertext and no
header would help.

## LUKS with LVM on top: the Linux default layout

This is what "Linux native encryption" means in practice on most installs. The
Ubuntu installer's encrypted option, and the equivalent on Fedora and Debian,
produces a stack rather than a single layer:

```
/dev/sdaN                  physical partition, type crypto_LUKS
  └─ /dev/mapper/dm_crypt-0    unlocked by cryptsetup
      └─ LVM physical volume
          └─ volume group  (e.g. ubuntu-vg)
              └─ logical volume  (e.g. ubuntu-lv)  ->  ext4 root
```

Four layers means four places damage can sit, and diagnosing the wrong one wastes
a lot of time. Work upward and confirm each layer before moving to the next —
that way a failure tells you exactly where you are.

```bash
# 1. Is the LUKS header intact?
sudo cryptsetup luksDump /dev/<partition>

# 2. Unlock it. Read-only while assessing.
sudo cryptsetup open --readonly /dev/<partition> recovered

# 3. Does LVM see a physical volume inside?
sudo pvs /dev/mapper/recovered
sudo vgscan --mknodes
sudo vgs; sudo lvs

# 4. Activate the logical volumes, then check the filesystem.
sudo vgchange -ay <volume-group>
sudo fsck -n /dev/<volume-group>/<logical-volume>
sudo mount -o ro /dev/<volume-group>/<logical-volume> /mnt/check
```

### Where a wiped partition table hurts here

Less than you would fear. The LUKS header lives at the start of the *partition*,
and LVM metadata lives inside the unlocked mapper device — so both sit past the
zeroed band, provided the partition did not start at sector 0. Recreate the
partition at the right offset and the whole stack usually comes back on its own.

Find the offset by scanning for the LUKS magic as described above, then rebuild
the partition entry exactly as in stage 5 of this skill.

### LVM metadata damage

LVM keeps a text archive of every metadata change, which makes this layer the
most forgiving of the four:

```bash
ls /etc/lvm/archive/                 # timestamped copies, on the root filesystem
ls /etc/lvm/backup/                  # current state per volume group
sudo vgcfgrestore -l <volume-group>  # list restore points
sudo vgcfgrestore -f /etc/lvm/archive/<vg>_<n>.vg <volume-group>
```

The catch is that this archive normally lives on the encrypted root you are
trying to recover, so it is unreachable when you need it. If the system boots at
all, copy `/etc/lvm/archive/` somewhere external now — it is a few kilobytes and
it turns an LVM metadata loss from serious into trivial.

Failing that, LVM writes its metadata in plain text inside the unlocked device,
so it can be read directly:

```bash
sudo dd if=/dev/mapper/recovered bs=1M count=2 status=none | strings | grep -A40 'ubuntu-vg\|^[a-z-]*vg {'
```

The extracted text can be hand-edited into a `.vg` file and fed to
`vgcfgrestore -f`. Tedious, but it recovers a volume group whose archive is gone.

### Recovering this stack from a live environment

A LUKS root cannot be repaired while it is mounted, so this work happens from a
live USB. The clone-first discipline still applies: image the physical partition
(or the whole disk) before unlocking anything, and do the repair on the copy.

One practical note specific to encrypted roots: after any change to the LUKS
header, the UUID in `/etc/crypttab` and the initramfs may no longer match, and the
system will boot to a passphrase prompt that never accepts anything. Check
`blkid` against `/etc/crypttab` and rebuild the initramfs from a chroot
(`update-initramfs -u -k all`) before concluding the recovery failed.


## Plain dm-crypt

`cryptsetup plain` volumes have **no header at all** — no magic, nothing to find,
nothing to back up. The parameters are the key: cipher, key size, hash, offset,
and key derivation, all supplied at open time.

That makes a lost partition table less damaging (nothing at the front to
destroy) and a forgotten parameter set completely fatal. If someone is recovering
a plain dm-crypt volume, the task is reconstructing the exact `cryptsetup plain`
invocation, and a single wrong parameter yields noise that looks identical to a
wrong passphrase. Sweeping parameter combinations is possible but the search
space is large; ask for any scripts or notes from when the volume was created
before attempting it.

## Advising someone on which to use

This comes up naturally at the end of a recovery, when the user is motivated to
change something. The honest answer is that the two trade differently rather than
one dominating, and the largest factor is neither of them.

**Locating a volume after the partition table is lost** favours LUKS decisively.
Its magic signature makes the search a scan; VeraCrypt's deliberate
indistinguishability from random data makes it a password-oracle sweep.

**Surviving a zeroed band at the front of the disk** favours VeraCrypt, which is
counterintuitive and worth stating plainly. VeraCrypt keeps an embedded backup
header in the last 128 KiB of the volume, far from the disk's head. LUKS2's
secondary header sits only 16 KiB past the primary, so the common "first
megabyte zeroed" accident destroys both; LUKS1 has no second copy at all.

**Backing the header up** favours LUKS heavily, and this is the factor that
actually decides outcomes. `cryptsetup luksHeaderBackup` is one scriptable
command; VeraCrypt's equivalent is a GUI action that people skip. Most
unrecoverable VeraCrypt volumes are unrecoverable for exactly this reason.

On security both use AES-XTS with a 256-bit key for the data path, so they are
equivalent there. Key derivation used to be a clear win for LUKS2's memory-hard
argon2id over VeraCrypt's PBKDF2, and much writing on this still says so — but
check the installed version before repeating it. VeraCrypt gained Argon2id
support during the 1.26 series, where the PIM field stops being a plain iteration
multiplier and becomes the Argon2 cost control: memory is
`min(64 MiB + (PIM - 1) x 32 MiB, 1024 MiB)` and iterations are
`3 + (PIM - 1)/3` up to PIM 31. The default Argon2 PIM of 12 gives 416 MiB and 6
passes, which is the same order of magnitude as a typical LUKS2 configuration.

Two things follow. A volume created before Argon2 support, or with a hash
explicitly chosen, still uses PBKDF2 — read the KDF line in the volume properties
rather than assuming. And with Argon2 a *lower* PIM weakens the volume rather
than merely speeding it up, which inverts the old intuition; VeraCrypt refuses
PIM below 12 for passwords shorter than 20 characters for exactly that reason.

Verify rather than recall:

```bash
veracrypt --text --version
strings "$(command -v veracrypt)" | grep -ci argon2   # non-zero => Argon2 available
```

What each has that the other cannot offer: VeraCrypt gives hidden volumes and
plausible deniability, and works on Windows and macOS. LUKS gives multiple
keyslots, TPM2 and FIDO2 enrolment via `systemd-cryptenroll`, and standard
tooling — on Linux only, in practice.

So: LUKS2 for storage that stays on Linux, VeraCrypt for cross-platform or
deniability. Then spend the remaining breath on the header backup, because it
matters more than the choice.
