---
name: linux-source-build-setuid-cli
description: Build a Qt GUI plus setuid command-line tool from source on Ubuntu and package it as a local .deb, with the dependency list, CMake flags, staging, dpkg-shlibdeps and the traps that break it (a build path with parentheses, AppImage mounted nosuid, no distribution package). Use when asked how to install zuluCrypt on Ubuntu, why a package is not in the archive, how to turn a source tree into a .deb, or why a setuid helper stops working inside an AppImage.
---

# Source build to a local .deb, with a setuid CLI

## When to use
- A tool is not packaged for the distribution and must be built from source.
- The GUI depends on a CLI that must run as root (setuid) and an AppImage was proposed.
- A build fails with `Syntax error: "(" unexpected`.

## The rule
Build from a path without shell metacharacters, stage the install with `DESTDIR`, let `dpkg-shlibdeps` compute the dependencies, and ship the setuid CLI in a real `.deb` rather than an AppImage.

## Recipe
Worked example: zuluCrypt 7.1.1 on Ubuntu 26.04 with Qt6.

1. **Copy the source to a clean path,** for example `~/zuluCrypt-build`. A download folder named `zuluCrypt-master(1)` breaks the build: a step passes the path unescaped to `/bin/sh`.
2. **Install the build dependencies:**
   ```bash
   sudo apt-get install -y build-essential cmake pkg-config libcryptsetup-dev libblkid-dev \
     libdevmapper-dev uuid-dev libgcrypt20-dev libpwquality-dev libsecret-1-dev libudev-dev \
     qt6-base-dev qt6-tools-dev qt6-tools-dev-tools libqt6core5compat6-dev chrpath
   ```
3. **Configure and build:**
   ```bash
   mkdir build && cd build
   cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=RELEASE -DBUILD_WITH_QT6=ON \
     -DNOGUI=false -DUDEVSUPPORT=true -DSHARE_MOUNT_PREFIX=default -DHOMEMOUNTPREFIX=false \
     -DREUSEMOUNTPOINT=false -DNOGNOME=false -DNOKDE=true -DINTERNAL_ZULUPLAY=true \
     -DINTERNAL_LXQT_WALLET=true -DUSE_POLKIT=false ..
   make -j"$(nproc)"
   ```
   `-DUSE_POLKIT=false` is the upstream default and keeps the CLI setuid. Upstream's `BUILD_INSTRUCTIONS` describe `true` as installing the CLI **without** the suid bit, making the GUI ask for the root password through polkit and the CLI unusable by normal users.
4. **Stage the install** instead of installing into the system: `make DESTDIR="$PWD/../stage" install`
5. **Derive the dependencies:**
   ```bash
   mapfile -t objs < <(find stage/usr/bin stage/usr/lib -type f -perm -u+x; find stage/usr/lib -name '*.so.*')
   DEPS=$(dpkg-shlibdeps -lstage/usr/lib/x86_64-linux-gnu --ignore-missing-info -O "${objs[@]}" | sed 's/^shlibs:Depends=//')
   ```
6. **Write `stage/DEBIAN/control`** (package, version, architecture, your own Maintainer line, `Depends: $DEPS`, `Recommends: cryptsetup-bin, xdg-utils`) and a `postinst` that sets `chmod 4755` on `zuluCrypt-cli` and `zuluMount-cli`, runs `ldconfig`, and refreshes the desktop, mime and icon caches. Then `dpkg-deb --build stage zulucrypt_<version>_amd64.deb`.
7. **Install:** `sudo apt install ./zulucrypt_<version>_amd64.deb`

## Pitfalls
- **Parentheses (or spaces and other shell metacharacters) in the build path** make a build step fail with `Syntax error: "(" unexpected`. Copy the tree to a clean path; do not escape your way around it.
- **AppImage and setuid do not mix.** An AppImage is mounted through FUSE, and FUSE mounts made by unprivileged users are `nosuid`, so a setuid `zuluCrypt-cli` the GUI depends on loses its privilege. That is why the package route was chosen.
- **A setuid-root CLI is a larger attack surface than a polkit-mediated one.** It is upstream's default design; choose the polkit build if you prefer the other trade-off, accepting its limits (above).
- **Qt5 versus Qt6.** A first attempt that asked for `libqt5-dev` and `-DQT5=true` was abandoned; the working recipe uses Qt6. Do not reuse an old Qt5 install script.
- **The Maintainer field ends up in the package.** Use a role address, not a personal one, before sharing the `.deb`.
- **Redistribution is bound by the GPL.** If you hand the `.deb` to anyone you must offer the source, including any patch (see `patches/`).
- **Check "not in the archive" yourself:** the author's notes say Ubuntu 26.04 has no `zulucrypt` package; that was not re-verified here.

## Verification
- `dpkg-deb -c zulucrypt_*.deb | grep rwsr` must list `usr/bin/zuluCrypt-cli` and `usr/bin/zuluMount-cli` with mode `-rwsr-xr-x`.
- `zuluCrypt-cli -h` runs and its `-t` line lists the volume types (on the author's `7.1.1-3local`: plain, luks, tcrypt, vcrypt).
- `dpkg -l zulucrypt` shows the version you built.
Both the package contents and the installed CLI were checked on the author's machine on 2026-10-01. The build itself was not repeated for this plugin.
