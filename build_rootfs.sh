#!/bin/bash

#build the debian rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path [release_name]"
  echo "The release defaults to 'trixie' (Debian 13)."
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages  - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname         - The hostname for the new rootfs."
  echo "  enable_root      - Enable the root user."
  echo "  root_passwd      - The root password. This only has an effect if enable_root is set."
  echo "  username         - The unprivileged user name for the new rootfs."
  echo "  user_passwd      - The password for the unprivileged user."
  echo "  disable_base     - Disable the base packages such as zram, NetworkManager, and firmware."
  echo "  timezone         - The timezone, such as 'America/New_York'. Defaults to the build machine's timezone."
  echo "  locale           - The system locale. Defaults to 'en_US.UTF-8'."
  echo "  mirror           - The Debian mirror to use. Defaults to http://deb.debian.org/debian"
  echo "  i386             - Set this to 0 to not enable 32-bit packages (needed for Steam and Wine)."
  echo "  flatpak          - Set this to 0 to not install Flatpak and the Flathub repo."
  echo "  auto_expand      - Set this to 0 to not grow the rootfs to fill the drive on the first boot."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
}

assert_root
assert_deps "realpath debootstrap findmnt"
assert_args "$1"
parse_args "$@"

rootfs_dir="$(realpath -m "$1")"
release_name="${2:-trixie}"
if [[ "$release_name" == *=* ]]; then
  release_name="trixie"
fi

if [ "${args['distro']}" ] && [ "${args['distro']}" != "debian" ]; then
  print_error "reshimboot only supports Debian. Alpine and Ubuntu support was removed."
  exit 1
fi
if [ "${args['arch']}" ] && [ "${args['arch']}" != "$SHIMBOOT_ARCH" ]; then
  print_error "reshimboot only supports dedede, which is an $SHIMBOOT_ARCH board."
  exit 1
fi

case "$release_name" in
  bookworm|trixie) ;;
  forky|testing|sid|unstable)
    print_warning "Warning: Debian $release_name is not a stable release."
    print_warning "Newer systemd versions may not work with the 5.4 kernel that dedede's shim uses, and the"
    print_warning "patched systemd in the shimboot repo can lag behind Debian. The build will stop if this happens."
    ;;
  *)
    print_error "'$release_name' is not a supported Debian release. Use trixie (recommended), bookworm, forky, or sid."
    exit 1
    ;;
esac

host_timezone=""
if [ -f /etc/timezone ]; then
  host_timezone="$(cat /etc/timezone)"
elif [ -L /etc/localtime ]; then
  host_timezone="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
fi

packages="${args['custom_packages']-task-xfce-desktop}"
mirror="${args['mirror']:-http://deb.debian.org/debian}"
chroot_mounts="proc sys dev"

mkdir -p "$rootfs_dir"

unmount_all() {
  local mountpoint
  for mountpoint in run dev/pts dev sys proc; do
    if mountpoint -q "$rootfs_dir/$mountpoint"; then
      umount -l "$rootfs_dir/$mountpoint"
    fi
  done
}

need_remount() {
  local target="$1"
  local mnt_options
  mnt_options="$(findmnt -n -o OPTIONS -T "$target")"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint
  mountpoint="$(findmnt -n -o TARGET -T "$target")"
  mount -o remount,dev,exec "$mountpoint"
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

print_info "bootstrapping debian $release_name"
debootstrap --arch "$SHIMBOOT_ARCH" --components=main,contrib,non-free,non-free-firmware \
  "$release_name" "$rootfs_dir" "$mirror"

print_info "copying rootfs setup scripts"
cp -a "$base_dir/rootfs/." "$rootfs_dir/"
#this is a copy of the host's dns config for use during the build only
cp -L /etc/resolv.conf "$rootfs_dir/etc/resolv.conf.build"
rm -f "$rootfs_dir/etc/resolv.conf"
cp "$rootfs_dir/etc/resolv.conf.build" "$rootfs_dir/etc/resolv.conf"

#prevent package scripts from starting services inside the chroot
cat > "$rootfs_dir/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$rootfs_dir/usr/sbin/policy-rc.d"

print_info "creating bind mounts for chroot"
add_cleanup unmount_all
for mountpoint in $chroot_mounts; do
  mkdir -p "$rootfs_dir/$mountpoint"
  mount --make-rslave --rbind "/$mountpoint" "$rootfs_dir/$mountpoint"
done
#use a private /run so that package scripts cannot talk to the host's services
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$rootfs_dir/run"

LC_ALL=C.UTF-8 chroot "$rootfs_dir" /usr/bin/env -i \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME=/root TERM="${TERM:-linux}" \
  DEBUG="$DEBUG" \
  RELEASE="$release_name" \
  PACKAGES="$packages" \
  NEW_HOSTNAME="${args['hostname']}" \
  ROOT_PASSWD="${args['root_passwd']}" \
  ENABLE_ROOT="${args['enable_root']}" \
  NEW_USERNAME="${args['username']}" \
  USER_PASSWD="${args['user_passwd']}" \
  DISABLE_BASE="${args['disable_base']}" \
  TIMEZONE="${args['timezone']:-${host_timezone:-Etc/UTC}}" \
  NEW_LOCALE="${args['locale']:-en_US.UTF-8}" \
  MIRROR="$mirror" \
  ENABLE_I386="${args['i386']:-1}" \
  ENABLE_FLATPAK="${args['flatpak']:-1}" \
  AUTO_EXPAND="${args['auto_expand']:-1}" \
  /bin/bash /opt/setup_rootfs.sh

run_cleanups
rm -f "$rootfs_dir/usr/sbin/policy-rc.d" "$rootfs_dir/opt/setup_rootfs.sh" "$rootfs_dir/etc/resolv.conf.build"

print_info "rootfs has been created"
