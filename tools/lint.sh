#!/bin/bash

#run shellcheck over every shell script in the repo and syntax-check the
#busybox bootloader scripts. used by CI and handy to run before committing.

set -e
cd "$(dirname "$0")/.."

shell_scripts=(
  common.sh image_utils.sh shim_utils.sh
  build.sh build_complete.sh build_rootfs.sh build_squashfs.sh patch_rootfs.sh
  tools/lint.sh
  rootfs/opt/setup_rootfs.sh
  rootfs/usr/local/bin/*
)

echo ">> shellcheck"
shellcheck -x -S warning "${shell_scripts[@]}"

echo ">> bash -n on busybox scripts"
for f in bootloader/bin/bootstrap.sh bootloader/bin/init squashfs/bin/bootstrap.sh squashfs/bin/init bootloader/opt/crossystem; do
  bash -n "$f"
done

echo ">> python syntax"
python3 -m py_compile tools/shimtool.py

echo "all checks passed"
