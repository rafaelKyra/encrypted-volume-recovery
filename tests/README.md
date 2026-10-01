# Tests

| Test | Needs | What it covers | Last result |
|---|---|---|---|
| `python3 -m unittest tests/test_detect_hidden_container.py -v` | Python 3 | Cover-file parsers and the offset candidate logic | 10 passed, 2026-10-01 |
| `bash tests/test_luks_file_images.sh` | `cryptsetup` | LUKS layout, destruction, header backup and restore on throwaway file images; records the auto-repair behaviour | 11 passed, 2026-10-01 (cryptsetup 2.8.4) |
| `bash scripts/lint-recovery-scripts.sh` | bash, Python | Syntax, and that only the designed stages can write to a disk | see below |
| `python3 scripts/validate_plugin.py . --strict` | Python 3 | Manifest, frontmatter and the series' evidence rules | see below |

None of these needs root and none touches a real disk or device-mapper.

## Not covered, and why it matters

- **The six numbered recovery scripts have never been run end to end on a disk.** The method
  was used on one real volume; these scripts are a later generalisation.
- **The zuluCrypt probe** (`zuluCrypt-cli` opening a candidate) is not exercised.
- **Anything that needs `losetup`, `cryptsetup open` or LVM.**

## Planned: an end-to-end test on a loop device (needs root)

This is the test that would close the first gap. It is **not written yet**; it is listed so
nobody mistakes the suite above for it.

1. Create a 256 MB image file, attach it with `losetup`.
2. Create a partition aligned at 1 MiB, then a VeraCrypt volume (and, separately, a LUKS2 volume) inside it with a throwaway passphrase, and put an ext filesystem and a few files in.
3. Zero the first MiB and the last MiB, then write an empty GPT (the Windows "Initialize Disk" pattern).
4. Run stages 00 to 50 against a second loop device as the clone, entering the passphrase once.
5. Assert that the offset found is 1,048,576, that the files are intact after the repair, and that stage 50 refuses to run when the clone does not unlock.

Run it only inside a throwaway VM or on loop devices you created yourself.
