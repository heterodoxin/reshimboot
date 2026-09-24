#!/bin/bash

#run shellcheck over every shell script in the repo and syntax-check the
#busybox bootloader scripts. used by CI and handy to run before committing.

set -e
cd "$(dirname "$0")/.."

shell_scripts=(
  common.sh image_utils.sh shim_utils.sh
  build.sh build_complete.sh build_rootfs.sh build_squashfs.sh patch_rootfs.sh build_docker.sh
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
python3 -m py_compile tools/shimtool.py tools/patch_systemd.py tests/test_shimtool.py tests/test_patch_systemd.py

echo ">> shimtool unit tests"
if ! test_output="$(python3 -m unittest discover -s tests 2>&1)"; then
  echo "$test_output"
  exit 1
fi
echo "$test_output" | tail -n 3

echo "all checks passed"
