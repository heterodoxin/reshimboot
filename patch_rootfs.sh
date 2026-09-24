#!/bin/bash

#patch the target rootfs to add the kernel modules and firmware for dedede

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

print_help() {
  echo "Usage: ./patch_rootfs.sh shim_path reco_path rootfs_dir"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  chromium_firmware - Also add the Chromium OS linux-firmware repo (large download, usually not needed)."
  echo "  audio             - Set this to 0 to skip installing the Chromebook audio (UCM) configuration."
}

assert_root
assert_deps "git depmod debugfs python3 find"
assert_args "$3"
parse_args "$@"

shim_path="$(realpath -m "$1")"
reco_path="$(realpath -m "$2")"
target_rootfs="$(realpath -m "$3")"
chromium_firmware="${args['chromium_firmware']}"
audio="${args['audio']:-1}"

#a pinned version of https://github.com/WeirdTreeThing/alsa-ucm-conf-cros
#which has ucm configs for the audio codecs used on dedede
ucm_repo="https://github.com/WeirdTreeThing/alsa-ucm-conf-cros"
ucm_commit="a46dd19"

stage_dir="$(mktemp -d -t reshimboot_patch.XXXXXX)"
add_cleanup "rm -rf '$stage_dir'"

#copy /lib/firmware (and the touchscreen firmware it links to) out of an image
#chrome os uses absolute symlinks like elan_i2c_141.0.bin -> /opt/google/touch/firmware/...
#which would be dangling on debian, so those get replaced with the real files
stage_firmware() {
  local image="$1"
  local out="$2"
  mkdir -p "$out/lib" "$out/opt/google/touch"
  copy_from_image "$image" "$SHIM_ROOTFS_PART" /lib/firmware "$out/lib"
  copy_from_image "$image" "$SHIM_ROOTFS_PART" /opt/google/touch/firmware "$out/opt/google/touch"

  local link target
  find "$out/lib/firmware" -type l | while read -r link; do
    target="$(readlink "$link")"
    if [[ "$target" == /* ]]; then
      if [ -f "$out$target" ]; then
        cp --remove-destination "$out$target" "$link"
      else
        rm -f "$link"
      fi
    fi
  done
}

copy_modules() {
  local shim_stage="$1"
  local target_rootfs="$2"

  #chrome os and debian both use /lib/modules, which is /usr/lib/modules on debian 12+
  rm -rf "$target_rootfs/lib/modules"
  mkdir -p "$target_rootfs/lib/modules"
  copy_from_image "$shim_path" "$SHIM_ROOTFS_PART" /lib/modules "$shim_stage"
  cp -a "$shim_stage/modules/." "$target_rootfs/lib/modules/"

  local kernel_dir version
  for kernel_dir in "$target_rootfs/lib/modules/"*; do
    [ -d "$kernel_dir" ] || continue
    rm -f "$kernel_dir/build" "$kernel_dir/source"
  done

  #decompress kernel modules if necessary - debian won't recognize these otherwise
  find "$target_rootfs/lib/modules" -name '*.ko.gz' -exec gunzip -f {} +
  for kernel_dir in "$target_rootfs/lib/modules/"*; do
    [ -d "$kernel_dir" ] || continue
    version="$(basename "$kernel_dir")"
    depmod -b "$target_rootfs" "$version"
  done
}

#the kernel searches /lib/firmware/updates/<kernel version> before /lib/firmware,
#so putting the chrome os firmware there gives it priority over the debian
#firmware packages without overwriting files owned by dpkg
copy_firmware() {
  local target_rootfs="$1"
  local kernel_version="$2"
  local fw_dest="$target_rootfs/lib/firmware/updates/$kernel_version"

  rm -rf "$fw_dest"
  mkdir -p "$fw_dest"

  #lowest priority first
  if is_true "$chromium_firmware"; then
    local firmware_path="$stage_dir/chromium-firmware"
    print_info "downloading the chromium os linux-firmware repo"
    retry_cmd git clone --branch master --depth=1 "https://chromium.googlesource.com/chromiumos/third_party/linux-firmware" "$firmware_path"
    rm -rf "$firmware_path/.git"
    cp -a "$firmware_path/." "$fw_dest/"
  fi
  cp -a "$stage_dir/reco/lib/firmware/." "$fw_dest/"
  cp -a "$stage_dir/shim/lib/firmware/." "$fw_dest/"
}

#the board specific modprobe configs (like the sof firmware path for audio)
#have to match the kernel, so they come from the shim rather than the recovery
#image. the generic chrome os ones (aliases.conf, alsa.conf with
#cards_limit=1, ppp.conf...) are skipped since debian has its own
copy_modprobe_config() {
  local target_rootfs="$1"
  local stage="$stage_dir/modprobe"
  mkdir -p "$stage/etc" "$stage/lib" "$target_rootfs/etc/modprobe.d"
  copy_from_image "$shim_path" "$SHIM_ROOTFS_PART" /etc/modprobe.d "$stage/etc"
  copy_from_image "$shim_path" "$SHIM_ROOTFS_PART" /lib/modprobe.d "$stage/lib"

  local conf
  for conf in "$stage/etc/modprobe.d/"alsa-*.conf "$stage/lib/modprobe.d/"*.conf; do
    [ -f "$conf" ] || continue
    cp "$conf" "$target_rootfs/etc/modprobe.d/chromeos-$(basename "$conf")"
  done
}

#install the chromebook ucm configs, and keep a copy so they can be
#re-applied whenever debian's alsa-ucm-conf package gets upgraded
install_ucm() {
  local target_rootfs="$1"
  local ucm_dir="$stage_dir/alsa-ucm-conf-cros"

  if ! retry_cmd git clone --quiet "$ucm_repo" "$ucm_dir"; then
    print_warning "failed to download the chromebook ucm configs, audio may not work"
    return 0
  fi
  git -C "$ucm_dir" checkout --quiet "$ucm_commit" || print_warning "could not check out $ucm_commit, using the latest version"

  local stash="$target_rootfs/usr/share/reshimboot/ucm2"
  rm -rf "$stash"
  mkdir -p "$stash" "$target_rootfs/usr/share/alsa/ucm2"
  cp -a "$ucm_dir/ucm2/." "$stash/"
  cp "$ucm_dir/LICENSE" "$target_rootfs/usr/share/reshimboot/ucm2.LICENSE"
  cp -a "$stash/." "$target_rootfs/usr/share/alsa/ucm2/"
}

if ! verify_disk_image "$shim_path" "$SHIM_ROOTFS_PART"; then
  print_error "$shim_path is not a valid shim image, or it is truncated"
  exit 1
fi
if ! verify_disk_image "$reco_path" "$SHIM_ROOTFS_PART"; then
  print_error "$reco_path is not a valid recovery image, or it is truncated"
  exit 1
fi

print_info "reading the shim kernel version"
copy_kernel "$shim_path" "$stage_dir/kernel.bin"
kernel_version="$(shimtool kernel-version "$stage_dir/kernel.bin")"
print_info "shim kernel version: $kernel_version"

print_info "copying modules to the rootfs"
mkdir -p "$stage_dir/shim_modules"
copy_modules "$stage_dir/shim_modules" "$target_rootfs"

print_info "copying firmware to the rootfs"
stage_firmware "$shim_path" "$stage_dir/shim"
stage_firmware "$reco_path" "$stage_dir/reco"
copy_firmware "$target_rootfs" "$kernel_version"

print_info "copying modprobe configs to the rootfs"
copy_modprobe_config "$target_rootfs"

if is_true "$audio"; then
  print_info "installing chromebook audio configs"
  install_ucm "$target_rootfs"
fi

echo "$kernel_version" > "$target_rootfs/etc/reshimboot-kernel"
print_info "done"
