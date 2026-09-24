# Build environment for reshimboot. It only contains the tools; the repo is
# mounted into the container, so downloads and the finished image end up in
# ./data on the host. Use ./build_docker.sh instead of running this directly.

FROM debian:trixie-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget python3 zip unzip git debootstrap \
    debian-archive-keyring cpio cgpt kmod pv fdisk e2fsprogs cryptsetup \
    mount util-linux xz-utils zstd lz4 \
  && rm -rf /var/lib/apt/lists/* \
  && git config --system --add safe.directory '*'

WORKDIR /reshimboot
ENTRYPOINT ["./build_complete.sh"]
