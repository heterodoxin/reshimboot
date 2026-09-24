# Changelog

## reshimboot r1.0.0 (unreleased)

reshimboot is a fork of [ading2210/shimboot](https://github.com/ading2210/shimboot)
that drops multi-board and multi-distro support to focus entirely on the
`dedede` board (Intel Jasper Lake, Linux 5.4 shim kernel) with a modern Debian
userland. It was developed with AI assistance; see the README.

### Bootloader

- Auto-boot countdown that starts the first Debian rootfs unless a key is pressed.
- Filesystem check before every boot with a static `e2fsck` (from Debian's
  `e2fsck-static`), run before the rootfs is mounted. Errors that preen mode
  cannot fix offer a full repair. There is also a new `f` menu option for a full
  repair of any rootfs, encrypted ones included. A wrong clock is not treated as
  corruption.
- Failed boots return to the menu instead of hanging. LUKS unlocking retries,
  and the rootfs is mounted with `noatime` (plus `discard` where supported).
- Chrome OS boot: `update_engine` is blocked with a bind mount, which stops the
  forced "update required" screen on every boot and keeps an update from
  undoing the verified-mode spoof. The donor partition is bind-mounted instead
  of copied into RAM.
- The menu shows the Chrome OS version on ROOT-A and ROOT-B and marks the one
  a normal boot uses as `(current)`. It warns before booting the older copy,
  which would make Chrome OS install the same update again.
- The invalid HWID spoof works on its own. It used to be silently ignored
  unless the verified mode spoof was chosen too. The verified mode spoof
  reports `cros_debug=0` like a real verified Chromebook, instead of 1.
- The spoofed `crossystem` was rewritten in plain bash. It is more than 10 times
  faster, parses values with spaces, quotes, `=` or `#` correctly, runs each
  `set` only once, and passes unknown keys to the real `crossystem`.

### Operating system

- Debian 13 (trixie) with KDE Plasma by default; the other desktops are still
  available. deb822 sources, with the security and updates repositories.
- Debian 14 (forky) and sid can be built (experimental). They use trixie's
  systemd 257, because systemd 258 and newer can't boot on Linux 5.4.
- The patched systemd can be compiled locally (`build_systemd.sh`) for any
  Debian release, instead of depending on the shimboot repo having a matching
  build. It is kept in the image as a local apt repo and pinned, so Debian's
  unpatched systemd can't replace it.
- PipeWire and WirePlumber, NetworkManager, systemd-resolved, systemd-timesyncd.
- Audio: the SOF firmware path the 5.4 kernel needs is taken from the shim
  (the recovery image's copy lacks it), and the Chromebook UCM configs are
  installed and re-applied after `alsa-ucm-conf` upgrades.
- Firmware from the shim and recovery image is placed in
  `/lib/firmware/updates/<kernel>`, so the old kernel prefers firmware it
  supports, without modifying files owned by dpkg. Absolute touchscreen
  firmware symlinks are resolved instead of being left dangling.
- iptables uses the legacy backend (no nf_tables in 5.4); exFAT and NTFS work
  through FUSE; zram uses lzo-rle.
- `bwrap` is setuid through `dpkg-statoverride`, so Steam and Flatpak work and
  keep working after upgrades. Flatpak and Flathub are included.
- sysctl: hung tasks and soft lockups no longer panic the kernel, and dirty
  writeback is capped so slow USB drives do not freeze the system.
- Suspend and hibernation are disabled cleanly; closing the lid locks the screen.
- Chrome OS style touchpad (tap to click, two-finger right click) on X11 and GNOME.
- Locale and timezone are set at build time. A fresh machine id is generated on
  first boot, so prebuilt images do not share one.
- `systemd-firstboot` is masked so it cannot block the first boot on a console
  that you cannot see.
- Debian kernel packages are pinned off, since they can never boot.

### New tools

- `reshimboot-welcome`: a first-login dialog with tips and a system check, which
  keeps asking to replace the default password until it is changed.
- `shimboot-doctor`: reports the state of systemd, storage, Wi-Fi, audio,
  graphics, and sandboxing. It recognises Wi-Fi cards that the 5.4 kernel has
  no driver for (the Realtek RTL8852BE in some newer dedede models), and can
  turn Wi-Fi back on or reinstall its firmware. `sudo shimboot-doctor --fix` repairs the common
  problems (unpatched systemd, zram, iptables backend, audio configs, bwrap,
  rootfs expansion).
- An apt hook that warns before you reboot into an unpatched systemd.
- `set_timezone`, and first-boot rootfs expansion.
- `reshimboot-wifi-region` sets the Wi-Fi country at boot from the
  Chromebook's VPD region (like Chrome OS does), the timezone, or
  `/etc/reshimboot/wifi-country`. Without a country, Linux uses the "world"
  regulatory domain and most 5 GHz channels are unusable.

### Build system

- Fixed images built on Debian 13, Arch, or Fedora not booting. Their newer
  `mke2fs` enables `orphan_file`, which Linux 5.4 cannot mount read-write. All
  filesystems now use a pinned `mke2fs.conf`, and every build checks the result.
- `tools/shimtool.py` replaces binwalk and pcregrep. It parses GPT, the vboot
  kernel, and the kernel ELF directly, and streams zip64 downloads with a CRC
  check (replacing `funzip`, which fails on zip64 files).
- The shim download stops once the two needed partitions are extracted, about
  130 MB instead of 4.3 GB. Images are stored sparse.
- The disk image is built without loop devices (`mkfs -d`, `sfdisk`, `debugfs`),
  except for LUKS.
- The build verifies by SHA-256 that the patched systemd was installed, and stops
  otherwise.
- Debian packages and the debootstrap base are cached between builds.
- `build_docker.sh` builds inside a container on any Linux distro or WSL.
- Options are validated before anything is downloaded. Build options can be
  passed through `build_complete.sh`, including `extra_ca` for networks that
  intercept HTTPS.
- Images get a `.sha256`, and can be compressed with zip or xz.
- CI: `shellcheck`, busybox syntax checks, and unit tests for `shimtool.py`; per-desktop
  release builds; superseded runs are cancelled, and documentation changes skip
  the image build.
- Removed ARM/arm64, Alpine, Ubuntu, Artix, and multi-board support.
