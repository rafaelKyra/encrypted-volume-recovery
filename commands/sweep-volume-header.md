---
name: sweep-volume-header
description: Find where an unrecognisable encrypted volume starts by trial-decrypting candidate offsets with one password entry. Wraps the skill crypto-header-sweep.
---

Use the `encrypted-volume-recovery:crypto-header-sweep` skill on $ARGUMENTS.

The disk must already be read-only (`blockdev --setro`). Save the header candidates
before sweeping, copy them off the machine, then run the sweep. A failed attempt is
never evidence that the header is gone: it means this combination did not work.
