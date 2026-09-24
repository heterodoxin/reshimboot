---
name: Bug report
about: Create a report to help us improve
title: ''
labels: bug
assignees: ''

---

<!--
reshimboot only supports the dedede board. If you have a different Chromebook,
please use the original project at https://github.com/ading2210/shimboot instead.

Before making a bug report please check that:
- Your device is actually a dedede board (check the board name at cros.download)
- The USB drive / SD card you are using isn't faulty
  - Dirt cheap USB 2.0 drives or fake high capacity ones will not work
- The disk image you are using is not corrupted
- You have run `shimboot-doctor` and included its output below
-->

**Describe the bug**
A clear and concise description of what the bug is.

**`shimboot-doctor` output**
<!-- Boot into reshimboot, open a terminal, and run `shimboot-doctor`. Paste the full output here. This is the single most useful thing you can include. -->
```
paste here
```

**To Reproduce**
Steps to reproduce the behavior:
1. ...

**Expected behavior**
A clear and concise description of what you expected to happen.

**Screenshots / Photos**
If applicable, add screenshots or photos to help explain your problem.

If you are reporting an issue with the build process, please run the scripts in debug mode by putting `DEBUG=1` before the build command, like `sudo DEBUG=1 ./build_complete.sh`.

**Device information:**
 - Device Name (e.g. drawcia): <!-- the exact dedede model -->
 - reshimboot version (run `cat /bootloader/opt/.shimboot_version`):
 - Debian release (e.g. trixie):
 - Desktop environment (e.g. xfce):
 - Prebuilt image or self-built:

**Build device (only if you built the image yourself):**
 - OS: [e.g. Debian 13]

**Additional context**
Add any other context about the problem here.
