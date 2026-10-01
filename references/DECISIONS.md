# Decisions and measured facts

Numbers with dates, what they beat, and what breaks if they change. Where a figure was
reported by the author and not reproduced, it says so.

## The real recovery that produced the method (2026-09-28)

| Fact | Value | Source |
|---|---|---|
| Volume | VeraCrypt, AES-XTS, HMAC-SHA-512, no PIM, no keyfile, ext3 inside, about 1 TB | author's runbook |
| Cause | a Windows "Initialize Disk" wrote an empty GPT and zeroed the first 1 MiB and the last 745,984 bytes of the disk | runbook |
| Where the header was | the volume began at exactly 1 MiB, the first byte after the zeroed band, so the standard header survived | runbook; the sweep found offset 1,048,576 |
| Embedded backup header | intact, at the end of the volume | runbook |
| Filesystem | primary superblock intact, backup superblocks valid across the whole volume, primary group descriptor table and resize inode damaged | runbook |
| Repair chosen | rebuild from a backup superblock (`e2fsck -f -b 32768 -B 4096`), on the **clone only** | runbook |

Timeline from the runbook's file timestamps: header extraction 08:50, first sweep scripts
09:07 to 09:14, offset found 09:52, clone map last written 13:06, clone repair script 13:33,
original repair script 14:55.

**Final outcome (session transcript of 28 Sep 2026, plus owner report).** The recovery was
completed on the clone and then on the original; the owner reports it as 100 %.
Transcript evidence: on the clone `e2fsck` reported 5,616,893 files / 226,570,211 blocks,
`lost+found` held 0 entries, a full `find` walked 5,783,072 entries with no error, and three
large ZIPs (2.1 GB, 894 MB, 1.2 GB) passed `unzip -t`. The owner then opened it manually.
The clone was then given a partition entry (stable name, visible in the GUI device list),
frozen read-only, and the same repair ran on the original: identical `e2fsck` counts, GPT
partition written only after the filesystem mounted, `e2fsck` exit code 1 = "errors fixed".
Order that mattered: sweep -> test on clone -> repair clone -> verify -> freeze -> repair
second copy/original.

**Directory correction: not located.** The owner mentions one further correction "related to
directories". The transcript shows only group-descriptor/resize-inode rebuild, `lost+found`
checks, and private-directory permissions (a `drwx------` directory needed `sudo` to list).
No separate directory-fixing step was found, so none is documented as fact.
`TODO(owner): describe the directory correction (command, symptom).`

### Where the packaged scripts come from

The recovery was done with ad-hoc scripts written during the work (`sweep.sh`, `sweep2.sh`,
`try.sh`, `test-candidat.sh`, `repara-clona.sh`, `repara-nvme.sh`). The numbered scripts in
`scripts/recovery/` were written afterwards (2026-09-28, 15:07 to 15:09) as a generalisation.
They are byte-identical to that generalisation and **have not been run end to end on a disk**.

| Script | sha256 (first 12) |
|---|---|
| 00-assess.sh | 01a64c6afc49 |
| 10-extract-headers.sh | 2c4b9a572b96 |
| 20-sweep-offsets.sh | bfc998e2f2ac |
| 30-clone.sh | 92859004ec48 |
| 40-repair-clone.sh | 2ba0d8dea03f |
| 50-repair-original.sh | 06c2f2e6fedd |
| lib.sh | b1f434901223 |

All pass `bash -n`. `shellcheck` was not available.

## Header sweep

- **Candidates:** sectors 2048, 1024, 4096, 8192, 34, 63, 56, 32, plus every sector from the first surviving data sector up to +256 when that sector is below 4096. Ordered by how often each turned out to be right. A partition aligned at 1 MiB is by far the most common and is where the real header was.
- **One password entry for all candidates.** Reason: a single attempt runs PBKDF2 across several hash and cipher combinations and costs seconds to a minute; typing the password per candidate is where manual attempts fail (mistyped entries, a paste landing in the shell, prompts answered out of order), and each of those failures prints the same message as a destroyed header. Reported by the author; timings were not reproduced here.
- **What the sweep does not try:** the embedded backup header (`headerbak`), a PIM other than 0, keyfiles, TrueCrypt format. See the README's planned list.

## LUKS (measured 2026-10-01, cryptsetup 2.8.4, 64 MB file images, no root)

| Measurement | Value |
|---|---|
| LUKS2 primary magic | `LUKS\xba\xbe` at offset 0 |
| LUKS2 secondary header | magic `SKUL\xba\xbe` at offset 16384 |
| LUKS1 secondary header | none |
| LUKS2 default payload offset | 16,777,216 bytes (16 MiB) |
| LUKS1 default payload offset | 4096 sectors |
| LUKS2 header backup file | 16,777,216 bytes. The earlier reference text said "a few megabytes"; corrected |
| LUKS1 header backup file | 2,068,480 bytes |
| First MiB zeroed | LUKS2 `luksDump` fails, `cryptsetup repair` reports "not a valid LUKS device" |
| LUKS1, 16 KiB zeroed | `repair` reports "not a valid LUKS device" |
| Restore from a backup file after the first MiB was zeroed | works; `luksDump` succeeds and the passphrase is valid |
| Primary header zeroed, secondary intact | `luksDump`, `isLuks`, `luksDump --dump-json-metadata` and `open --test-passphrase` each rewrote the primary header; a `chmod 444` file stayed untouched |

Reproduce: `bash tests/test_luks_file_images.sh` (11 hard checks passed on 2026-10-01, plus the
characterisation above). The PBKDF was forced to pbkdf2 with 1000 iterations for speed; the
on-disk layout does not depend on it. Not measured: block devices, loop devices, LVM.

## Hidden containers (zuluCrypt)

| Fact | Value | Status |
|---|---|---|
| Candidate count, 100 MB file | 1,122 | measured by `tests/test_detect_hidden_container.py` |
| Candidate count, 1 GB file | 2,046 | measured |
| Candidate count, 8 GB file | 2,053 | measured; the build notes said about 1,040, a figure from an earlier iteration of the algorithm |
| True offset among candidates | 60 of 60 random cover and container sizes, with and without knowing the cover format | tested |
| Per-probe cost | about 74 ms, a typical case resolved within 18 probes (about 1.3 s) | **reported by the author, not reproduced** |
| The probe (`zuluCrypt-cli` opening a candidate) | works on the author's machine with the patched build | **not covered by the test suite** |

Why the offset is bounded: the create dialog makes the container a whole number of MB, grows
the cover file in 1024-byte chunks, and sets the offset to the original cover size rounded up
to a whole KB, MB or GB depending on how large that file was.

### The patch

| Fact | Value |
|---|---|
| Files | `zuluCrypt-gui/createvolumeinexistingfile.cpp`, `password_dialog.cpp`, `password_dialog.h`, `password.ui` |
| Size | 295 added lines and 1 removed |
| Applies to | an upstream master snapshot whose CMake version is 7.1.1 (files dated 2026-05-21) |
| Verified | `patch -p1 --dry-run` succeeds on that snapshot and the patched files are byte-identical to the author's build tree |
| Installed build | `7.1.1-3local` |

Behaviour added: a Detect button in the unlock dialog; the offset field shown instead of
masked; a warning for cover files that keep their index at the end (zip, pdf, docx, xlsx,
pptx, odt, ods, odp, jar, apk, epub, 7z, whl); rejection of a container of 3 MB or less before
the cover file is grown (the backend refused it only after growing the file); a dialog after
creation showing offset, cipher and the reminder that the passphrase is the third value, with
the offset copied to the clipboard.

## Build facts (zuluCrypt 7.1.1, Ubuntu 26.04.1 LTS, Qt6)

- Options: `BUILD_WITH_QT6=ON`, `USE_POLKIT=false`, `NOKDE=true`, `INTERNAL_ZULUPLAY=true`, `INTERNAL_LXQT_WALLET=true`, `UDEVSUPPORT=true`, release build, prefix `/usr`.
- The package sets mode 4755 on `zuluCrypt-cli` and `zuluMount-cli` and contains no other setuid file listed in `usr/bin`.
- Three local package revisions (`-1local`, `-2local`, `-3local`); `-3local` carries the patch.

## Reported, not re-derived

- The 74 ms per probe and 18-probe figures above.
- That Ubuntu 26.04 has no `zulucrypt` package.
- That AppImage is unsuitable because FUSE mounts are `nosuid`.
- The 24-way parallel sweep finishing in minutes on a many-core machine.
