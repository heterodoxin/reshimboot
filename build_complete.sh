#!/bin/bash

#download everything and build a complete reshimboot image for dedede

if [ ! -x "./common.sh" ]; then
  echo "error: the other scripts are not executable. please clone this repository with git instead of downloading the .zip from github."
  exit 1
fi

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

valid_desktops="kde gnome xfce lxde gnome-flashback cinnamon mate lxqt none"
valid_releases="trixie forky bookworm sid"

print_help() {
  echo "Usage: sudo ./build_complete.sh [key=value ...]"
  echo "reshimboot only builds for the dedede board, so no board name is needed."
  echo
  echo "Image options:"
  echo "  desktop      - The desktop to install: $valid_desktops. Defaults to 'kde' (KDE Plasma)."
  echo "  release      - The Debian release: trixie (Debian 13, default), forky (Debian 14, experimental), bookworm, or sid."
  echo "  luks         - Set to 1 to encrypt the rootfs partition with LUKS2."
  echo "  autoboot     - Seconds before the bootloader boots Debian automatically. 0 disables it. Defaults to 5."
  echo "  compress_img - Set to 1 to also write a .zip of the image, or 'xz' for a smaller .xz."
  echo
  echo "System options:"
  echo "  hostname     - Defaults to 'reshimboot'."
  echo "  username     - Defaults to 'user'."
  echo "  user_passwd  - Defaults to 'user'. Change it after the first boot."
  echo "  timezone     - Such as 'America/New_York'. Defaults to the build machine's timezone."
  echo "  locale       - Defaults to 'en_US.UTF-8'."
  echo "  flatpak      - Set to 0 to skip Flatpak and Flathub."
  echo "  i386         - Set to 0 to skip 32-bit packages (needed for Steam and Wine)."
  echo "  auto_expand  - Set to 0 to not grow the rootfs to fill the drive on the first boot."
  echo "  mirror       - The Debian mirror. Defaults to http://deb.debian.org/debian"
  echo "  systemd      - Where the patched systemd comes from: 'shimboot' (prebuilt, only for bookworm"
  echo "                 and trixie), 'build' (compiled locally, takes 15-30 minutes the first time),"
  echo "                 or 'auto' (default: shimboot when it has the release, otherwise build)."
  echo
  echo "Build options:"
  echo "  data_dir     - The working directory. Defaults to ./data"
  echo "  rootfs_dir   - Use an existing rootfs directory instead of building one."
  echo "  shim_path    - Use a shim you already have (.bin or .zip) instead of downloading it."
  echo "  reco_path    - Use a recovery image you already have (.bin or .zip)."
  echo "  quiet        - Don't show progress bars (useful for CI logs)."
  echo "  cache        - Set to 0 to not keep downloaded Debian packages in data_dir/cache between builds."
  echo "  extra_ca     - A CA certificate to trust during the build, for networks that intercept HTTPS."
}

assert_root

#shimboot took the board name as the first argument, so catch other boards
if [ "$1" ] && [[ "$1" != *=* ]] && [ "$1" != "-h" ] && [ "$1" != "--help" ]; then
  if [ "$1" != "$SHIMBOOT_BOARD" ]; then
    print_error "reshimboot only supports the '$SHIMBOOT_BOARD' board, not '$1'."
    print_error "For other boards, use the original project: https://github.com/ading2210/shimboot"
    exit 1
  fi
  shift
fi
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
desktop="${args['desktop']:-kde}"
release="${args['release']:-trixie}"
compress_img="${args['compress_img']}"
quiet="${args['quiet']}"
luks="${args['luks']}"
rootfs_dir="${args['rootfs_dir']}"

#check the options now instead of failing after downloading several gigabytes
if [[ " $valid_desktops " != *" $desktop "* ]]; then
  print_error "'$desktop' is not a valid desktop. Valid options: $valid_desktops"
  exit 1
fi
if [ "$release" = "unstable" ]; then
  release="sid"
fi
if [[ " $valid_releases " != *" $release "* ]]; then
  print_error "'$release' is not a supported release. Valid options: $valid_releases"
  exit 1
fi
#the shimboot repo only has patched systemd packages that match bookworm and
#trixie. newer releases get a locally compiled one.
systemd_mode="${args['systemd']:-auto}"
case "$systemd_mode" in
  auto)
    case "$release" in
      bookworm|trixie) systemd_mode="shimboot" ;;
      *) systemd_mode="build" ;;
    esac
    ;;
  shimboot|build) ;;
  *)
    print_error "systemd must be 'auto', 'shimboot', or 'build'"
    exit 1
    ;;
esac

#systemd 258 and newer need at least linux 5.10 and fail to mount /proc on
#dedede's 5.4 kernel ("Failed to mount early API filesystems"). forky and sid
#therefore get trixie's systemd (257), compiled for them.
systemd_source_release="$release"
if [ "$release" = "forky" ] || [ "$release" = "sid" ]; then
  systemd_source_release="trixie"
  if [ "$systemd_mode" = "shimboot" ]; then
    print_error "the shimboot repo has no systemd for $release that works with the 5.4 kernel, use systemd=build"
    exit 1
  fi
  #gdm needs systemd 259, so gnome can't be installed with systemd 257
  if [ "$desktop" = "gnome" ] || [ "$desktop" = "gnome-flashback" ]; then
    print_error "GNOME on Debian $release needs systemd 259 or newer, which can't run on dedede's 5.4 kernel."
    print_error "Use release=trixie for GNOME, or pick another desktop."
    exit 1
  fi
fi

if [ "$desktop" = "none" ]; then
  desktop_package=""
else
  desktop_package="task-$desktop-desktop"
fi

data_dir="${args['data_dir']}"
if [ -z "$data_dir" ]; then
  data_dir="$base_dir/data"
else
  data_dir="$(realpath -m "$data_dir")"
fi

shim_url="https://dl.cros.download/files/$board/$board.zip"
boards_url="https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=ChromeOS"

needed_deps="curl python3 zip git debootstrap cpio cgpt mkfs.ext4 mkfs.ext2 sfdisk debugfs depmod findmnt"
if is_true "$luks"; then
  needed_deps="$needed_deps cryptsetup losetup wget"
fi
if [ "$(check_deps "$needed_deps")" ] || [ ! -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  if [ -f "/etc/debian_version" ]; then
    print_title "installing build dependencies"
    apt-get install -y curl wget python3 zip xz-utils git debootstrap cpio cgpt kmod pv fdisk e2fsprogs \
      cryptsetup debian-archive-keyring
  fi
  assert_deps "$needed_deps"
fi

#around 6GB for the rootfs, 4GB for the recovery image, and 6GB for the final image
if [ "$(free_space_mb "$data_dir")" -lt 16000 ]; then
  print_warning "Warning: less than 16GB of free space in $data_dir, the build may run out of space."
fi

#download a zipped chrome os image and extract it on the fly, without ever
#storing the zip. keep_parts limits it to some partitions; the rest of the
#image is left as a hole in a sparse file and the download stops early.
download_image() {
  local url="$1"
  local bin_path="$2"
  local keep_parts="$3"
  local verify="$4"

  local unzip_opts=()
  if [ "$keep_parts" ]; then
    unzip_opts+=(--parts "$keep_parts")
  fi
  if is_true "$verify"; then
    unzip_opts+=(--verify)
  fi

  local curl_log
  curl_log="$(mktemp)"
  local progress=(cat)
  if [ ! "$quiet" ] && command -v pv > /dev/null; then
    progress=(pv -f -b -r -t)
  fi

  #curl complains when the download is stopped early on purpose, so its
  #messages are only shown if the extraction itself failed
  if curl -fsSL --retry 3 "$url" 2> "$curl_log" | "${progress[@]}" | shimtool unzip - "$bin_path.part" "${unzip_opts[@]}"; then
    mv "$bin_path.part" "$bin_path"
    rm -f "$curl_log"
    return 0
  fi
  cat "$curl_log" >&2
  rm -f "$curl_log" "$bin_path.part"
  return 1
}

#use a local .bin or .zip, or download the image
#the path of the resulting image is stored in $image_path
get_image() {
  local local_path="$1"
  local bin_path="$2"
  local url="$3"
  local keep_parts="$4"
  local verify="$5"

  if [ "$local_path" ]; then
    local_path="$(realpath -m "$local_path")"
    if [[ "$local_path" == *.zip ]]; then
      print_info "extracting $(basename "$local_path")"
      shimtool unzip "$local_path" "$bin_path.part" --parts "$keep_parts" ${verify:+--verify}
      mv "$bin_path.part" "$bin_path"
    else
      bin_path="$local_path"
    fi
  elif [ ! -f "$bin_path" ]; then
    retry_cmd download_image "$url" "$bin_path" "$keep_parts" "$verify"
  fi
  image_path="$bin_path"
}

get_reco_url() {
  curl -fsSL "$boards_url" | python3 -c '
import json, sys

all_builds = json.load(sys.stdin)
board_name = sys.argv[1]
if board_name not in all_builds["builds"]:
  print("Invalid board name: " + board_name, file=sys.stderr)
  sys.exit(1)

#every dedede model uses the same recovery image, so use the newest one
urls = {}
board = all_builds["builds"][board_name]
for model in board.get("models", {"": board}).values():
  for version, url in model.get("pushRecoveries", {}).items():
    urls[int(version)] = url
if not urls:
  print("No recovery image found for " + board_name, file=sys.stderr)
  sys.exit(1)
print(urls[max(urls)])
' "$board"
}

mkdir -p "$data_dir"
reco_bin="$data_dir/reco_$board.bin"
shim_bin="$data_dir/shim_$board.bin"

print_title "getting the recovery image"
reco_url=""
if [ ! "${args['reco_path']}" ] && [ ! -f "$reco_bin" ]; then
  reco_url="$(retry_cmd get_reco_url)"
  print_info "found url: $reco_url"
fi
#only ROOT-A (firmware) is needed, and the whole download is crc checked
get_image "${args['reco_path']}" "$reco_bin" "$reco_url" "$SHIM_ROOTFS_PART" 1
reco_bin="$image_path"
if ! verify_disk_image "$reco_bin" "$SHIM_ROOTFS_PART"; then
  print_error "the recovery image is corrupted, delete $reco_bin and try again"
  exit 1
fi

print_title "getting the shim image"
#only KERN-A and ROOT-A are needed, which are in the first ~10% of the image
get_image "${args['shim_path']}" "$shim_bin" "$shim_url" "$SHIM_KERNEL_PART,$SHIM_ROOTFS_PART"
shim_bin="$image_path"
if ! verify_disk_image "$shim_bin" "$SHIM_KERNEL_PART $SHIM_ROOTFS_PART"; then
  print_error "the shim image is corrupted, delete $shim_bin and try again"
  exit 1
fi
print_info "shim kernel: $(shimtool extract "$shim_bin" "$SHIM_KERNEL_PART:/dev/stdout" 2>/dev/null | shimtool kernel-version -)"

#downloaded debian packages are kept between builds unless cache=0
apt_cache_dir=""
if [ "${args['cache']:-1}" != "0" ]; then
  apt_cache_dir="$data_dir/cache"
fi

#without a password of your own, the image uses the well known "user"
#password, and asks you to change it on the first login
default_password=""
if [ ! "${args['user_passwd']}" ]; then
  default_password="1"
fi

systemd_repo=""
if [ ! "$rootfs_dir" ] && [ "$systemd_mode" = "build" ]; then
  print_title "building the patched systemd for debian $release"
  ./build_systemd.sh "$data_dir/systemd" "$release" \
    source_release="$systemd_source_release" \
    mirror="${args['mirror']}" \
    extra_ca="${args['extra_ca']}" \
    cache_dir="$apt_cache_dir"
  systemd_repo="$data_dir/systemd/$release"
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
    custom_packages="$desktop_package" \
    hostname="${args['hostname']:-reshimboot}" \
    username="${args['username']:-user}" \
    user_passwd="${args['user_passwd']:-user}" \
    timezone="${args['timezone']}" \
    locale="${args['locale']}" \
    mirror="${args['mirror']}" \
    i386="${args['i386']:-1}" \
    flatpak="${args['flatpak']:-1}" \
    auto_expand="${args['auto_expand']:-1}" \
    extra_ca="${args['extra_ca']}" \
    default_password="$default_password" \
    systemd_repo="$systemd_repo" \
    cache_dir="$apt_cache_dir"
fi

print_title "patching the rootfs with dedede drivers and firmware"
retry_cmd ./patch_rootfs.sh "$shim_bin" "$reco_bin" "$rootfs_dir"

print_title "building the final disk image"
final_image="$data_dir/shimboot_$board.bin"
rm -f "$final_image"
./build.sh "$final_image" "$shim_bin" "$rootfs_dir" "quiet=$quiet" "name=debian" \
  "luks=$luks" "autoboot=${args['autoboot']:-5}"

print_info "writing the checksum"
(cd "$(dirname "$final_image")" && sha256sum "$(basename "$final_image")" > "$(basename "$final_image").sha256")

clean_loops

compressed_image=""
if [ "$compress_img" = "xz" ]; then
  print_title "compressing the disk image with xz"
  compressed_image="$final_image.xz"
  rm -f "$compressed_image"
  xz -T0 -6 -k "$final_image"
elif is_true "$compress_img"; then
  print_title "compressing the disk image into a zip"
  compressed_image="$data_dir/shimboot_$board.zip"
  rm -f "$compressed_image"
  zip -j "$compressed_image" "$final_image"
fi

print_title "build complete"
echo "Image:    $final_image ($(du -h --apparent-size "$final_image" | cut -f1))"
echo "SHA256:   $(cut -d' ' -f1 "$final_image.sha256")"
if [ "$compressed_image" ]; then
  echo "Compressed: $compressed_image ($(du -h "$compressed_image" | cut -f1))"
fi
echo "Login:    ${args['username']:-user} / (the password you set, default 'user')"
echo
echo "Flash it to a USB drive or SD card with the Chromebook Recovery Utility, or with:"
echo "  sudo dd if=$final_image of=/dev/sdX bs=4M oflag=direct status=progress"
