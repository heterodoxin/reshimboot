# reshimboot

**Boot a full, modern Debian desktop on a `dedede` Chromebook, from a USB drive, without touching the firmware. It works on enterprise-enrolled devices too.**

reshimboot is a fork of [ading2210/shimboot](https://github.com/ading2210/shimboot) rebuilt around a single board. By dropping multi-board support, every part of it can be tuned for dedede and its 5.4 shim kernel: Debian 13 by default, PipeWire, a safer bootloader, much faster builds, and fixes for the most common problems reported upstream.

> [!NOTE]
> **This fork was developed with AI assistance** (Claude, by Anthropic). Every change was checked by building real images against the actual dedede shim and recovery image, and the bootloader logic was tested with the shim's own busybox. It has **not all been confirmed on real Chromebook hardware yet**. Features that still need that are marked below. See [About the AI-assisted development](#about-the-ai-assisted-development) for details, and please [report what works and what doesn't](https://github.com/heterodoxin/reshimboot/issues).

## Contents

- [Quick start](#quick-start)
- [Is my Chromebook supported?](#is-my-chromebook-supported)
- [What works](#what-works)
- [What's new compared to shimboot](#whats-new-compared-to-shimboot)
- [Building](#building)
- [Flashing and booting](#flashing-and-booting)
- [Using the bootloader](#using-the-bootloader)
- [Booting Chrome OS through reshimboot](#booting-chrome-os-through-reshimboot)
- [Troubleshooting and FAQ](#troubleshooting-and-faq)
- [Why not a newer kernel? (kexec)](#why-not-a-newer-kernel-kexec)
- [How it works](#how-it-works)
- [Contributing](#contributing)
- [About the AI-assisted development](#about-the-ai-assisted-development)
- [Credits and license](#credits-and-license)

## Quick start

On a Linux machine (Debian or Ubuntu, or any distro [with Docker](#building-in-a-container)):

```bash
git clone https://github.com/heterodoxin/reshimboot
cd reshimboot
sudo ./build_complete.sh
```

1. Flash `data/shimboot_dedede.bin` to a USB drive or SD card (8 GB or larger).
2. Put the Chromebook in developer mode (enrolled devices: see [sh1mmer](https://sh1mmer.me)), plug in the drive, and enter recovery mode.
3. Debian boots automatically after a 5 second countdown. Log in as `user` / `user`, and the welcome screen asks you to pick a new password.

The default image is **Debian 13 (trixie) with KDE Plasma**.

## Is my Chromebook supported?

Only if its board is **dedede**: the Intel Jasper Lake Chromebooks from 2021 and later, with a Celeron N4500, Celeron N5100, or Pentium Silver N6000. Search for your model on [cros.download](https://cros.download/recovery) to see its board name.

Every dedede model uses the same shim and the same image:

> awadoron, awasuki, beadrix, beetley, blipper, bookem, boten, boxy, bugzzy, cret, cret360, dexi, dita, drawcia, drawlat, drawman, drawper, galith, galith360, gallop, galnat, galnat360, galtic, galtic360, kracko, kracko360, landia, landrid, lantis, madoo, magister, maglet, maglia, maglith, magma, magneto, magolor, magpie, metaknight, palutena, pasara, peezer, pirette, pirika, sasuke, sasukette, storo, storo360, taranza

For any other board, use the [original shimboot](https://github.com/ading2210/shimboot).

## What works

dedede's shim runs **Linux 5.4.85**, and that can't be changed (see [kexec](#why-not-a-newer-kernel-kexec)). Most hardware works; a few things are limited by that old kernel.

| Feature | shimboot | reshimboot | Notes |
|---|---|---|---|
| Desktop (X11 / Wayland) | ✅ | ✅ | KDE Plasma by default; GNOME, XFCE and others available |
| 3D acceleration | ✅ | ✅ | Intel Gen 11 (Jasper Lake) |
| Wi-Fi: Intel AX201 / 9560, Realtek RTL8822CE | ✅ | ✅ | Better defaults for WPA2/WPA3 networks |
| Wi-Fi: Realtek RTL8852BE (some newer models) | ❌ | ❌ | No driver in the 5.4 kernel, [use USB](#wi-fi-doesnt-work) |
| Bluetooth | ✅ | ✅ | |
| Touchscreen, touchpad, webcam, backlight | ✅ | ✅ | Tap to click and two-finger right click like Chrome OS |
| Internal speakers and mic | ❌ | 🧪 | Firmware path and UCM fix included, **needs hardware confirmation** |
| Hardware video decoding | ❔ | 🧪 | `intel-media-va-driver` included, **needs hardware confirmation** |
| exFAT / NTFS drives | ❌ | ✅ | Through FUSE; the kernel has no driver for them |
| iptables / firewalls | ❌ | ✅ | Legacy backend; the kernel has no nf_tables |
| Steam and Flatpak sandboxes | ⚠️ manual fix | ✅ | `bwrap` is set up automatically |
| Chrome OS without the forced update loop | ❌ | 🧪 | Shows which Chrome OS partition is current; **needs hardware confirmation** |
| Compressed RAM swap (zram) | ✅ | ✅ | lzo-rle; the kernel has no zstd |
| Suspend / hibernate | ❌ | ❌ | Disabled in the shim kernel; lid close locks instead |
| nftables, WireGuard, overlayfs, btrfs | ❌ | ❌ | Not built into the shim kernel |

✅ works · 🧪 fix included but not yet confirmed on hardware · ⚠️ partly · ❌ doesn't work

## What's new compared to shimboot

**A safer bootloader**
- Boots Debian automatically after a countdown; press any key for the menu.
- **Checks and repairs the filesystem before every boot**, using a static `e2fsck`, so a drive that was pulled out mid-write gets fixed instead of getting worse. There is also an `f` option in the menu for a full repair.
- Falls back to the menu when something fails, instead of hanging on a black screen. LUKS password prompts allow retries.

**A better system**
- **Debian 13 (trixie) with KDE Plasma 6** by default. Debian 14 (forky) can be built as an experiment: the patched systemd that shimboot needs is compiled during the build (`build_systemd.sh`), so reshimboot isn't limited to the releases the shimboot repository covers.
- PipeWire, NetworkManager, systemd-resolved and timesyncd.
- A **welcome app** on first login that makes you replace the default password, because every prebuilt image shares it.
- `shimboot-doctor` checks everything a bug report needs, and **`sudo shimboot-doctor --fix` repairs** the common problems automatically.
- The rootfs grows to fill the drive on first boot.
- Chromebook touchpad behaviour, keyboard layout (`croskbd`), and Flatpak with Flathub.

**Fixes for common upstream problems**
- **Images built on Debian 13, Arch or Fedora couldn't boot.** Newer `mke2fs` enables ext4 features (like `orphan_file`) that Linux 5.4 can't mount read-write. reshimboot pins a kernel-safe feature set and checks it on every build.
- **"Failed to mount API filesystems":** an unpatched systemd slipped in. The build now verifies the patched systemd by SHA-256 and stops if it's wrong, and an apt hook warns you before you reboot into a broken system. ([#432](https://github.com/ading2210/shimboot/issues/432), [#508](https://github.com/ading2210/shimboot/issues/508))
- **No sound:** the 5.4 kernel needs to be told where the SOF firmware is, and that setting was taken from the wrong image. The Chromebook UCM configs are also installed, and survive upgrades. ([#518](https://github.com/ading2210/shimboot/issues/518))
- **Random reboots to the recovery screen:** hung tasks and soft lockups no longer panic the kernel, dirty-page writeback to slow USB drives is capped, and suspend (which the kernel can't do) is disabled cleanly. ([#461](https://github.com/ading2210/shimboot/issues/461), [#423](https://github.com/ading2210/shimboot/issues/423))
- **Chrome OS forcing an update on every boot** with the verified-mode spoof. See [below](#booting-chrome-os-through-reshimboot). ([#359](https://github.com/ading2210/shimboot/issues/359))
- **The spoofed `crossystem` returned wrong or empty values**, for example for keys containing `=`, `#` or quotes, and ran `set` commands several times. It was rewritten and is more than 10 times faster, which matters because Chrome calls it often during startup.
- iptables ([#414](https://github.com/ading2210/shimboot/issues/414)), exFAT ([#512](https://github.com/ading2210/shimboot/issues/512)), Wi-Fi ([#487](https://github.com/ading2210/shimboot/issues/487), [#506](https://github.com/ading2210/shimboot/issues/506)), locales ([#475](https://github.com/ading2210/shimboot/issues/475)), and Steam ([#306](https://github.com/ading2210/shimboot/issues/306)).

**A much better build**
- **No more binwalk.** `tools/shimtool.py` reads the shim kernel's actual structure, so the build no longer breaks with binwalk 3.x. ([#353](https://github.com/ading2210/shimboot/issues/353), [#526](https://github.com/ading2210/shimboot/issues/526))
- **About 97% less to download for the shim.** Only the two partitions that are needed are extracted while downloading, and the download stops there: about 130 MB instead of 4.3 GB. The recovery image is CRC-checked.
- **Faster rebuilds.** Debian packages are cached between builds. In a minimal test build, the second run downloaded 30 packages instead of 265.
- **Build anywhere.** No loop devices are needed (except for LUKS), and there's a [container build](#building-in-a-container) for Arch, Fedora and WSL.
- Unit tests, `shellcheck`, and per-desktop release builds in CI.

Removed: support for other boards, ARM, and the Alpine and Ubuntu rootfs options.

## Building

You need about 20 GB of free space and root access. `build_complete.sh` installs its own dependencies on Debian and Ubuntu.

```bash
sudo ./build_complete.sh [option=value ...]
```

| Option | Default | Description |
|---|---|---|
| `desktop` | `kde` | `kde`, `gnome`, `xfce`, `lxqt`, `mate`, `cinnamon`, `lxde`, `gnome-flashback`, or `none` |
| `release` | `trixie` | `trixie` (Debian 13), `forky` (14, experimental), `bookworm` (12) or `sid` (see [below](#which-debian-release-should-i-use)) |
| `systemd` | `auto` | Where the patched systemd comes from: `build` (compile it), `shimboot` (the prebuilt shimboot repo, trixie and bookworm only), or `auto` |
| `username` / `user_passwd` | `user` / `user` | If you set a password, the first-login password prompt is skipped |
| `hostname` | `reshimboot` | |
| `timezone` | the build machine's | For example `America/New_York` |
| `locale` | `en_US.UTF-8` | |
| `luks` | off | `luks=1` encrypts the rootfs; you'll be asked for a password |
| `autoboot` | `5` | Seconds before Debian boots automatically, `0` to always show the menu |
| `compress_img` | off | `1` for a `.zip` (Chromebook Recovery Utility), `xz` for a smaller `.xz` |
| `flatpak` / `i386` / `auto_expand` | on | Set to `0` to leave out Flatpak, 32-bit packages (Steam, Wine), or first-boot expansion |
| `cache` | on | `0` to not keep Debian packages in `data/cache` between builds |
| `shim_path` / `reco_path` | download | Use a `.bin` or `.zip` you already have |
| `extra_ca` | none | A CA certificate to trust during the build, for networks that intercept HTTPS |
| `quiet` | off | No progress bars, for CI logs |

For example:

```bash
sudo ./build_complete.sh release=trixie desktop=xfce compress_img=xz timezone=Europe/Berlin
```

The finished image is `data/shimboot_dedede.bin`, with a `.sha256` checksum next to it.

### Building in a container

If you're not on Debian or Ubuntu (Arch, Fedora, WSL…), build inside a container instead. It takes the same options:

```bash
sudo ./build_docker.sh desktop=gnome
```

This uses Docker or Podman (rootful), and the image still ends up in `data/`.

<details>
<summary>Running the steps by hand</summary>

1. For forky only: `sudo ./build_systemd.sh data/systemd forky source_release=trixie` compiles the patched systemd.
1. `sudo ./build_rootfs.sh data/rootfs trixie` builds the Debian rootfs (for forky, add `systemd_repo=data/systemd/forky`).
2. `sudo ./patch_rootfs.sh shim.bin reco.bin data/rootfs` adds the dedede kernel modules, firmware, and audio configs.
3. `sudo ./build.sh image.bin shim.bin data/rootfs` writes the disk image.

Each script prints its options with `--help`. `build_squashfs.sh` can make a compressed rootfs as well.
</details>

## Flashing and booting

1. Flash the image to a USB drive or SD card:
   - the [Chromebook Recovery Utility](https://chrome.google.com/webstore/detail/chromebook-recovery-utili/pocpnlppkickgojjlmhdmidojbmbodfm) (use the `.bin` or `.zip`), or
   - [balenaEtcher](https://etcher.balena.io/) or Rufus (these also take `.xz`), or
   - `sudo dd if=shimboot_dedede.bin of=/dev/sdX bs=4M oflag=direct status=progress`
2. Enable developer mode. If your Chromebook is enrolled, follow the [sh1mmer instructions](https://sh1mmer.me).
3. Plug in the drive and enter recovery mode (Esc + Refresh + Power).
4. Debian boots after the countdown. Log in and follow the welcome screen.

Use a decent USB 3 drive or SD card. Cheap USB 2 drives work, but slowly.

## Using the bootloader

```
┌───────────────────────────┐
│ reshimboot OS Selector    │
└───────────────────────────┘
r1.0.0 - kernel 5.4.85-22138-ga9994f5cad40

1) ChromeOS_ROOT-A_R151_16715.62.0_(older) on /dev/mmcblk1p3
2) ChromeOS_ROOT-B_R152_16765.49.0_(current) on /dev/mmcblk1p5
3) debian on /dev/sda4
q) reboot
s) enter a shell
f) check and repair a filesystem
l) view license
type 'rescue <number>' to boot into a rescue shell

booting debian in 5 seconds, press any key for the menu...
```

- **Number:** boot that system.
- **`rescue <number>`:** get a root shell inside that system instead of starting it. Run `exec /sbin/init` to continue booting.
- **`f`:** run a full filesystem repair (`e2fsck -fy`) on a Debian partition, including encrypted ones.
- **`s`:** a busybox shell in the bootloader itself.

## Booting Chrome OS through reshimboot

Pick a `ChromeOS_ROOT` entry to boot the Chrome OS that's on the internal drive. It borrows the kernel modules from your Debian partition, and asks whether to spoof verified mode and an invalid HWID. That's useful on enrolled devices.

**Pick the `(current)` partition.** Chrome OS keeps two copies of itself (ROOT-A and ROOT-B) and installs each update into the one it isn't using. The menu now shows each copy's version, and marks the one that a normal boot would use as `(current)`. Booting the `(older)` copy through shimboot makes Chrome OS download and install the same update again every time, which was a common cause of the "forced update on every boot" reports. reshimboot warns you before booting the older copy.

**No more forced update loop.** With the spoof on, Chrome OS still ran `update_engine` on every boot. That put a forced "update required" screen in front of the setup screens even when nothing needed updating. Worse, if an update ever finished, Chrome OS booted *normally* afterwards and locked the device again, which undid the spoof. reshimboot now stops `update_engine` for that boot by bind-mounting over its upstart job. Nothing is written to your internal drive, and booting Chrome OS without reshimboot brings updates back. This can't help if your school sets a minimum Chrome OS version that the `(current)` copy is older than; then the update-required screen comes from policy, and the only fix is to update Chrome OS normally.

**Known limits on recent Chrome OS versions**, found by examining the current dedede recovery image (R152):
- Early startup (`chromeos_startup`) now reads the firmware state through `libcrossystem` directly, not the `crossystem` command. It sees the real recovery-mode boot, whatever the spoof says. The spoof still covers Chrome and the scripts that run `crossystem`.
- `chromeos_startup` now sets up the encrypted stateful partition itself, without running `mount-encrypted`. So the `--unsafe` persistence workaround from shimboot no longer takes effect, and Chrome OS data may not survive between shimboot sessions.

Google keeps changing how verified mode is detected, so the spoof itself may still fail on the newest Chrome OS versions.

## Troubleshooting and FAQ

#### Something isn't working
Open a terminal and run `shimboot-doctor`. It checks systemd, storage, Wi-Fi, audio, graphics and more, then tells you what it can fix. Run `sudo shimboot-doctor --fix` to fix it, and include the output in bug reports.

#### It won't boot any more
At the bootloader menu, try `f` to repair the filesystem. If that doesn't help, type `rescue <number>` to get a shell and look at `journalctl -b -1`. If you see "Failed to mount API filesystems", run `sudo shimboot-doctor --fix` from the rescue shell to reinstall the patched systemd.

#### Wi-Fi doesn't work
Run `shimboot-doctor` and look at the Wi-Fi section.
- If it says your card **has no driver in the shim kernel**, your model has a Realtek RTL8852BE, which Linux 5.4 doesn't support. Since the kernel can't be replaced (see [kexec](#why-not-a-newer-kernel-kexec)), use a USB Wi-Fi adapter, a USB Ethernet adapter, or USB tethering from a phone. Adapters that work with Linux out of the box (for example ones with Realtek RTL8188/RTL8192/RTL8812 chips) are the safest choice.
- If Wi-Fi is switched off or the firmware failed to load, `sudo shimboot-doctor --fix` turns it back on or reinstalls the firmware.
- Intel AX201 and 9560 cards (most dedede models) and the Realtek RTL8822CE are supported. Please open an issue with the `shimboot-doctor` output if one of these doesn't work.

#### Some Wi-Fi networks won't connect
Mixed WPA2/WPA3 networks work out of the box. For a network that *only* allows WPA3, run:
```bash
sudo nmcli connection modify "<network name>" wifi-sec.pmf required
```

#### There's no sound
Run `shimboot-doctor` and look at the audio section. Internal audio is the least-tested fix here, so please report what you see. A USB sound card, or a USB-to-headphone adapter (which is a sound card), always works.

#### Steam or a Flatpak app says user namespaces are disabled
`/usr/bin/bwrap` is already fixed. For the copies Steam downloads into your home directory, run `fix_bwrap`.

#### How do I mount a USB stick or SD card?
It mounts automatically in the file manager, including exFAT and NTFS.

#### Which Debian release should I use?
**trixie (Debian 13)**, the default. It's the stable release and uses shimboot's prebuilt, patched systemd.

**forky (Debian 14)** is experimental. systemd 258 and newer need Linux 5.10 or later: forky's own systemd (261) was booted in QEMU on a stock 5.4 kernel and failed with "Failed to mount early API filesystems". So forky builds use trixie's systemd (257), compiled for forky and patched. Only a few forky packages need a newer systemd, but one of them is GNOME's login screen, so the build refuses GNOME on forky. This combination hasn't been boot-tested yet. **sid** has the same limits, and it changes every day.

With a locally built systemd, the image keeps a copy in `/var/lib/reshimboot/systemd-repo`, and apt is pinned so Debian's unpatched systemd can't replace it.

#### How do I upgrade to a newer Debian release?
Replace the release name in `/etc/apt/sources.list.d/debian.sources`, then run `sudo apt update && sudo apt full-upgrade`. The apt hook warns you if the upgrade tries to replace the patched systemd; don't reboot if it does. Upgrading from trixie to forky isn't possible this way, because the shimboot repo doesn't have a forky systemd. Build a new forky image instead.

#### Why is there no suspend?
The shim kernel has suspend disabled, and trying to suspend could crash the Chromebook. reshimboot turns it off everywhere, and closing the lid locks the screen instead.

#### I see 404 errors from `apt update`
That's normal. The shimboot repository doesn't publish signatures or translations.

## Why not a newer kernel? (kexec)

A newer kernel would fix most of the limitations above, so this was investigated. **It isn't possible on dedede:**

- The only way to run another kernel without firmware changes is `kexec`. The dedede shim kernel is **built without kexec** (`CONFIG_KEXEC_CORE` is off). Its image has none of kexec's own code: no `kexec_load_disabled` sysctl, no "Starting new kernel" message, no crash-kernel reservation. So `kexec_load` and `kexec_file_load` don't exist on it.
- The kernel can't be replaced or patched either. The firmware only boots the shim kernel because it's signed by Google. The unsigned part that shimboot relies on is the root filesystem, not the kernel.
- There's only one dedede shim, so there's no other kernel to pick.

So reshimboot works around the 5.4 kernel instead (FUSE for exFAT and NTFS, legacy iptables, lzo-rle zram, and a pinned ext4 feature set). Booting a different kernel needs firmware write protection disabled, and at that point you don't need shimboot at all.

## How it works

Chrome OS RMA shims are signed recovery images that even enrolled Chromebooks will boot. Their kernel is verified, but [their root filesystem isn't](https://sh1mmer.me/). reshimboot keeps the signed shim kernel and replaces the root filesystem with a bootloader:

```
firmware ─► shim kernel (signed, Linux 5.4, KERN-A)
              └─► /sbin/init on the bootloader partition (ROOT-A)
                    └─► bootstrap.sh: menu, fsck, LUKS unlock
                          └─► pivot_root into the Debian partition ─► patched systemd
```

| Partition | Size | Contents |
|---|---|---|
| 1 | 1 MB | Stateful partition that the shim expects |
| 2 | 32 MB | The shim's signed kernel |
| 3 | 20 MB | Bootloader: the shim's initramfs, `bootstrap.sh`, static `e2fsck` (and `cryptsetup` with LUKS) |
| 4 | the rest | Debian, labelled `shimboot_rootfs:debian` |

A few details:
- **systemd:** the Chrome OS kernel rejects a normal systemd's early mounts, so a [patched systemd](https://github.com/ading2210/chromeos-systemd) from the shimboot apt repo is installed and pinned.
- **Kernel modules** come from the shim.
- **Firmware** from the shim and the recovery image goes into `/lib/firmware/updates/<kernel>`. The kernel checks that directory first, so it prefers firmware that matches it over Debian's newer files, without modifying anything dpkg owns.
- **ext4 features** are pinned by [`mke2fs.conf`](mke2fs.conf) to what Linux 5.4 can mount read-write.

## Contributing

Bug reports with `shimboot-doctor` output are the most useful thing, especially for the 🧪 features.

Before sending changes, run:

```bash
./tools/lint.sh   # shellcheck, busybox syntax checks, and the shimtool unit tests
```

| Path | What it is |
|---|---|
| `build_complete.sh` | Downloads everything and runs the other steps |
| `build_rootfs.sh`, `rootfs/opt/setup_rootfs.sh` | Build and configure Debian (the second one runs inside the chroot) |
| `patch_rootfs.sh` | Adds dedede's kernel modules, firmware, and audio configs |
| `build.sh`, `image_utils.sh` | Write the final disk image |
| `bootloader/` | The boot menu that runs from the shim |
| `rootfs/` | Files copied into Debian: configs, `shimboot-doctor`, the welcome app… |
| `tools/shimtool.py` | Reads GPT disks, Chrome OS kernels, and zip64 downloads (Python standard library only) |
| `tests/` | Unit tests for `shimtool.py` using synthetic images |

## About the AI-assisted development

This fork was developed with the help of an AI coding assistant (Claude, by Anthropic), directed and reviewed by the maintainer. Here's how the work was checked:

- **Research:** upstream's issues, pull requests and unreleased `dev` branch were reviewed, and the real dedede shim and recovery image were analysed. Findings such as the 5.4 kernel, the missing SOF firmware setting, the wrong WiFi firmware and the ext4 incompatibility came from those images, not from guesses.
- **Testing:**
  - complete builds were run from download to finished image, on Ubuntu and inside a Debian 13 container;
  - the bootloader's menu, countdown and filesystem repair were run under the shim's own busybox, against deliberately corrupted filesystems;
  - `shimtool.py` has unit tests;
  - every script passes `shellcheck`.
- **Not yet tested:** booting on real dedede hardware. The 🧪 items in [What works](#what-works) are the ones that most need confirmation.

If something looks wrong, please open an issue. Hardware reports decide which of these fixes stay.

## Credits and license

reshimboot is licensed under the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.txt).

- [ading2210/shimboot](https://github.com/ading2210/shimboot), the project this is forked from. Copyright (C) 2025 ading2210.
- The [patched systemd](https://github.com/ading2210/chromeos-systemd) by ading2210, with the original fix by [@r58Playz](https://github.com/r58Playz).
- The Chromebook audio (UCM) configs from [WeirdTreeThing/alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros) (BSD 3-Clause).
- Upstream contributors whose work is included: [@a1g0r1thm9](https://github.com/a1g0r1thm9) (LUKS2), WifiRouterYT (bind-mounted Chrome OS modules, upstream PR #480), and hainesnoids (`set_timezone`, upstream PR #504).

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
