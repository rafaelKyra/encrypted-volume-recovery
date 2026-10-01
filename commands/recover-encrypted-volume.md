---
name: recover-encrypted-volume
description: Recover an encrypted disk whose partition table or header was damaged, using the clone-first discipline. Wraps the skill crypto-clone-first-repair.
---

Use the `encrypted-volume-recovery:crypto-clone-first-repair` skill to recover $ARGUMENTS.

Start by identifying the case without asking the user to recall it: run the assessment
stage on a read-only device, decide VeraCrypt versus LUKS from the evidence, and only
then pick `crypto-header-sweep` or `crypto-luks-header-recovery` for stage 2. Never
write to the original disk before a verified clone exists. If you are an agent, you
cannot type the user's password: hand over each command that asks for it.
