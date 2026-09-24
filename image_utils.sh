#!/bin/bash

#utilities for creating the final shimboot disk image
#the partitions are built as separate files with "mkfs -d" and then copied
#into the disk image, so no loop devices are needed unless luks is enabled

STATEFUL_SIZE_MB=1
KERNEL_SIZE_MB=32
#gpt headers and alignment padding at the start and end of the disk
DISK_OVERHEAD_MB=2

TYPE_LINUX_DATA="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
TYPE_CROS_KERNEL="FE3A2A5D-4F32-41A7-B725-ACCC3285A309"
TYPE_CROS_ROOTFS="3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC"

#set required flags on the kernel partition
make_bootable() {
  cgpt add -i 2 -S 1 -T 5 -P 10 -l kernel "$1"
}

#write a gpt partition table to an image file
#the bootloader partition is deliberately left unnamed, otherwise the
#bootloader would mistake it for a chrome os install (it searches for ROOT-A)
partition_disk() {
  local image_path="$1"
  local bootloader_size="$2"
  local rootfs_name="$3"

  sfdisk --quiet --wipe always "$image_path" << EOF
label: gpt
unit: sectors

size=${STATEFUL_SIZE_MB}MiB, type=$TYPE_LINUX_DATA
size=${KERNEL_SIZE_MB}MiB, type=$TYPE_CROS_KERNEL
size=${bootloader_size}MiB, type=$TYPE_CROS_ROOTFS
type=$TYPE_LINUX_DATA, name="shimboot_rootfs:${rootfs_name}"
EOF
}

#copy a partition image into a disk image at the right offset
write_partition() {
  local image_path="$1"
  local part_num="$2"
  local part_image="$3"

  local offset part_size
  offset="$(part_offset "$image_path" "$part_num")"
  part_size="$(shimtool gpt "$image_path" --part "$part_num" --field size)"
  if [ "$(stat -c %s "$part_image")" -gt "$part_size" ]; then
    print_error "$(basename "$part_image") does not fit in partition $part_num"
    return 1
  fi
  dd if="$part_image" of="$image_path" bs=4M seek="$offset" oflag=seek_bytes conv=notrunc,sparse status=none
}

#disk usage of a directory in MiB
dir_size_mb() {
  du -sm "$1" | cut -f1
}

#build an ext filesystem image populated from a directory
#if the filesystem runs out of space, retry with a bigger size
make_fs_image() {
  local fs_type="$1"
  local source_dir="$2"
  local out_image="$3"
  local size_mb="$4"
  shift 4
  local extra_opts=("$@")

  local attempt
  for attempt in 1 2 3 4; do
    rm -f "$out_image"
    truncate -s "${size_mb}M" "$out_image"
    if "mkfs.$fs_type" -q -F -d "$source_dir" "${extra_opts[@]}" "$out_image"; then
      echo "$size_mb"
      return 0
    fi
    size_mb="$(( size_mb * 5 / 4 + 64 ))"
    print_warning "filesystem was too small, retrying with ${size_mb}MiB"
  done
  print_error "failed to create the $fs_type filesystem for $source_dir"
  return 1
}

#write the stateful partition that the factory shim expects to exist
create_stateful_image() {
  local out_image="$1"
  local stateful_dir
  stateful_dir="$(mktemp -d)"
  mkdir -p "$stateful_dir/dev_image/etc/" "$stateful_dir/dev_image/factory/sh"
  touch "$stateful_dir/dev_image/etc/lsb-factory"
  make_fs_image ext4 "$stateful_dir" "$out_image" "$STATEFUL_SIZE_MB" > /dev/null
  rm -rf "$stateful_dir"
}

#add the shimboot bootloader files to an extracted initramfs
patch_initramfs() {
  local initramfs_path="$1"

  rm -f "$initramfs_path/init"
  cp -r "$base_dir/bootloader/"* "$initramfs_path/"
  find "$initramfs_path/bin" -type f -exec chmod +x {} \;

  #mark it as a dev version if we are not on a tagged release
  if git -C "$base_dir" rev-parse HEAD > /dev/null 2>&1; then
    if [ ! "$(git -C "$base_dir" tag -l --contains HEAD)" ]; then
      git -C "$base_dir" rev-parse --short HEAD | tr -d '\n' > "$initramfs_path/opt/.shimboot_version_dev"
    fi
  fi
}

#clean up unused loop devices
clean_loops() {
  local loop_devices
  loop_devices="$(losetup -a | awk -F':' '{print $1}')"
  for loop_device in $loop_devices; do
    if ! grep -q "$loop_device" /proc/mounts; then
      losetup -d "$loop_device" 2>/dev/null || true
    fi
  done
}

#create a loop device for a single partition of a disk image
#this uses an offset instead of partition scanning, which does not work in
#many containers and on wsl
create_part_loop() {
  local image_path="$1"
  local part_num="$2"
  local offset size
  offset="$(part_offset "$image_path" "$part_num")"
  size="$(shimtool gpt "$image_path" --part "$part_num" --field size)"
  losetup --find --show --offset "$offset" --sizelimit "$size" "$image_path"
}

copy_progress() {
  local source="$1"
  local destination="$2"
  local total_bytes
  total_bytes="$(du -sb "$source" | cut -f1)"
  mkdir -p "$destination"
  tar -cf - -C "${source}" . | pv -f -s "$total_bytes" | tar -xf - -C "${destination}"
}
