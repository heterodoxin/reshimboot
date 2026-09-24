#!/bin/bash

#build a compressed rootfs that uses a squashfs + unionfs
#this consists of a minimal busybox system (from the shim) containing:
# - the FUSE kernel module from the shim
# - a statically compiled unionfs-fuse
# - the main rootfs, compressed into a squashfs with gzip
#writes are stored uncompressed in the writable upper layer

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

print_help() {
  echo "Usage: sudo ./build_squashfs.sh rootfs_dir uncompressed_rootfs_dir path_to_shim"
  echo "  rootfs_dir              - The output directory for the compressed rootfs."
  echo "  uncompressed_rootfs_dir - The existing Debian rootfs to compress."
  echo "  path_to_shim            - The dedede shim image."
}

assert_root
assert_deps "git make gcc mksquashfs cpio python3"
assert_args "$3"

compile_unionfs() {
  local out_path="$1"
  local working_path="$2"
  local original_dir
  original_dir="$(pwd)"

  rm -rf "$working_path"
  retry_cmd git clone "https://github.com/rpodgorny/unionfs-fuse" -b master --depth=1 "$working_path"
  cd "$working_path"
  env LDFLAGS="-static" CFLAGS="-O3" make -j"$(nproc --all)"
  cp "$working_path/src/unionfs" "$out_path"
  cd "$original_dir"
}

rootfs_dir="$(realpath -m "$1")"
old_dir="$(realpath -m "$2")"
shim_path="$(realpath -m "$3")"

root_squashfs="$rootfs_dir/root.squashfs"
unionfs_dir="$(mktemp -d)"
add_cleanup "rm -rf '$unionfs_dir'"

if ! verify_disk_image "$shim_path" "$SHIM_KERNEL_PART"; then
  print_error "$shim_path is not a valid shim image"
  exit 1
fi

print_info "compiling unionfs-fuse"
compile_unionfs "$unionfs_dir/unionfs" "$unionfs_dir"

print_info "reading the shim image"
extract_initramfs_full "$shim_path" "$rootfs_dir"
rm -rf "$rootfs_dir/init"

print_info "compressing the rootfs"
mksquashfs "$old_dir" "$root_squashfs" -noappend -comp gzip

print_info "patching the compressed rootfs"
mv "$unionfs_dir/unionfs" "$rootfs_dir/bin/unionfs"
cp -a "$base_dir/squashfs/." "$rootfs_dir/"
chmod +x "$rootfs_dir/bin/"*

print_info "done"
