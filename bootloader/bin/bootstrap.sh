#!/bin/busybox sh
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# To bootstrap the factory installer on rootfs. This file must be executed as
# PID=1 (exec).
# Note that this script uses the busybox shell (not bash, not dash).

#original: https://chromium.googlesource.com/chromiumos/platform/initramfs/+/refs/heads/main/factory_shim/bootstrap.sh

#set -x
set +x

rescue_mode=""
AUTOBOOT_TIMEOUT=5
if [ -f /opt/shimboot.conf ]; then
  . /opt/shimboot.conf
fi

invoke_terminal() {
  local tty="$1"
  local title="$2"
  shift
  shift
  # Copied from factory_installer/factory_shim_service.sh.
  echo "${title}" >>"${tty}"
  setsid sh -c "exec script -afqc '$*' /dev/null <${tty} >>${tty} 2>&1 &"
}

enable_debug_console() {
  local tty="$1"
  echo -e "debug console enabled on ${tty}"
  invoke_terminal "${tty}" "[Bootstrap Debug Console]" "/bin/busybox sh"
}

#get a partition block device from a disk path and a part number
get_part_dev() {
  local disk="$1"
  local partition="$2"

  #disk paths ending with a number will have a "p" before the partition number
  local last_char="$(echo -n "$disk" | tail -c 1)"
  if [ "$last_char" -eq "$last_char" ] 2>/dev/null; then
    echo "${disk}p${partition}"
  else
    echo "${disk}${partition}"
  fi
}

find_rootfs_partitions() {
  local disks=$(fdisk -l 2>/dev/null | sed -n "s/Disk \(\/dev\/.*\):.*/\1/p")
  if [ ! "${disks}" ]; then
    return 1
  fi

  for disk in $disks; do
    local partitions=$(fdisk -l "$disk" 2>/dev/null | sed -n "s/^[ ]\+\([0-9]\+\).*shimboot_rootfs:\(.*\)$/\1:\2/p")
    if [ ! "${partitions}" ]; then
      continue
    fi
    for partition in $partitions; do
      get_part_dev "$disk" "$partition"
    done
  done
}

#describe a chrome os root partition, such as "R152_16765.49.0_(current)".
#chrome os updates install to the other root partition, and normal boots
#use the kernel with the highest priority. booting the older root partition
#through shimboot makes chrome os want to install the same update again.
describe_chromeos_partition() {
  local part="$1"
  local mnt="/tmp/cros_probe"
  local milestone=""
  local version=""
  mkdir -p "$mnt"
  if mount -o ro "$part" "$mnt" 2>/dev/null; then
    milestone="$(sed -n 's/^CHROMEOS_RELEASE_CHROME_MILESTONE=//p' "$mnt/etc/lsb-release" 2>/dev/null)"
    version="$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' "$mnt/etc/lsb-release" 2>/dev/null)"
    umount "$mnt"
  fi

  local description="unknown_version"
  if [ "$version" ]; then
    description="R${milestone}_${version}"
  fi

  #the kernel partition is the one right before the root partition
  local part_num="$(echo "$part" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')"
  local disk="$(echo "$part" | sed 's/p\{0,1\}[0-9]*$//')"
  local kern_num=$((part_num - 1))
  local priority="$(cgpt show -i "$kern_num" -P "$disk" 2>/dev/null)"
  local best_priority=0
  local other
  for other in 2 4; do
    local other_priority="$(cgpt show -i "$other" -P "$disk" 2>/dev/null)"
    if [ "$other_priority" -gt "$best_priority" ] 2>/dev/null; then
      best_priority="$other_priority"
    fi
  done
  #the marker is left out when the priorities cannot be read
  if [ "$priority" -gt 0 ] 2>/dev/null && [ "$priority" = "$best_priority" ]; then
    description="${description}_(current)"
  elif [ "$priority" -ge 0 ] 2>/dev/null && [ "$best_priority" -gt 0 ]; then
    description="${description}_(older)"
  fi
  echo "$description"
}

find_chromeos_partitions() {
  local roota_partitions="$(cgpt find -l ROOT-A)"
  local rootb_partitions="$(cgpt find -l ROOT-B)"

  if [ "$roota_partitions" ]; then
    for partition in $roota_partitions; do
      echo "${partition}:ChromeOS_ROOT-A_$(describe_chromeos_partition "$partition"):CrOS"
    done
  fi

  if [ "$rootb_partitions" ]; then
    for partition in $rootb_partitions; do
      echo "${partition}:ChromeOS_ROOT-B_$(describe_chromeos_partition "$partition"):CrOS"
    done
  fi
}

find_all_partitions() {
  find_chromeos_partitions
  find_rootfs_partitions
}

#from original bootstrap.sh
move_mounts() {
  local base_mounts="/sys /proc /dev"
  local newroot_mnt="$1"
  for mnt in $base_mounts; do
    # $mnt is a full path (leading '/'), so no '/' joiner
    mkdir -p "$newroot_mnt$mnt"
    mount -n -o move "$mnt" "$newroot_mnt$mnt"
  done
}

get_version() {
  local shimboot_version="$(cat /opt/.shimboot_version)"
  if [ -f "/opt/.shimboot_version_dev" ]; then
    shimboot_version="${shimboot_version}-dev-$(cat /opt/.shimboot_version_dev)"
  fi
  echo "$shimboot_version"
}

print_license() {
  cat << EOF
reshimboot $(get_version)

heterodoxin/reshimboot: a modernized shimboot for dedede Chromebooks.
Based on ading2210/shimboot: Boot desktop Linux from a Chrome OS RMA shim.
Copyright (C) 2025 ading2210
Copyright (C) 2026 reshimboot contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
EOF
}

print_selector() {
  local rootfs_partitions="$1"
  local i=1

  echo "┌───────────────────────────┐"
  echo "│ reshimboot OS Selector    │"
  echo "└───────────────────────────┘"
  echo "$(get_version) - kernel $(uname -r)"
  echo

  if [ "${rootfs_partitions}" ]; then
    for rootfs_partition in $rootfs_partitions; do
      #i don't know of a better way to split a string in the busybox shell
      local part_path="${rootfs_partition%%:*}"
      local part_name="$(echo "$rootfs_partition" | cut -d ":" -f 2)"
      echo "${i}) ${part_name} on ${part_path}"
      i=$((i+1))
    done
  else
    echo "no bootable partitions found. please see the shimboot documentation to mark a partition as bootable."
  fi

  echo "q) reboot"
  echo "s) enter a shell"
  if [ -x /bin/e2fsck.static ]; then
    echo "f) check and repair a filesystem"
  fi
  echo "l) view license"
  echo "type 'rescue <number>' to boot into a rescue shell"
}

#the first shimboot rootfs is booted automatically unless a key is pressed
autoboot() {
  local rootfs_partitions="$1"
  if [ "$AUTOBOOT_TIMEOUT" -le 0 ] 2>/dev/null; then
    return 1
  fi

  local i=1
  local target=""
  local target_name=""
  local target_index=""
  for rootfs_partition in $rootfs_partitions; do
    local part_flags="$(echo "$rootfs_partition" | cut -d ":" -f 3)"
    if [ "$part_flags" != "CrOS" ] && [ ! "$target" ]; then
      target="${rootfs_partition%%:*}"
      target_name="$(echo "$rootfs_partition" | cut -d ":" -f 2)"
      target_index="$i"
    fi
    i=$((i+1))
  done
  if [ ! "$target" ]; then
    return 1
  fi

  local remaining="$AUTOBOOT_TIMEOUT"
  echo
  while [ "$remaining" -gt 0 ]; do
    printf "\rbooting %s in %s seconds, press any key for the menu... " "$target_name" "$remaining"
    if read -t 1 -n 1 key; then
      echo
      return 1
    fi
    remaining=$((remaining-1))
  done
  echo
  echo "selected ${target_index}) ${target_name} on ${target}"
  boot_target "$target"
  return 1
}

get_selection() {
  local rootfs_partitions="$1"
  local i=1

  read -p "Your selection: " selection
  if [ "$selection" = "q" ]; then
    echo "rebooting now."
    reboot -f
  elif [ "$selection" = "s" ]; then
    reset
    enable_debug_console "$TTY1"
    return 0
  elif [ "$selection" = "f" ]; then
    repair_filesystem "$rootfs_partitions"
    return 1
  elif [ "$selection" = "l" ]; then
    clear
    print_license
    echo
    read -p "press [enter] to return to the bootloader menu"
    return 1
  fi

  local selection_cmd="$(echo "$selection" | cut -d' ' -f1)"
  if [ "$selection_cmd" = "rescue" ]; then
    selection="$(echo "$selection" | cut -d' ' -f2-)"
    rescue_mode="1"
  else
    rescue_mode=""
  fi

  for rootfs_partition in $rootfs_partitions; do
    local part_path="${rootfs_partition%%:*}"
    local part_flags="$(echo "$rootfs_partition" | cut -d ":" -f 3)"

    if [ "$selection" = "$i" ]; then
      echo "selected $part_path"
      if [ "$part_flags" = "CrOS" ]; then
        local part_name="$(echo "$rootfs_partition" | cut -d ":" -f 2)"
        if echo "$part_name" | grep -q "_(older)$"; then
          echo "warning: this is the older chrome os partition. chrome os installs its updates to"
          echo "the other partition, so booting this one makes it ask to update again every time."
          yes_no_prompt "boot it anyway? pick 'n' and choose the (current) partition instead. (y/n): " boot_older
          if [ "$boot_older" != "y" ]; then
            return 1
          fi
        fi
        echo "booting chrome os partition"
        print_donor_selector "$rootfs_partitions"
        get_donor_selection "$rootfs_partitions" "$part_path"
      else
        boot_target "$part_path"
      fi
      return 1
    fi

    i=$((i+1))
  done

  echo "invalid selection"
  sleep 1
  return 1
}

print_donor_selector() {
  local rootfs_partitions="$1"
  local i=1

  echo "Choose a partition to copy firmware and modules from:"

  for rootfs_partition in $rootfs_partitions; do
    local part_path="${rootfs_partition%%:*}"
    local part_name="$(echo "$rootfs_partition" | cut -d ":" -f 2)"
    local part_flags="$(echo "$rootfs_partition" | cut -d ":" -f 3)"

    if [ "$part_flags" = "CrOS" ]; then
      continue
    fi

    echo "${i}) ${part_name} on ${part_path}"
    i=$((i+1))
  done
}

yes_no_prompt() {
  local prompt="$1"
  local var_name="$2"

  while true; do
    read -p "$prompt" temp_result

    if [ "$temp_result" = "y" ] || [ "$temp_result" = "n" ]; then
      #the busybox shell has no other way to declare a variable from a string
      #the declare command and printf -v are both bashisms
      eval "$var_name='$temp_result'"
      return 0
    else
      echo "invalid selection"
    fi
  done
}

get_donor_selection() {
  local rootfs_partitions="$1"
  local target="$2"
  local i=1
  read -p "Your selection: " selection

  for rootfs_partition in $rootfs_partitions; do
    local part_path="${rootfs_partition%%:*}"
    local part_flags="$(echo "$rootfs_partition" | cut -d ":" -f 3)"

    if [ "$part_flags" = "CrOS" ]; then
      continue
    fi

    if [ "$selection" = "$i" ]; then
      echo "selected $part_path as the donor partition"
      yes_no_prompt "would you like to spoof verified mode? this is useful if you're planning on using chrome os while enrolled. (y/n): " use_crossystem
      yes_no_prompt "would you like to spoof an invalid hwid? this will forcibly prevent the device from being enrolled. (y/n): " invalid_hwid
      #blocking updates stops the forced "update required" screen during oobe,
      #and stops chrome os from silently updating itself and undoing the spoof
      block_updates="y"
      if [ "$use_crossystem" = "n" ]; then
        yes_no_prompt "would you like to block chrome os updates? recommended, this prevents the forced update screen. (y/n): " block_updates
      else
        echo "chrome os updates will be blocked to keep the verified mode spoof from being undone by an update."
      fi
      boot_chromeos "$target" "$part_path" "$use_crossystem" "$invalid_hwid" "$block_updates"
      return 1
    fi

    i=$((i+1))
  done

  echo "invalid selection"
  sleep 1
  return 1
}

exec_init() {
  if [ "$rescue_mode" = "1" ]; then
    echo "entering a rescue shell instead of starting init"
    echo "once you are done fixing whatever is broken, run 'exec /sbin/init' to continue booting the system normally"

    if [ -f "/bin/bash" ]; then
      exec /bin/bash < "$TTY1" >> "$TTY1" 2>&1
    else
      exec /bin/sh < "$TTY1" >> "$TTY1" 2>&1
    fi
  else
    exec /sbin/init < "$TTY1" >> "$TTY1" 2>&1
  fi
}

#undo a partially completed boot so that the menu can be shown again
cleanup_boot() {
  umount /newroot/proc 2>/dev/null
  umount /newroot/dev 2>/dev/null
  umount /newroot 2>/dev/null
  if [ -e /dev/mapper/rootfs ]; then
    cryptsetup close rootfs 2>/dev/null
  fi
}

boot_failed() {
  echo "$1"
  cleanup_boot
  read -p "press [enter] to return to the bootloader menu"
  return 1
}

#unlock the rootfs if it is encrypted. the device to use is stored in
#$rootfs_device, which is the partition itself when it is not encrypted.
open_rootfs() {
  local target="$1"
  rootfs_device="$target"
  if [ -x "$(command -v cryptsetup)" ] && cryptsetup isLuks "$target" >/dev/null 2>&1; then
    local tries=0
    while ! cryptsetup open --allow-discards "$target" rootfs; do
      tries=$((tries+1))
      if [ "$tries" -ge 3 ]; then
        return 1
      fi
    done
    rootfs_device="/dev/mapper/rootfs"
  fi
}

#check the rootfs before it is mounted, so that a drive that was unplugged or
#lost power while writing gets repaired instead of getting more corrupted.
#this uses a static e2fsck, since the shim's busybox does not have one.
#returns 1 if the boot should be cancelled.
check_filesystem() {
  local device="$1"
  if [ ! -x /bin/e2fsck.static ]; then
    return 0
  fi

  echo "checking the filesystem on $device"
  /bin/e2fsck.static -p "$device"
  local result="$?"

  #the exit code is a bit mask: 1 and 2 = errors were fixed,
  #4 = errors are left, 8 and up = e2fsck itself failed
  if [ "$result" -ge 8 ]; then
    echo "could not check the filesystem (e2fsck exited with $result), booting anyway"
    sleep 2
  elif [ "$((result & 4))" -ne 0 ]; then
    echo "the filesystem has errors that could not be fixed automatically."
    yes_no_prompt "run a full repair now? this can take a few minutes. (y/n): " run_repair
    if [ "$run_repair" = "y" ]; then
      /bin/e2fsck.static -fy "$device"
      result="$?"
    fi
    if [ "$((result & 4))" -ne 0 ] || [ "$result" -ge 8 ]; then
      yes_no_prompt "the filesystem still has errors. boot anyway? (y/n): " boot_anyway
      if [ "$boot_anyway" != "y" ]; then
        return 1
      fi
    fi
  elif [ "$result" -ne 0 ]; then
    echo "filesystem errors were found and fixed"
    sleep 1
  fi
  return 0
}

#the "f" menu option: run a full check on a partition that the user picks
repair_filesystem() {
  local rootfs_partitions="$1"
  local i=1
  echo "Choose a partition to check and repair:"
  for rootfs_partition in $rootfs_partitions; do
    local part_flags="$(echo "$rootfs_partition" | cut -d ":" -f 3)"
    if [ "$part_flags" = "CrOS" ]; then
      continue
    fi
    echo "${i}) $(echo "$rootfs_partition" | cut -d ":" -f 2) on ${rootfs_partition%%:*}"
    i=$((i+1))
  done
  read -p "Your selection: " selection

  i=1
  for rootfs_partition in $rootfs_partitions; do
    local part_flags="$(echo "$rootfs_partition" | cut -d ":" -f 3)"
    if [ "$part_flags" = "CrOS" ]; then
      continue
    fi
    if [ "$selection" = "$i" ]; then
      if ! open_rootfs "${rootfs_partition%%:*}"; then
        echo "failed to unlock the partition"
      else
        /bin/e2fsck.static -fy "$rootfs_device"
        echo "e2fsck finished with exit code $?"
        if [ "$rootfs_device" = "/dev/mapper/rootfs" ]; then
          cryptsetup close rootfs
        fi
      fi
      read -p "press [enter] to return to the bootloader menu"
      return 0
    fi
    i=$((i+1))
  done
  echo "invalid selection"
  sleep 1
}

boot_target() {
  local target="$1"

  mkdir -p /newroot
  if ! open_rootfs "$target"; then
    boot_failed "failed to unlock $target"
    return 1
  fi
  local device="$rootfs_device"

  if [ "$rescue_mode" != "1" ] && ! check_filesystem "$device"; then
    cleanup_boot
    return 1
  fi

  #discard trims the usb/sd card, noatime avoids a write on every read
  if ! mount -o rw,noatime,discard "$device" /newroot; then
    #discard is not supported on every drive, so retry without it
    if ! mount -o rw,noatime "$device" /newroot; then
      boot_failed "failed to mount $device"
      return 1
    fi
  fi

  if [ ! -e /newroot/sbin/init ] && [ ! -L /newroot/sbin/init ]; then
    boot_failed "$device does not contain /sbin/init, this is not a bootable rootfs"
    return 1
  fi

  #bind mount /dev/console to show systemd boot msgs
  if [ -f "/bin/frecon-lite" ]; then
    rm -f /dev/console
    touch /dev/console #this has to be a regular file otherwise the system crashes afterwards
    mount -o bind "$TTY1" /dev/console
  fi

  echo "moving mounts to newroot"
  move_mounts /newroot

  echo "switching root"
  mkdir -p /newroot/bootloader
  pivot_root /newroot /newroot/bootloader
  exec_init
}

boot_chromeos() {
  local target="$1"
  local donor="$2"
  local use_crossystem="$3"
  local invalid_hwid="$4"
  local block_updates="$5"

  echo "mounting target"
  mkdir -p /newroot
  if ! mount -o ro "$target" /newroot; then
    boot_failed "failed to mount $target"
    return 1
  fi

  echo "mounting tmpfs"
  mount -t tmpfs -o mode=1777 none /newroot/tmp
  mount -t tmpfs -o mode=0555 run /newroot/run
  mkdir -p -m 0755 /newroot/run/lock

  #the donor partition is bind mounted instead of copied into ram, which
  #is faster and leaves more memory for chrome os
  echo "mounting modules and firmware from the donor partition"
  local donor_mount="/newroot/tmp/donor_mnt"
  mkdir -p "$donor_mount"
  if ! mount -o ro "$donor" "$donor_mount"; then
    umount /newroot/run /newroot/tmp 2>/dev/null
    boot_failed "failed to mount the donor partition $donor (encrypted donors are not supported)"
    return 1
  fi
  mount -o bind,ro "$donor_mount/lib/modules" /newroot/lib/modules
  mount -o bind,ro "$donor_mount/lib/firmware" /newroot/lib/firmware
  umount "$donor_mount"
  rmdir "$donor_mount"

  if [ -e "/newroot/etc/init/tpm-probe.conf" ]; then
    echo "applying chrome os flex patches"
    mkdir -p /newroot/tmp/empty
    mount -o bind /newroot/tmp/empty /sys/class/tpm

    cat /newroot/etc/lsb-release | sed "s/DEVICETYPE=OTHER/DEVICETYPE=CHROMEBOOK/" > /newroot/tmp/lsb-release
    mount -o bind /newroot/tmp/lsb-release /newroot/etc/lsb-release
  fi

  echo "patching chrome os rootfs"
  cat /newroot/etc/ui_use_flags.txt | sed "/reven_branding/d" | sed "/os_install_service/d" > /newroot/tmp/ui_use_flags.txt
  mount -o bind /newroot/tmp/ui_use_flags.txt /newroot/etc/ui_use_flags.txt

  cp /opt/mount-encrypted /newroot/tmp/mount-encrypted
  cp /newroot/usr/sbin/mount-encrypted /newroot/tmp/mount-encrypted.real
  mount -o bind /newroot/tmp/mount-encrypted /newroot/usr/sbin/mount-encrypted

  cat /newroot/etc/init/boot-splash.conf | sed '/^script$/a \  pkill frecon-lite || true' > /newroot/tmp/boot-splash.conf
  mount -o bind /newroot/tmp/boot-splash.conf /newroot/etc/init/boot-splash.conf

  #stop update_engine from running. otherwise oobe forces an "update required"
  #screen every boot, and a completed update would boot normally and re-lock
  #the device, undoing the spoof. this only affects this shimboot session.
  if [ "$block_updates" = "y" ] && [ -f "/newroot/etc/init/update-engine.conf" ]; then
    echo "blocking chrome os updates"
    mount -o bind /opt/update-engine.conf /newroot/etc/init/update-engine.conf
  fi

  if [ "$use_crossystem" = "y" ]; then
    echo "patching crossystem"
    cp /opt/crossystem /newroot/tmp/crossystem
    if [ "$invalid_hwid" = "y" ]; then
      sed -i 's/^invalid_hwid=0$/invalid_hwid=1/' /newroot/tmp/crossystem
    fi

    cp /newroot/usr/bin/crossystem /newroot/tmp/crossystem_old
    mount -o bind /newroot/tmp/crossystem /newroot/usr/bin/crossystem
  fi

  echo "moving mounts"
  move_mounts /newroot

  echo "switching root"
  mkdir -p /newroot/tmp/bootloader
  pivot_root /newroot /newroot/tmp/bootloader

  echo "starting init"
  /sbin/modprobe zram
  exec_init
}

main() {
  echo "starting the shimboot bootloader"

  #e2fsck uses this to make sure that it never checks a mounted filesystem
  if [ ! -e /etc/mtab ]; then
    ln -s /proc/mounts /etc/mtab
  fi

  enable_debug_console "$TTY2"

  local valid_partitions="$(find_all_partitions)"

  clear
  print_selector "${valid_partitions}"
  autoboot "${valid_partitions}"

  while true; do
    clear
    print_selector "${valid_partitions}"

    if get_selection "${valid_partitions}"; then
      break
    fi
  done
}

trap - EXIT
main "$@"
sleep 1d
