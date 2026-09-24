#!/bin/bash

#download everything and build a complete reshimboot image for dedede

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

print_help() {
  echo "Usage: sudo ./build_complete.sh"
  echo "reshimboot only builds for the dedede board, so no board name is needed."
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  desktop      - The desktop environment to install. Defaults to 'xfce'."
  echo "                   Valid options: gnome, xfce, kde, lxde, gnome-flashback, cinnamon, mate, lxqt"
  echo "  release      - The Debian release: 'bookworm', 'trixie' (default), 'forky', or 'sid'."
  echo "  compress_img - Compress the final disk image into a zip file. Set to any value to enable."
  echo "  quiet        - Don't use progress indicators which may clog up log files."
  echo "  data_dir     - The working directory for the scripts. Defaults to ./data"
  echo "  rootfs_dir   - Use a prebuilt rootfs directory instead of building one."
  echo "  luks         - Set to 1 to encrypt the rootfs partition with LUKS2."
  echo "  shim_path    - Use a shim image you already have instead of downloading one."
  echo "  reco_path    - Use a recovery image you already have instead of downloading one."
  echo "  desktop, release, etc. are passed through to the individual build scripts."
}

assert_root
parse_args "$@"

if [ "${args['board']}" ] && [ "${args['board']}" != "$SHIMBOOT_BOARD" ]; then
  print_error "reshimboot only supports the '$SHIMBOOT_BOARD' board."
  exit 1
fi
if [ "${args['arch']}" ] && [ "${args['arch']}" != "$SHIMBOOT_ARCH" ]; then
  print_error "reshimboot only supports dedede, which is an $SHIMBOOT_ARCH board."
  exit 1
fi
if [ "${args['distro']}" ] && [ "${args['distro']}" != "debian" ]; then
  print_error "reshimboot only supports Debian."
  exit 1
fi

board="$SHIMBOOT_BOARD"
desktop="${args['desktop']:-xfce}"
release="${args['release']:-trixie}"
compress_img="${args['compress_img']}"
quiet="${args['quiet']}"
luks="${args['luks']}"

data_dir="${args['data_dir']}"
if [ -z "$data_dir" ]; then
  data_dir="$base_dir/data"
else
  data_dir="$(realpath -m "$data_dir")"
fi
rootfs_dir="${args['rootfs_dir']}"

#chrome os shim and recovery image sources
shim_url="https://dl.cros.download/files/$board/$board.zip"
boards_url="https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=ChromeOS"

needed_deps="wget curl python3 unzip zip git debootstrap cpio cgpt mkfs.ext4 mkfs.ext2 sfdisk debugfs depmod findmnt pv"
if is_true "$luks"; then
  needed_deps="$needed_deps cryptsetup losetup"
fi
if [ "$(check_deps "$needed_deps")" ]; then
  if [ -f "/etc/debian_version" ]; then
    print_title "installing build dependencies"
    apt-get install -y wget curl python3 unzip zip git debootstrap cpio cgpt kmod pv fdisk gdisk e2fsprogs cryptsetup
  fi
  assert_deps "$needed_deps"
fi

#reshimboot builds the initramfs itself, so it does not need binwalk anymore
if command -v binwalk > /dev/null 2>&1; then
  print_info "note: binwalk is installed but no longer used, you can remove it if you want"
fi

mkdir -p "$data_dir"

shim_bin="${args['shim_path']:-$data_dir/shim_$board.bin}"
shim_zip="$data_dir/shim_$board.zip"
reco_bin="${args['reco_path']:-$data_dir/reco_$board.bin}"
reco_zip="$data_dir/reco_$board.zip"

extract_zip() {
  local zip_path="$1"
  local bin_path="$2"
  print_info "extracting $(basename "$zip_path")"
  if [ ! "$quiet" ] && command -v pv > /dev/null; then
    local total_bytes
    total_bytes="$(unzip -lq "$zip_path" | tail -1 | xargs | cut -d' ' -f1)"
    unzip -p "$zip_path" | pv -s "$total_bytes" > "$bin_path"
  else
    unzip -p "$zip_path" > "$bin_path"
  fi
  rm -f "$zip_path"
}

download_and_unzip() {
  local url="$1"
  local zip_path="$2"
  local bin_path="$3"
  if [ -f "$bin_path" ]; then
    return 0
  fi
  #stream the zip straight through funzip so a huge image is never stored twice
  if command -v funzip > /dev/null; then
    print_info "downloading and extracting $(basename "$bin_path")"
    if retry_cmd bash -c "wget -q -O - '$url' | funzip > '$bin_path.part'"; then
      mv "$bin_path.part" "$bin_path"
      return 0
    fi
    rm -f "$bin_path.part"
  fi
  #fall back to downloading the whole zip and extracting it
  retry_cmd wget -q --show-progress "$url" -O "$zip_path" -c
  extract_zip "$zip_path" "$bin_path"
}

get_reco_url() {
  wget -qO- "$boards_url" | python3 -c '
import json, sys

all_builds = json.load(sys.stdin)
board_name = sys.argv[1]
if board_name not in all_builds["builds"]:
  print("Invalid board name: " + board_name, file=sys.stderr)
  sys.exit(1)

board = all_builds["builds"][board_name]
if "models" in board:
  for device in board["models"].values():
    if device["pushRecoveries"]:
      board = device
      break

reco_url = list(board["pushRecoveries"].values())[-1]
print(reco_url)
' "$board"
}

if [ ! -f "$reco_bin" ]; then
  print_title "downloading the recovery image"
  reco_url="$(get_reco_url)"
  print_info "found url: $reco_url"
  download_and_unzip "$reco_url" "$reco_zip" "$reco_bin"
fi
if ! verify_disk_image "$reco_bin" "$SHIM_ROOTFS_PART"; then
  print_error "the recovery image is corrupted, delete $reco_bin and try again"
  exit 1
fi

if [ ! -f "$shim_bin" ]; then
  print_title "downloading the shim image"
  download_and_unzip "$shim_url" "$shim_zip" "$shim_bin"
fi
if ! verify_disk_image "$shim_bin" "$SHIM_KERNEL_PART $SHIM_ROOTFS_PART"; then
  print_error "the shim image is corrupted, delete $shim_bin and try again"
  exit 1
fi

if [ ! "$rootfs_dir" ]; then
  print_title "building the debian $release rootfs"
  rootfs_dir="$data_dir/rootfs_$board"
  if findmnt -T "$rootfs_dir/dev" > /dev/null 2>&1; then
    umount -l "$rootfs_dir"/* 2>/dev/null || true
  fi
  rm -rf "$rootfs_dir"
  mkdir -p "$rootfs_dir"

  ./build_rootfs.sh "$rootfs_dir" "$release" \
    custom_packages="task-$desktop-desktop" \
    hostname="reshimboot" \
    username=user \
    user_passwd=user
fi

print_title "patching the rootfs with dedede drivers and firmware"
retry_cmd ./patch_rootfs.sh "$shim_bin" "$reco_bin" "$rootfs_dir"

print_title "building the final disk image"
final_image="$data_dir/shimboot_$board.bin"
rm -f "$final_image"
./build.sh "$final_image" "$shim_bin" "$rootfs_dir" "quiet=$quiet" "name=debian" "luks=$luks"
print_info "build complete, the image is at $final_image"

clean_loops

if [ "$compress_img" ]; then
  print_title "compressing the disk image"
  image_zip="$data_dir/shimboot_$board.zip"
  rm -f "$image_zip"
  zip -j "$image_zip" "$final_image"
  print_info "the compressed image is at $image_zip"
fi
