---
name: build-setuid-cli
description: Build a Qt GUI with a setuid CLI from source on Ubuntu and package it as a local .deb. Wraps the skill linux-source-build-setuid-cli.
---

Use the `encrypted-volume-recovery:linux-source-build-setuid-cli` skill to build $ARGUMENTS.

Copy the source to a path without shell metacharacters first, stage the install with
`DESTDIR`, and verify the setuid bit on the CLI binaries in the finished package.
