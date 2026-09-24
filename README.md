# reshimboot

**A modernized [shimboot](https://github.com/ading2210/shimboot) focused entirely on the `dedede` board.**

reshimboot boots a full desktop Debian install on a dedede Chromebook by turning a Chrome OS RMA shim into a bootloader. It does not touch the firmware and works on enterprise-enrolled devices.

This is a fork of ading2210's shimboot that trades multi-board support for a build that is smaller, faster, and tuned specifically for dedede — Debian 13 by default, working audio, more reliable Wi-Fi, PipeWire, no more forced Chrome OS updates when spoofing verified mode, and a `shimboot-doctor` diagnostic tool. If you have a different Chromebook, use the [original shimboot](https://github.com/ading2210/shimboot).

## Table of Contents
- [What is dedede?](#what-is-dedede)
- [What changed from shimboot](#what-changed-from-shimboot)
- [How it works](#how-it-works)
- [Building](#building)
- [Booting the image](#booting-the-image)
- [Booting Chrome OS through reshimboot](#booting-chrome-os-through-reshimboot)
- [Feature support on dedede](#feature-support-on-dedede)
- [FAQ](#faq)
- [Copyright](#copyright)

## What is dedede?

`dedede` is the board name for a large family of 2021-era Intel Jasper Lake Chromebooks (Celeron N4500 / N5100 / Pentium N6000). Common models include the Lenovo 100e/300e/500e Gen 3, Acer Chromebook 511/512/314, Dell Chromebook 3110/3111, HP Chromebook 11 G9 EE, and many more. If [cros.download](https://cros.download/recovery) lists your Chromebook's board as `dedede`, this project is for you.

dedede uses a **5.4 kernel** in its RMA shim. That single fact drives most of the tuning in this project: the kernel is old, has no `nf_tables`, no `zstd`/`lz4` in the compressed-memory path, no unprivileged user namespaces, and can crash if it is asked to do things newer kernels handle. reshimboot works around each of these instead of pretending the kernel is modern.

## What changed from shimboot

Compared to upstream shimboot, reshimboot:

- **Only builds for dedede.** No board matrix, no ARM code paths, no per-board special cases. The board, architecture and kernel are known, so everything can be tuned for them.
- **Removes the binwalk / pcregrep dependencies.** The shim kernel and its initramfs are now parsed directly from the vboot and ELF structures by `tools/shimtool.py` (pure Python standard library). This is deterministic, works with any binwalk version, and streams the shim straight from the download so a 5 GB image is never stored twice. See [issue #526](https://github.com/ading2210/shimboot/issues/526) and the [binwalk 3.x breakage](https://github.com/ading2210/shimboot/issues/353).
- **Builds the disk image without loop devices** (using `mkfs.ext4 -d` and `debugfs`), so it works in more containers, CI runners, and WSL.
- **Defaults to Debian 13 (Trixie)** with a modern stack: PipeWire + WirePlumber instead of PulseAudio, NetworkManager, systemd-resolved/timesyncd, deb822 apt sources with the security and updates repos enabled.
- **Fixes audio on dedede** by shipping the SOF community firmware path and the [Chromebook UCM configs](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros), which survive `alsa-ucm-conf` upgrades. ([#518](https://github.com/ading2210/shimboot/issues/518), [#460](https://github.com/ading2210/shimboot/issues/460))
- **Stops the forced Chrome OS update** when booting Chrome OS with the verified-mode spoof — see [below](#booting-chrome-os-through-reshimboot). ([#359](https://github.com/ading2210/shimboot/issues/359), [#406](https://github.com/ading2210/shimboot/issues/406))
- **Makes iptables work** by selecting the legacy backend, since the 5.4 shim kernel has no `nf_tables`. ([#414](https://github.com/ading2210/shimboot/issues/414))
- **Improves Wi-Fi reliability** with power-save and PMF defaults tuned for the older drivers, and firmware from the shim kernel is given priority so the old kernel never loads firmware it can't handle. ([#487](https://github.com/ading2210/shimboot/issues/487), [#490](https://github.com/ading2210/shimboot/issues/490), [#506](https://github.com/ading2210/shimboot/issues/506))
- **Prevents the "reboot to recovery" / random power-off crashes** by making hung-task and soft-lockup non-fatal and capping dirty-page writeback, which the 5.4 kernel otherwise turns into a kernel panic on slow USB drives. ([#423](https://github.com/ading2210/shimboot/issues/423), [#461](https://github.com/ading2210/shimboot/issues/461))
- **Guarantees the patched systemd is installed.** An unpatched systemd is the cause of the "Failed to mount API filesystems" boot hang; the build now verifies the systemd it installed really came from the shimboot repo and aborts if not. ([#432](https://github.com/ading2210/shimboot/issues/432), [#508](https://github.com/ading2210/shimboot/issues/508))
- **Sets up locale and timezone at build time** so apps like Steam/Proton don't lag generating locales, and adds a `set_timezone` helper. ([#475](https://github.com/ading2210/shimboot/issues/475), [#504](https://github.com/ading2210/shimboot/pull/504))
- **Fixes Steam/Flatpak sandboxing** by making `bwrap` setuid with `dpkg-statoverride`, so it survives package upgrades. ([#306](https://github.com/ading2210/shimboot/issues/306))
- **Handles external drives**: exFAT and NTFS work through FUSE, since the shim kernel lacks the in-kernel drivers. ([#512](https://github.com/ading2210/shimboot/issues/512))
- **Auto-expands the rootfs on first boot**, checks the filesystem before every boot, and can auto-boot the first OS after a countdown.
- **Adds `shimboot-doctor`**, a one-command diagnostic that reports everything a bug report needs.
- **Lints in CI** (`shellcheck` + Python) and disables Debian kernel packages that can never boot.

Removed: ARM/arm64 support, the Alpine, Ubuntu and Artix rootfs paths, and the multi-board download logic. reshimboot is Debian-on-dedede only.

## How it works

Chrome OS RMA shims are bootable images that run even on enrolled devices. Because [the shim's root filesystem is not verified](https://sh1mmer.me/), it can be replaced with a bootloader that `pivot_root`s into a normal Linux rootfs.

The Chrome OS kernel refuses to boot a normal systemd because of how systemd sets up its early mounts, so reshimboot uses a [patched systemd](https://github.com/ading2210/chromeos-systemd) hosted in the shimboot apt repo. Kernel modules and firmware are taken from the shim (kernel 5.4) and the Chrome OS recovery image and layered under `/lib/firmware/updates` so they take priority over Debian's firmware without overwriting dpkg-owned files.

### Partition layout

1. 1 MB dummy stateful partition
2. 32 MB Chrome OS kernel (taken from the shim)
3. Bootloader partition (the patched shim initramfs)
4. Debian rootfs (fills the rest of the disk)

The rootfs partition must be named `shimboot_rootfs:<name>` for the bootloader to find it.

## Building

You need a Linux machine (Debian/Ubuntu recommended, WSL2 works) with about 20 GB free and root access.

```bash
git clone https://github.com/heterodoxin/reshimboot
cd reshimboot
sudo ./build_complete.sh
```

That downloads the dedede shim and recovery image, builds a Debian Trixie XFCE rootfs, patches in the dedede drivers, and writes `data/shimboot_dedede.bin`.

Useful options (`key=value`):

```bash
# a different desktop
sudo ./build_complete.sh desktop=gnome

# a different Debian release
sudo ./build_complete.sh release=bookworm

# an encrypted rootfs (you will be prompted for a password)
sudo ./build_complete.sh luks=1

# compress the finished image to a .zip
sudo ./build_complete.sh compress_img=1
```

Valid desktops: `xfce` (default), `gnome`, `kde`, `lxde`, `gnome-flashback`, `cinnamon`, `mate`, `lxqt`.
Valid releases: `trixie` (default), `bookworm`, `forky`, `sid`.

Run `./tools/lint.sh` to check the scripts before contributing.

## Booting the image

1. Flash `data/shimboot_dedede.bin` to a USB drive or SD card (8 GB+) with the [Chromebook Recovery Utility](https://chrome.google.com/webstore/detail/chromebook-recovery-utili/pocpnlppkickgojjlmhdmidojbmbodfm) or `dd`.
2. Enable developer mode on your Chromebook. If it is enrolled, follow the [sh1mmer instructions](https://sh1mmer.me).
3. Plug in the drive and enter recovery mode. The reshimboot bootloader appears.
4. It auto-boots Debian after a short countdown (press any key for the menu). Log in with `user` / `user`.
5. The rootfs expands to fill the drive automatically on the first boot. Change your password with `passwd user`.

## Booting Chrome OS through reshimboot

reshimboot can also boot the Chrome OS already installed on the internal drive, which is useful on enrolled devices. From the bootloader menu, pick the `ChromeOS_ROOT-A/B` entry, choose a partition to borrow modules and firmware from, and answer the prompts.

**About the "forced update every time" bug.** When you spoof verified mode, older shimboot let Chrome OS run `update_engine` on every boot. During enrollment that triggers a forced "update required" screen even when nothing needs updating — and if the update ever completes, Chrome OS boots *normally* the next time and re-locks/re-enrolls the device, silently undoing the spoof. reshimboot neuters `update_engine` for that boot (a bind-mount over its upstart job, nothing is written to your drive), so the update screen no longer appears and the spoof sticks. Booting Chrome OS *without* reshimboot restores updates.

This is best-effort: Google actively changes verified-mode detection, so the crossystem spoof may still fail on the very newest Chrome OS versions. Blocking the update is what stops the repeating update loop and keeps the spoof from being undone.

## Feature support on dedede

| Feature | Status | Notes |
|---|---|---|
| Display (X11 / Wayland) | ✅ | |
| 3D acceleration | ✅ | Intel Jasper Lake (Gen 11) |
| Wi-Fi | ✅ | See the WPA3 note in the FAQ |
| Bluetooth | ✅ | |
| Internal audio | ✅ | SOF + community firmware + UCM configs |
| Backlight / brightness | ✅ | |
| Touchscreen / touchpad | ✅ | |
| Webcam | ✅ | |
| Hardware video decode | ✅ | via `intel-media-va-driver` |
| zram compressed swap | ✅ | lzo-rle (the 5.4 kernel has no zstd) |
| Suspend / hibernate | ❌ | disabled by the shim kernel |
| nftables | ❌ | use iptables (legacy backend, set up automatically) |

## FAQ

#### I found a bug.
Boot reshimboot, open a terminal, run `shimboot-doctor`, and include its output in your report. It captures the version, kernel, failed services, storage, Wi-Fi, audio, and graphics state in one go.

#### Some Wi-Fi networks won't connect (WPA3).
Mixed WPA2/WPA3 networks work out of the box now. For networks that *only* offer WPA3:
```bash
sudo nmcli connection modify "<network name>" wifi-sec.pmf required
```

#### Audio still doesn't work.
Run `shimboot-doctor` and check the audio section. A USB sound card or a "USB to headphone jack" adapter (which is really a USB sound card) always works as a fallback.

#### Steam / a Flatpak app says user namespaces are disabled.
The shim kernel blocks unprivileged user namespaces. reshimboot already makes `/usr/bin/bwrap` setuid at build time. If Steam still fails, run `fix_bwrap` to fix the copies of `bwrap` that Steam downloads into your home directory.

#### GPU acceleration isn't working after an OS upgrade.
dedede is new enough that the standard Mesa drivers work; you should not need the legacy `mesa-amber` packages, and installing them can remove your whole graphics stack ([#457](https://github.com/ading2210/shimboot/issues/457)). Check `shimboot-doctor`; if it reports software rendering, file a bug.

#### I want to change the desktop later.
```bash
sudo apt install task-kde-desktop *xfce*- thunar- --autoremove
```

#### I broke something and it won't boot.
Type `rescue <number>` at the bootloader menu (the number of your Debian entry) to get a root shell before init starts.

#### I see 404 errors when I run `apt update`.
That is normal. The shimboot package repo does not sign its packages or ship translations; it is harmless.

#### Can I use a different Chromebook?
Not with reshimboot — it is dedede-only on purpose. Use the [original shimboot](https://github.com/ading2210/shimboot), which supports many boards and both architectures.

## Copyright

reshimboot is licensed under the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.txt).

It is a fork of [ading2210/shimboot](https://github.com/ading2210/shimboot), Copyright (C) 2025 ading2210, and would not exist without that work. The patched systemd is by [ading2210](https://github.com/ading2210/chromeos-systemd) with the original fix by [@r58Playz](https://github.com/r58Playz). The Chromebook audio (UCM) configuration is from [WeirdTreeThing](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros) (BSD 3-Clause).

```
reshimboot: a modernized shimboot for dedede Chromebooks.
Based on ading2210/shimboot: Boot desktop Linux from a Chrome OS RMA shim.
Copyright (C) 2025 ading2210
Copyright (C) 2026 reshimboot contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```
