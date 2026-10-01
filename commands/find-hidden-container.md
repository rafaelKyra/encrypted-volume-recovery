---
name: find-hidden-container
description: Find the offset of a PLAIN dm-crypt container hidden in a cover file. Wraps the skill crypto-plain-container-offset.
---

Use the `encrypted-volume-recovery:crypto-plain-container-offset` skill on $ARGUMENTS.

Run the detector on the cover file; it asks for the passphrase once and probes a
bounded set of candidate offsets read-only. This is for recovering your own data:
it tests the passphrase you give it and does not guess one.
