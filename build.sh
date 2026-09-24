#!/bin/bash

#build the final shimboot disk image for dedede

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

print_help() {
  echo "Usage: ./build.sh output_path shim_path rootfs_dir"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  quiet           - Don't use progress indicators which may clog up log files."
  echo "  name            - The name for the shimboot rootfs partition. Defaults to 'debian'."
  echo "  luks            - Set this to 1 to encrypt the rootfs partition with LUKS2."
  echo "  luks_password   - The LUKS2 password. You will be prompted for it if this is not set."
  echo "  autoboot        - Seconds the bootloader waits before booting the rootfs. 0 disables it. Defaults to 5."
  echo "  free_space      - Extra free space in MiB to leave on the rootfs partition. Defaults to 20% of the rootfs size."
}

assert_root
assert_deps "cpio realpath cgpt mkfs.ext4 mkfs.ext2 sfdisk debugfs python3 git"
assert_args "$3"
parse_args "$@"

output_path="$(realpath -m "$1")"
shim_path="$(realpath -m "$2")"
rootfs_dir="$(realpath -m "$3")"

quiet="${args['quiet']}"
rootfs_name="${args['name']:-debian}"
luks_enabled="${args['luks']}"
crypt_password="${args['luks_password']}"
autoboot="${args['autoboot']:-5}"
free_space="${args['free_space']}"

if [ "${args['arch']}" ] && [ "${args['arch']}" != "$SHIMBOOT_ARCH" ]; then
  print_error "reshimboot only supports dedede, which is an $SHIMBOOT_ARCH board."
  exit 1
fi
if [[ ! "$autoboot" =~ ^[0-9]+$ ]]; then
  print_error "autoboot must be a number of seconds"
  exit 1
fi
if [ ! -d "$rootfs_dir" ]; then
  print_error "the rootfs directory $rootfs_dir does not exist"
  exit 1
fi
if ! verify_disk_image "$shim_path" "$SHIM_KERNEL_PART"; then
  print_error "$shim_path is not a valid shim image, or it is truncated"
  exit 1
fi

if is_true "$luks_enabled"; then
  assert_deps "cryptsetup losetup"
  if [ ! "$crypt_password" ]; then
    while true; do
      read -rsp "Enter the LUKS2 password for the image: " crypt_password; echo
      read -rsp "Retype the password: " crypt_password_confirm; echo
      if [ ! "$crypt_password" ]; then
        echo "The password cannot be empty."
      elif [ "$crypt_password" = "$crypt_password_confirm" ]; then
        break
      else
        echo "Passwords do not match. Please try again."
      fi
    done
  fi
  if [ ! -x "$base_dir/bootloader/bin/cryptsetup" ]; then
    print_info "downloading a static cryptsetup binary for the bootloader"
    binaries_tar="$(mktemp)"
    add_cleanup "rm -f '$binaries_tar'"
    retry_cmd wget -q --show-progress "https://github.com/ading2210/shimboot-binaries/releases/latest/download/shimboot_binaries_$SHIMBOOT_ARCH.tar.gz" -O "$binaries_tar"
    tar -xf "$binaries_tar" -C "$base_dir/bootloader/bin/" "cryptsetup"
    chmod +x "$base_dir/bootloader/bin/cryptsetup"
  fi
fi

work_dir="$(mktemp -d /tmp/reshimboot_build.XXXXXX)"
add_cleanup "rm -rf '$work_dir'"
initramfs_dir="$work_dir/initramfs"
kernel_img="$work_dir/kernel.bin"

print_info "reading the shim image"
extract_initramfs_full "$shim_path" "$initramfs_dir" "$kernel_img"

print_info "patching initramfs"
patch_initramfs "$initramfs_dir"
echo "AUTOBOOT_TIMEOUT=$autoboot" > "$initramfs_dir/opt/shimboot.conf"

#a static e2fsck lets the bootloader check the rootfs before mounting it
e2fsck_static=""
for candidate in "$rootfs_dir/usr/sbin/e2fsck.static" "$rootfs_dir/sbin/e2fsck.static"; do
  if [ -f "$candidate" ]; then
    e2fsck_static="$candidate"
    break
  fi
done
if [ "$e2fsck_static" ]; then
  cp "$e2fsck_static" "$initramfs_dir/bin/e2fsck.static"
  chmod +x "$initramfs_dir/bin/e2fsck.static"
else
  print_warning "e2fsck.static is not in the rootfs, so the bootloader will not check the filesystem before booting"
fi

print_info "creating the bootloader partition"
bootloader_img="$work_dir/bootloader.img"
bootloader_size="$(( $(dir_size_mb "$initramfs_dir") * 5 / 4 + 4 ))"
if [ "$bootloader_size" -lt 20 ]; then
  bootloader_size=20
fi
bootloader_size="$(make_fs_image ext2 "$initramfs_dir" "$bootloader_img" "$bootloader_size")"

print_info "creating the stateful partition"
stateful_img="$work_dir/stateful.img"
create_stateful_image "$stateful_img"

rootfs_used="$(dir_size_mb "$rootfs_dir")"
if [ ! "$free_space" ]; then
  free_space="$(( rootfs_used / 5 ))"
fi
#the journal, inode tables, and luks header take some space as well
rootfs_part_size="$(( rootfs_used * 11 / 10 + free_space + 128 ))"

#stop lazy init from hammering the usb drive on the first boot
# shellcheck disable=SC2054  # the comma is part of a single mke2fs -E argument
ext4_opts=(-E lazy_itable_init=0,lazy_journal_init=0 -L shimboot_rootfs)

rootfs_img=""
if ! is_true "$luks_enabled"; then
  print_info "creating the rootfs partition (${rootfs_used}MiB of data)"
  rootfs_img="$work_dir/rootfs.img"
  rootfs_part_size="$(make_fs_image ext4 "$rootfs_dir" "$rootfs_img" "$rootfs_part_size" "${ext4_opts[@]}")"
  check_fs_features "$rootfs_img"
fi
check_fs_features "$bootloader_img"

print_info "creating the disk image"
total_size="$(( DISK_OVERHEAD_MB + STATEFUL_SIZE_MB + KERNEL_SIZE_MB + bootloader_size + rootfs_part_size ))"
rm -f "$output_path"
truncate -s "${total_size}M" "$output_path"
partition_disk "$output_path" "$bootloader_size" "$rootfs_name"
make_bootable "$output_path"

print_info "copying data into the image"
write_partition "$output_path" 1 "$stateful_img"
write_partition "$output_path" 2 "$kernel_img"
write_partition "$output_path" 3 "$bootloader_img"

if is_true "$luks_enabled"; then
  print_info "encrypting the rootfs partition"
  rootfs_loop="$(create_part_loop "$output_path" 4)"
  add_cleanup "losetup -d '$rootfs_loop'"
  mapper_name="reshimboot_build_$$"
  #argon2id with a fixed memory cost, so that unlocking stays quick on a 4GB chromebook
  printf '%s\n' "$crypt_password" | cryptsetup luksFormat --batch-mode --type luks2 \
    --pbkdf argon2id --pbkdf-memory 262144 --pbkdf-parallel 2 --iter-time 1000 "$rootfs_loop"
  printf '%s\n' "$crypt_password" | cryptsetup open "$rootfs_loop" "$mapper_name"
  add_cleanup "cryptsetup close '$mapper_name'"

  print_info "copying the rootfs (${rootfs_used}MiB of data)"
  mkfs.ext4 -q -F -d "$rootfs_dir" "${ext4_opts[@]}" "/dev/mapper/$mapper_name"
  check_fs_features "/dev/mapper/$mapper_name"
  sync
  run_cleanups
else
  write_partition "$output_path" 4 "$rootfs_img"
  rm -f "$rootfs_img"
fi

print_info "done, the image is $(du -h --apparent-size "$output_path" | cut -f1)"
