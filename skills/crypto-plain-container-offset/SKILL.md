---
name: crypto-plain-container-offset
description: Open, create and recover PLAIN dm-crypt containers hidden inside a cover file (the zuluCrypt "hidden in video" mode), and find the offset when it was forgotten by deriving candidates from the cover file's own size invariants. Use when someone hid an encrypted container inside an mp4, mkv, avi, jpg or other file and lost the offset, asks how to open it from the command line, gets "-g" or "-t" errors from zuluCrypt-cli, or wants a hidden container that does not destroy its cover file.
---

# Plain dm-crypt containers: three values on no disk

## When to use
- A container was appended to a cover file and the offset is lost.
- Opening one from the command line fails or behaves differently from the GUI.
- Choosing a cover file, or advising someone who is about to create one.

## The rule
A PLAIN dm-crypt container has **no header**. Opening it needs three values that exist nowhere on disk: the **offset**, the **cipher specification** and the **passphrase**. Lose one and the data is gone. So record all three at creation; and when the offset is lost, do not guess blindly: it is constrained by how the container was made.

## Recipe
1. **Open from the command line.** The offset and cipher go through `-t` as one specification:
   ```bash
   zuluCrypt-cli -o -d cover.mp4 -m name -t aes.xts-plain64.256.sha256.<offset>b -h
   ```
   The specification is `<cipher>.<offset>b`; `-h` asks for the passphrase interactively. This is the form the detector probes with and prints. At **creation** the options go through `-g`, which the man page documents as starting with a random source, for example the LUKS default `/dev/urandom.aes.xts-plain64.256.sha1`; per the author's build notes the GUI creates containers with `-g /dev/urandom.<cipher>.<offset>b`. On the **open** path `-g` is not wired to plain volumes and the CLI parser has no offset flag, so on the command line the whole spec goes through `-t`. `zuluCrypt-cli -O` (open without mounting) is root-only; probe with `-o` and a throwaway mount name instead.
   Version caveat: the installed `zuluCrypt-cli -h` lists the volume types `plain/luks/tcrypt/vcrypt`, while the shipped man page lists `vera, plain/luks` and says `vera` is required to open a VeraCrypt volume. Check the build you have.
2. **When the offset is lost,** run the detector. It reads where the cover file legitimately ends (mp4/mov/m4v/m4a/3gp, avi/wav, mkv/webm, zip and Office/Java/Android archives, pdf), builds a bounded candidate list and probes each one read-only:
   `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/hidden-container/detect-hidden-container.py /path/to/cover.mp4`
   Add `--all` to find stacked containers. It asks for the passphrase once.
3. **Know why the list is short.** A container created by the zuluCrypt create dialog satisfies two properties: its size is a whole number of MB (the cover file is grown in 1024-byte chunks, so `file size = offset + n MB + r`, with `0 <= r < 1024`), and the offset is the original cover size rounded **up** to a whole KB, MB or GB depending on how large that file was. Together they bound the search to roughly 2,000 candidates whatever the file size, with the common sizes tried first.
4. **Patched zuluCrypt.** `patches/0001-zuluCrypt-gui-hidden-container-offset.patch` adds a *Detect* button to the unlock dialog that does the same from the GUI, shows the offset instead of masking it, warns about cover files that break, rejects containers of 3 MB or less before anything is written, and shows the three values after creation. It is GPL and separate: see the README.

## Pitfalls
- **A stale probe mount point reads as "wrong key".** After an interrupted scan every later probe fails with "could not create mount point"; read naively, a whole scan reports nothing found. The detector uses a name unique to the run and stops with an explanation. The same applies when a mapper for the file is already open.
- **Cover files that keep their index at the end** (zip, pdf, docx, xlsx, pptx, odt, jar, apk, epub, 7z, whl) are located by scanning back from the end of the file; an appended container pushes that index out of reach and the file stops opening. Prefer a video, audio or image file. The detector still handles zip and pdf hosts for recovery.
- **Stored offsets cost deniability.** The patch derives the offset from the cover file instead of storing it, on purpose: a stored offset would reveal that a container exists.
- **The offset field in upstream's unlock dialog is masked like a password,** which makes it impossible to proofread. The patch shows it; an offset is not a secret.
- **Passphrase handling in the detector:** it is read once and written to a mode-0600 temporary file that `zuluCrypt-cli -f` reads, then deleted in a `finally` block; it is not wiped and it is not on a tmpfs unless your temp directory is one. Do not run it on a shared machine.
- **TrueCrypt volumes are a different case,** not handled here: see the README.

## Verification
`python3 -m unittest tests/test_detect_hidden_container.py -v` runs 10 tests with no root and no zuluCrypt: the cover-end parsers for mp4 (index before or after the data), AVI, zip with 3 MB of appended data; and, over 60 random cover sizes and container sizes, that the true offset is among the candidates both with and without knowing the cover format, that older containers in a stack remain reachable, and that candidates are unique and inside the file. Measured candidate counts: about 1,100 for a 100 MB file, about 2,050 for 1 GB and for 8 GB.

Not covered: the probe itself (`zuluCrypt-cli` opening a candidate). That was exercised on the author's machine with the patched build; it is not reproduced by the test suite.
