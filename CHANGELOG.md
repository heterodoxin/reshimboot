# Changelog

## reshimboot r1.0.0

reshimboot is a fork of [ading2210/shimboot](https://github.com/ading2210/shimboot)
that drops multi-board and multi-distro support to focus entirely on the
`dedede` board (Intel Jasper Lake, kernel 5.4) with a modern Debian userland.

### Build system

- Replaced the `binwalk` + `pcregrep` shim extraction with `tools/shimtool.py`,
  a dependency-free Python tool that parses the vboot keyblock/preamble and the
  kernel ELF directly. It is deterministic, works with any binwalk version
  (fixes the binwalk 3.x breakage), and streams the shim from the download so a
  5 GB image is never stored twice.
- The disk image is now built without loop devices (`mkfs.ext4 -d`, `sfdisk`,
  `debugfs`), so it works in containers, CI runners, and WSL. LUKS still uses a
  single loop device for the encrypted partition only.
- The build verifies (by SHA-256) that the installed systemd really came from
  the patched shimboot repo and aborts otherwise, instead of producing an image
  that hangs at "Failed to mount API filesystems".
- Consolidated all shared logic in `common.sh` with proper cleanup traps, and
  added `tools/lint.sh` (shellcheck + busybox syntax + Python) run in CI.
- Removed ARM/arm64, Alpine, Ubuntu, and Artix support.

### Operating system

- Debian 13 (Trixie) by default, with deb822 apt sources and the security and
  updates repositories enabled.
- PipeWire + WirePlumber replace PulseAudio; NetworkManager, systemd-resolved,
  and systemd-timesyncd are set up and enabled.
- Working internal audio on dedede: the SOF community firmware path is set and
  the WeirdTreeThing Chromebook UCM configs are installed and re-applied when
  `alsa-ucm-conf` is upgraded.
- iptables uses the legacy backend, since the 5.4 kernel has no `nf_tables`.
- exFAT and NTFS work through FUSE; the shim kernel lacks the in-kernel drivers.
- Locale and timezone are configured at build time; added a `set_timezone`
  helper.
- `bwrap` is made setuid with `dpkg-statoverride` so Steam and Flatpak sandboxes
  work and survive upgrades.
- Kernel modules and firmware from the shim and recovery image are layered under
  `/lib/firmware/updates/<version>` so the 5.4 kernel loads firmware it supports
  instead of newer firmware that can crash it.
- Debian kernel packages are pinned off (they can never boot the shim).

### Bootloader

- Added an auto-boot countdown that boots the first Debian rootfs unless a key
  is pressed.
- Chrome OS boot now blocks `update_engine`, which stops the forced "update
  required" screen on every boot and stops a background update from booting
  normally and undoing the verified-mode spoof. Nothing is written to the
  internal drive.
- The rootfs is mounted with `discard,noatime`, and LUKS is opened with
  `--allow-discards`.
- Boots fail gracefully back to the menu instead of dropping to a confusing
  state.

### Reliability

- `sysctl` tuning makes hung-task and soft-lockup non-fatal and caps dirty-page
  writeback, so slow USB drives no longer trigger a kernel panic that reboots
  the Chromebook to recovery.
- Suspend and hibernation are disabled cleanly (the shim kernel cannot do
  either), and the lid switch locks instead of suspending.
- The rootfs auto-expands on first boot.
- Added `shimboot-doctor`, a one-command diagnostic for bug reports.
