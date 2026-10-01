# Encrypted volume recovery

**Recover VeraCrypt, LUKS and hidden dm-crypt volumes without making the damage worse.**

The instinct, when an encrypted disk stops opening, is to fix the disk. This plugin encodes the
opposite: the broken original is the only pristine copy, so it is locked read-only, imaged,
and left alone until a verified repair of a **frozen clone** has proved the way. Around that
discipline it adds three techniques that are rarely written down.

> Every claim in this repository is marked **tested**, **reported** or **planned**. The table
> under [Evidence](#evidence-what-is-tested-and-what-is-not) says which is which, and what is
> not covered is stated rather than implied.

## Three axes

| | Situation | What is unusual here | Evidence |
|---|---|---|---|
| **1. VeraCrypt** | The partition table is gone (Windows "Initialize Disk", a quick format of the table, an accidental repartition). The password is known, nothing opens. | A VeraCrypt header has no magic number, so the volume is found by **sweeping candidate offsets with the password**, once, in parallel. | Method used on one real 1 TB volume; scripts not yet run end to end |
| **2. zuluCrypt** | A PLAIN dm-crypt container hidden inside a video or other file, offset forgotten. Or zuluCrypt simply will not install. | The offset is **derived from the cover file's size invariants**, about 2,000 candidates whatever the file size. A source-build recipe for Ubuntu. A patch to zuluCrypt's GUI. | 10 automated tests; patch verified against upstream; probe tested on the author's machine |
| **3. LUKS** | A LUKS or LUKS2 disk lost its table or header. | A scan for six bytes instead of a sweep, the LUKS2 secondary header, and a measured finding: **tools that look read-only rewrite the header**. | 11 automated checks on file images; device level not tested |

## What is unusual

### The sweep: asking the password where the header might be
A VeraCrypt header is encrypted, so it cannot be recognised by looking. The only test is
*"does the password unlock a volume here?"*, which makes recovery a search. The sweep tries the
standard partition alignments plus every sector of any surviving island near the head of the
disk, as read-only loop devices, in parallel, and asks for the password **once**. The password
lives in an unexported shell variable and reaches `veracrypt` through a pipe, so it stays out of
`ps`, `/proc/*/environ`, shell history and disk.

Why once matters more than it sounds: manual attempts fail from mistyped entries, a paste that
lands in the shell, a prompt answered out of order. Every one of them prints the same message
VeraCrypt prints for a destroyed header, and a perfectly intact header gets declared dead.

The 1 MiB alignment is the other insight. Partitioning zeroes the first megabyte and stops
exactly where a volume in a 1 MiB-aligned partition keeps its header. That header usually
survives; a volume on the *whole raw device* does not, because its header and its backup both
fall inside the zeroed bands.

### The frozen clone, and the gates that enforce it
Recovery is run as a pipeline. Each stage reads the state recorded by the one before it and
refuses to start without it, and the final stage adds explicit gates:

```
original ──► lock read-only ──► save header candidates ──► find the volume (sweep / scan)
                                                                   │
                                                                   ▼
original (still untouched) ──► ddrescue clone ──► verify copy against source
                                                                   │
                                          repair the CLONE only  ◄─┘
                                                   │
                                  verify: archive CRCs, full tree walk, e2fsck counts
                                                   │
                       freeze the clone ──► repair the ORIGINAL, last, behind gates
```

- The original is locked with `blockdev --setro` in the first minute, and every later stage calls `assert_ro` and **refuses to continue** if the device is writable.
- The original is touched only if the clone unlocks, its filesystem mounts, and it does not look too empty to be a real backup.
- All experiments run on the clone: break it freely, re-clone.
- A lint (`scripts/lint-recovery-scripts.sh`) fails if a script other than the three designed stages grows a command that writes to a disk.

### Tools that look read-only are not
With a LUKS2 header zeroed and the secondary copy intact, `cryptsetup luksDump`, `isLuks`,
`luksDump --dump-json-metadata` and `open --test-passphrase` each **rewrote the primary header**.
`--readonly` did not prevent it; a file made read-only did. That is convenient on a clone and
destructive on an original you are still diagnosing, because the rewrite erases the evidence of
how it was damaged. Reproduce it: `bash tests/test_luks_file_images.sh`. Observed on cryptsetup
2.8.4 with file images; behaviour on a block device was not tested.

### Hidden containers: three values on no disk
A PLAIN dm-crypt container has no header. Opening it needs the **offset**, the **cipher
specification** and the **passphrase**, none of which is stored anywhere. When the offset is
lost it is still constrained: the create dialog makes the container a whole number of MB and
sets the offset to the original cover size rounded up to its own KB, MB or GB tier. The
detector turns that into a bounded candidate list (1,122 for a 100 MB file, about 2,050 for 1 GB
and for 8 GB, measured) and probes each one read-only. It reads where the cover file
legitimately ends for mp4, avi, mkv, zip-based formats and pdf.

## What this adds for zuluCrypt

zuluCrypt is a graphical and command-line front end to cryptsetup and tcplay by Francis
Banyikwa. This repository does not copy its code. It contributes:

1. **A patch to `zuluCrypt-gui`** (`patches/`, GPL-2.0-or-later, 295 lines in 4 files):
   - a **Detect** button in the unlock dialog that finds a hidden container's offset from the cover file alone;
   - the offset field **shown** instead of masked like a password;
   - a warning when the cover file keeps its index at the end (zip, pdf, Office formats, jar, apk, epub, 7z, whl), since an appended container makes such a file stop opening;
   - rejection of a container of 3 MB or less *before* the cover file is grown (upstream only refused afterwards, leaving the file bigger and nothing created);
   - after creation, a dialog showing the offset, cipher and the reminder that the passphrase is the third value, with the offset copied to the clipboard.

   It applies cleanly to an upstream snapshot and reproduces the author's build byte for byte. It is worth sending upstream.
2. **A detector script** (`scripts/hidden-container/`, MIT) that does the same from the terminal and finds *stacked* containers with `--all`.
3. **Documentation upstream does not have:** the `-g` versus `-t` trap when opening plain volumes from the command line and the fact that `-O` is root-only (both from the author's build notes, not re-verified here), and one discrepancy found when checking: the installed help lists the types `tcrypt/vcrypt` while the man page lists `vera`.
4. **A source-build recipe for Ubuntu** (`skills/linux-source-build-setuid-cli`): the exact packages, CMake options and `.deb` packaging for Qt6, and the traps that break it: a build path containing parentheses, and AppImage mounted `nosuid`, which defeats the setuid CLI.

zuluCrypt is also the Linux route to the other end of the axis: `zuluCrypt-cli` lists the
volume types `plain`, `luks`, `tcrypt` and `vcrypt` and has a `-W` check for TrueCrypt devices.
The VeraCrypt 1.26.29 command line used here lists no TrueCrypt option, and the sweep script
itself says TrueCrypt volumes are no longer supported. Whether `tcrypt` opens a real TrueCrypt
volume was **not tested**; it is on the planned list.

## Evidence: what is tested and what is not

| Claim | Status | How | Where |
|---|---|---|---|
| Offset candidate logic finds the true offset (60 random cases, with and without cover format) | **Tested** | unit tests, no root | `tests/test_detect_hidden_container.py` |
| Cover-end parsers (mp4 both layouts, AVI, zip with 3 MB appended) | **Tested** | unit tests | same |
| LUKS layout, secondary header, payload offsets, wiped-front destruction, backup and restore | **Tested** | 11 checks on throwaway images, cryptsetup 2.8.4 | `tests/test_luks_file_images.sh` |
| LUKS2 inspection commands rewrite a damaged header | **Tested** (file images only) | characterisation | same |
| The patch applies to upstream and reproduces the author's build | **Tested** | `patch --dry-run`, byte comparison | `references/DECISIONS.md` |
| Package carries setuid on exactly two CLIs; installed build is `7.1.1-3local` | **Tested** | `dpkg-deb -c`, `dpkg -l` | `skills/linux-source-build-setuid-cli` |
| Recovery method on a real 1 TB VeraCrypt volume | **Used once, completed** | header found at 1 MiB, clone repaired and verified (CRCs, full walk, `lost+found` empty), clone frozen, original repaired with identical counts; owner reports 100 % | `references/DECISIONS.md`; one directory correction is reported but not yet documented |
| The six numbered recovery scripts | **Not run end to end** | pass `bash -n` and the lint; they generalise ad-hoc scripts used in the real recovery | planned test below |
| The zuluCrypt probe and the Detect button | **Used on the author's machine** | not reproduced by the suite | needs zuluCrypt |
| The `-g` versus `-t` trap, `-O` being root-only | **Reported** | the author's build notes; the installed help confirms `-t` takes the volume type | not reproduced |
| 74 ms per probe, 18 probes typical | **Reported** | author's measurement | not reproduced |
| LUKS recovery on a real disk, LVM on LUKS | **Planned** | documented only | none |

Run everything that needs no root:

```bash
python3 scripts/validate_plugin.py . --strict
bash scripts/lint-recovery-scripts.sh
python3 -m unittest tests/test_detect_hidden_container.py -v
bash tests/test_luks_file_images.sh
```

## Planned / unverified

Kept here, not in a skill, because nothing in this repository demonstrates them.

| Item | Status |
|---|---|
| **Sweeping with the embedded backup header.** After a quick format that overwrote the first sectors of the partition, the standard header is gone and the copy at the end of the volume survives. `veracrypt --mount-options=headerbak` ("use backup headers when mounting") and `--restore-headers` ("from the embedded or an external backup") exist in VeraCrypt 1.26.29, and the scripts save that region, but the sweep does not use it. | Not implemented or tested |
| **End-to-end test on a loop device** (needs root), the test that would close the gap on the six scripts. | Written up in `tests/README.md`, not written |
| **TrueCrypt volumes through `zuluCrypt-cli -t tcrypt`.** | Not tested |
| **LUKS recovery on a block device and with LVM on top.** | Not tested |
| **Stage 2 for volumes created with a PIM or keyfiles.** The sweep uses `--pim=0` and no keyfiles. | Not supported |
| **A quick format of an SSD.** TRIM can zero the ciphertext; the assessment stage reports it, nothing recovers it. | Out of scope |

## Install and use

```bash
claude --plugin-dir ./encrypted-volume-recovery
```

Skills are namespaced, for example `/encrypted-volume-recovery:crypto-header-sweep`. Commands:
`recover-encrypted-volume`, `sweep-volume-header`, `find-hidden-container`, `build-setuid-cli`.

| Skill | Axis | One mechanism |
|---|---|---|
| `crypto-clone-first-repair` | 1, 3 | Lock, image, repair the copy, freeze, repair the original last |
| `crypto-header-sweep` | 1 | Find a volume that cannot be recognised by asking the password |
| `crypto-luks-header-recovery` | 3 | Scan, inspect, repair and back up LUKS headers |
| `crypto-plain-container-offset` | 2 | Recover a hidden container's offset from size invariants |
| `linux-source-build-setuid-cli` | 2 | Source build to a local `.deb` with a setuid CLI |

An agent running these cannot type your password and should not try: it hands you the command,
you enter the passphrase, it reads the outcome.

## Intended use and limits

- **Your own data.** This recovers volumes you are entitled to open. The detector tests the passphrase you give it; it does not guess one.
- **No guarantee.** Recovery depends on what was overwritten. A whole-device VeraCrypt volume with both header regions zeroed is unrecoverable without a header backup file, and a quick format of an SSD may leave nothing. The assessment stage tells you which case you are in.
- **Back up your headers** (VeraCrypt: *Tools, Backup Volume Header*; LUKS: `luksHeaderBackup`) and keep them off the disk they describe: 128 KiB for VeraCrypt, 16 MiB for a LUKS2 default header. A header backup is also the only thing an attacker needs to test passwords offline, so store it with the same care as the disk.
- **A setuid-root CLI is a larger attack surface** than a polkit-mediated one. It is upstream's default; the build skill explains the alternative.

## Licences and credits

- **Plugin, scripts, documentation:** MIT, see `LICENSE`.
- **`patches/0001-...patch`:** GPL-2.0-or-later. It is a derivative of zuluCrypt (c) 2011-2015 Francis Banyikwa and carries the same terms as the files it modifies. It is **not** covered by the MIT licence. Anyone who redistributes a package built with it must offer the corresponding source.
- zuluCrypt is by Francis Banyikwa. VeraCrypt is by IDRIX and contributors. cryptsetup is by the cryptsetup project. This plugin is independent of all three and is not endorsed by them.

Part of an open series of plugins; it follows the series' merge contract (skills named
`<domain>-<mechanism>`, no product name in a skill name, one mechanism per skill, the fixed
section order, `DECISIONS.md` and `PITFALLS.md`).

Copyright 2026 Rafael Kyra.
