# Pitfalls

Every entry here is a symptom that looks like failure but usually is not, or a
mistake that quietly costs data. Ordered roughly by how often it bites.

## Contents
- [The six-cause error message](#the-six-cause-error-message)
- [Declaring a header dead on input errors](#declaring-a-header-dead-on-input-errors)
- [The VeraCrypt GUI cannot see loop devices](#the-veracrypt-gui-cannot-see-loop-devices)
- [PKCS-5 PRF pinned to one hash](#pkcs-5-prf-pinned-to-one-hash)
- [Passwords leaking into shell history](#passwords-leaking-into-shell-history)
- [dd offsets truncated by block-size arithmetic](#dd-offsets-truncated-by-block-size-arithmetic)
- [iflag=direct silently reading nothing](#iflagdirect-silently-reading-nothing)
- [pkill -f matching its own command line](#pkill--f-matching-its-own-command-line)
- [fsck -n cannot diagnose this damage](#fsck--n-cannot-diagnose-this-damage)
- [Read-only flags lost on reboot](#read-only-flags-lost-on-reboot)
- [Device names shifting](#device-names-shifting)
- [Mounting the volume read-write during verification](#mounting-the-volume-read-write-during-verification)
- [Running one attempt at a time on a many-core machine](#running-one-attempt-at-a-time-on-a-many-core-machine)
- [Partition end beyond the GPT's last usable sector](#partition-end-beyond-the-gpts-last-usable-sector)
- [Stale VeraCrypt processes holding loop devices](#stale-veracrypt-processes-holding-loop-devices)
- [Treating a header backup as harmless](#treating-a-header-backup-as-harmless)

## The six-cause error message

VeraCrypt reports one message for wrong password, wrong PIM, wrong PRF, not a
volume, removed algorithm, and TrueCrypt format. It cannot distinguish them, by
design — a failed header decryption yields noise, with nothing to say why.

Consequence: a failure tells you this *combination* did not work. It is never
evidence about the header specifically. Change one variable at a time.

## Declaring a header dead on input errors

The most expensive mistake in this whole workflow. Manual attempts fail from
causes that have nothing to do with the volume: a paste that lands in the shell
instead of the prompt, `Ctrl+Z` suspending the process mid-attempt, the PIM
prompt answered with text, the keyfile prompt receiving a pasted command.

Every one of those produces the same six-cause message as a destroyed header.
Four failed manual attempts at a given offset are not evidence the offset is
wrong. Use `--pim=0 --keyfiles=` to suppress the prompts that cause it, and
prefer the automated sweep with a single password entry.

## The VeraCrypt GUI cannot see loop devices

`Select Device...` lists physical disks and partitions only. A volume reached
through a loop device at an offset will not appear. Selecting the bare disk
instead fails, because the volume does not start at sector 0 — VeraCrypt reads
the partition table where it expects a header.

Workaround: use `Select File...` and type the device path (`/dev/loopN`) into the
filename field. Better: rebuild the partition table so the volume gets a real
partition the picker lists.

## PKCS-5 PRF pinned to one hash

If the GUI's PRF dropdown is set to a specific hash rather than `Autodetection`,
every correct password fails. A frequent cause of "it worked from the terminal
but not the GUI".

Check also: `Use PIM` unchecked, `TrueCrypt Mode` unchecked, `Use keyfiles`
unchecked.

## Passwords leaking into shell history

When a paste misses the prompt, the password is echoed to the shell, "command not
found" is printed, and it is written to `~/.bash_history` on exit. Watch for this
and clean it in the shell that holds it:

```bash
history -d $(history | grep -n '<fragment>' | tail -1 | cut -d: -f1); history -w
```

Clearing the file alone is not enough — the running shell rewrites it on exit.

## dd offsets truncated by block-size arithmetic

`skip=$(( (SIZE - 524288) / 524288 ))` with `bs=512K` truncates when `SIZE` is
not a multiple of 512 KiB, and disk sizes generally are not. The read then lands
somewhere before the intended offset and returns zeros, which reads exactly like
"this region was wiped".

Use `bs=512` with sector arithmetic, or `iflag=skip_bytes` with a byte offset.
Verify by looking for a structure you expect at that offset — a GPT backup
header's `EFI PART` signature in the last sector, for instance.

## iflag=direct silently reading nothing

`O_DIRECT` imposes alignment requirements some devices reject at large block
sizes. `dd` prints `IO error: Invalid input` and produces an empty stream. Hashed,
that gives `e3b0c442...` — the SHA-256 of zero bytes — and two devices compared
this way appear to differ everywhere.

If a comparison shows `e3b0c442...`, the read failed; the data is fine. Drop
`iflag=direct` or reduce the block size.

## pkill -f matching its own command line

`pkill -9 -f 'keyfiles= /dev/loop100'` matches the shell running it, because that
pattern appears in its own command line. The shell dies before doing anything.

Use a pattern that cannot match itself: `'keyfiles= /dev/loop1[0-9][0-9]'`.

## fsck -n cannot diagnose this damage

`e2fsck -n` answers "no" to every repair, so it cannot rebuild the group
descriptor table it needs in order to read anything. It then walks a filesystem
it cannot interpret and reports almost nothing — a dry run on a fully recoverable
1 TB volume can report eleven files.

Do not read that as data loss. `-n` is useful for confirming a filesystem is
present; it cannot estimate what a real repair will recover. Run the repair on
the clone and measure there.

## Read-only flags lost on reboot

`blockdev --setro` is kernel state, not a disk property. After a reboot the disk
is writable again. Re-apply it as the first command after boot, before anything
else touches the disk. Say this out loud to the user — a frozen backup that
silently thaws is worse than one never frozen, because it is trusted.

## Device names shifting

`/dev/sdb` is assigned at discovery. Add or move a disk and it becomes `sdc`
while something else takes `sdb`. A script that writes to a remembered name will
eventually find the wrong disk.

Use `/dev/disk/by-id/` paths. `stable_path` in `lib.sh` resolves them.

## Mounting the volume read-write during verification

An ext3 mounted read-write replays its journal immediately, so the clone is no
longer byte-identical to the original. Harmless on a clone, but it ends any
bit-level comparison you were relying on. Mount `-o ro` while verifying, and for
ext specifically `-o ro,noload` also skips the replay.

## Running one attempt at a time on a many-core machine

Each unlock attempt is CPU-bound PBKDF2 and can take tens of seconds. Serially,
a hundred candidates is hours; at 24 in parallel on an idle many-core box it is
minutes. Check `nproc` and `uptime` before choosing — a sweep left running
serially is often abandoned before it reaches the right offset.

## Partition end beyond the GPT's last usable sector

A volume may extend past the last usable sector declared by an existing GPT
(Windows sometimes reserves extra space at the tail). `sgdisk` then refuses the
partition.

Check with `sgdisk -p`. A fresh GPT reserves only 33 sectors at the end and
usually leaves room. If it still does not fit, skip the partition — it is
cosmetic. The volume opens through a loop device at the recorded offset, which is
what actually matters.

## Stale VeraCrypt processes holding loop devices

Interrupted attempts leave `veracrypt` processes waiting on input, holding loop
devices and consuming CPU. A process stopped with `Ctrl+Z` ignores `SIGTERM`
until resumed, so `pkill` appears to do nothing; `SIGKILL` is needed.

Clean up before starting a sweep, or the state becomes hard to reason about.

## Treating a header backup as harmless

Recommend header backups without overselling their innocence. The file holds the
master key wrapped by the user's password, so it discloses nothing on its own —
but it is also the only verifiable target an attacker needs in order to test
passwords offline at full speed. Ciphertext alone offers no oracle; a header
does.

The marginal risk is narrower than it first sounds, because the on-disk header is
equally exposed to anyone holding the disk. The backup matters in the case where
someone obtains the backup but not the drive. So: store it with the same care as
the drive, ideally inside a separate encrypted container, and say plainly that
password strength is the only remaining barrier once the file is out.

Related: VeraCrypt asks for mouse entropy when backing up a header because it
regenerates the header with a fresh salt. The master key is unchanged and no data
is re-encrypted. It is good hygiene — the backup is not byte-identical to the
on-disk copy — but it does not harden the volume against brute force, and
describing it that way sets a false expectation.

For LUKS, one further caveat: a header backup reinstates the keyslots as they
were. Restoring an old one revives revoked passphrases and invalidates ones added
since, so re-take it after any passphrase change.
