#!/bin/bash

#utilities for reading chrome os shim and recovery images
#none of these need loop devices, binwalk, or pcregrep

#the chrome os kernel for the shim always lives on KERN-A, and the rootfs on ROOT-A
SHIM_KERNEL_PART=2
SHIM_ROOTFS_PART=3

#copy the shim's kernel partition to a file
copy_kernel() {
  local shim_path="$1"
  local kernel_out="$2"
  shimtool extract "$shim_path" "$SHIM_KERNEL_PART:$kernel_out"
}

#extract the initramfs that is embedded in a chrome os kernel partition
extract_initramfs() {
  local kernel_bin="$1"
  local output_dir="$2"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  shimtool initramfs "$kernel_bin" | cpio -D "$output_dir" -imd --quiet --no-absolute-filenames
  if [ ! -e "$output_dir/init" ]; then
    print_error "the extracted initramfs does not contain an init script, the shim may be corrupted"
    return 1
  fi
}

#copy the kernel image and then extract the initramfs from it
extract_initramfs_full() {
  local shim_path="$1"
  local rootfs_dir="$2"
  local kernel_bin="$3"
  local kernel_dir
  kernel_dir="$(mktemp -d)"

  print_info "copying the shim kernel"
  copy_kernel "$shim_path" "$kernel_dir/kernel.bin"

  print_info "extracting initramfs from the kernel"
  print_info "shim kernel version: $(shimtool kernel-version "$kernel_dir/kernel.bin")"
  extract_initramfs "$kernel_dir/kernel.bin" "$rootfs_dir"

  if [ "$kernel_bin" ]; then
    cp "$kernel_dir/kernel.bin" "$kernel_bin"
  fi
  rm -rf "$kernel_dir"
}

#byte offset of a partition inside a disk image
part_offset() {
  shimtool gpt "$1" --part "$2" --field offset
}

#recursively copy a directory out of an ext2/3/4 partition inside a disk image
#this uses debugfs so no loop device or mount is needed
copy_from_image() {
  local image="$1"
  local part_num="$2"
  local source="$3"
  local dest="$4"

  local offset
  offset="$(part_offset "$image" "$part_num")"
  mkdir -p "$dest"
  #debugfs does not fail on missing paths, so check first
  if ! debugfs -R "stat $source" "$image?offset=$offset" 2>/dev/null | grep -q "Type: directory"; then
    print_warning "$source does not exist in partition $part_num of $(basename "$image")"
    return 0
  fi
  debugfs -R "rdump $source $dest" "$image?offset=$offset" 2>/dev/null
}

#make sure a file is a chrome os disk image that is not truncated
verify_disk_image() {
  local image="$1"
  local expected_parts="$2"
  if ! shimtool gpt "$image" > /dev/null 2>&1; then
    return 1
  fi
  local part_num end
  for part_num in $expected_parts; do
    end="$(( $(part_offset "$image" "$part_num") + $(shimtool gpt "$image" --part "$part_num" --field size) ))"
    if [ "$(stat -c %s "$image")" -lt "$end" ]; then
      return 1
    fi
  done
}
