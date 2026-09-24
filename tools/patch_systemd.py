#!/usr/bin/env python3
"""Patch a systemd source tree so that it boots on Chrome OS kernels.

The Chrome OS kernel refuses mounts whose target is reached through a
symlink, and systemd's mount_nofollow() mounts through /proc/self/fd/<n>,
which is exactly that. PID 1 then fails with "Failed to mount API
filesystems". The fix, from ading2210/chromeos-systemd (credit to
r58playz), is to make mount_nofollow() call mount() directly.

This edits the function body instead of applying a diff, so that it keeps
working when the surrounding code changes between systemd versions.
"""

import re
import sys
from pathlib import Path

REPLACEMENT_BODY = """{
        /* reshimboot: Chrome OS kernels reject mounts through /proc/self/fd/,
         * so mount the target path directly. */
        return RET_NERRNO(mount(source, target, filesystemtype, mountflags, data));
}"""

PARAMS = ("source", "target", "filesystemtype", "mountflags", "data")


def find_function(text):
    match = re.search(r"^int mount_nofollow\(([^)]*)\)\s*\{", text, re.MULTILINE)
    if not match:
        return None
    params = match.group(1)
    for name in PARAMS:
        if not re.search(r"\b%s\b" % name, params):
            raise SystemExit("mount_nofollow() has an unexpected signature: " + params)

    #find the matching closing brace of the function body
    start = match.end() - 1
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
    raise SystemExit("could not find the end of mount_nofollow()")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_systemd.py systemd_source_dir")
    src_dir = Path(sys.argv[1])

    candidates = sorted(src_dir.glob("src/**/*.c"))
    for path in candidates:
        text = path.read_text()
        if "mount_nofollow(" not in text:
            continue
        span = find_function(text)
        if not span:
            continue
        start, end = span
        if "reshimboot:" in text[start:end]:
            print("%s is already patched" % path)
            return
        path.write_text(text[:start] + REPLACEMENT_BODY + text[end:])
        print("patched mount_nofollow() in %s" % path.relative_to(src_dir))
        return

    raise SystemExit("mount_nofollow() was not found in " + str(src_dir))


if __name__ == "__main__":
    main()
