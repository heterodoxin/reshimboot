#!/bin/bash

#build the debian rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path [release_name]"
  echo "The release defaults to 'trixie' (Debian 13)."
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages  - The packages that will be installed in place of task-kde-desktop."
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
  echo "  extra_ca         - A CA certificate to trust during the build only, for networks that intercept HTTPS."
  echo "  default_password - Set to 1 if user_passwd is a publicly known default, so the user is asked to change it."
  echo "  cache_dir        - Keep downloaded Debian packages here, which makes later builds much faster."
  echo "  systemd_repo     - A directory made by build_systemd.sh to install the patched systemd from,"
  echo "                     instead of the shimboot repo. Needed for releases the shimboot repo lacks."
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
  bookworm|trixie|forky) ;;
  sid|unstable)
    print_warning "Warning: Debian $release_name changes every day and can break at any time."
    ;;
  *)
    print_error "'$release_name' is not a supported Debian release. Use forky, trixie, bookworm, or sid."
    exit 1
    ;;
esac

#the shimboot repo only has systemd builds that match bookworm and trixie
if [ "$release_name" != "bookworm" ] && [ "$release_name" != "trixie" ] && [ ! "${args['systemd_repo']}" ]; then
  print_error "Debian $release_name needs a locally built systemd. Run ./build_systemd.sh first and pass"
  print_error "its output with systemd_repo=, or use build_complete.sh, which does this for you."
  exit 1
fi

host_timezone=""
if [ -f /etc/timezone ]; then
  host_timezone="$(cat /etc/timezone)"
elif [ -L /etc/localtime ]; then
  host_timezone="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
fi

packages="${args['custom_packages']-task-kde-desktop}"
mirror="${args['mirror']:-http://deb.debian.org/debian}"
chroot_mounts="proc sys dev"

mkdir -p "$rootfs_dir"

unmount_all() {
  local mountpoint
  for mountpoint in var/cache/apt/archives run dev/pts dev sys proc; do
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

# shellcheck disable=SC2054  # the commas are part of a single --components argument
debootstrap_opts=(--arch "$SHIMBOOT_ARCH" --components=main,contrib,non-free,non-free-firmware)
cache_dir="${args['cache_dir']}"
if [ "$cache_dir" ]; then
  cache_dir="$(realpath -m "$cache_dir")"
  mkdir -p "$cache_dir/apt-archives/partial"
  #the base packages are cached in a tarball, which is refreshed every two
  #weeks. anything that got updated since then is upgraded later anyway.
  base_tarball="$cache_dir/debootstrap-$release_name-$SHIMBOOT_ARCH.tar"
  find "$cache_dir" -maxdepth 1 -name "$(basename "$base_tarball")" -mtime +14 -delete
  if [ ! -f "$base_tarball" ]; then
    print_info "downloading the debian $release_name base packages into the cache"
    tarball_work="$(mktemp -d "$cache_dir/debootstrap.XXXXXX")"
    add_cleanup "rm -rf '$tarball_work'"
    debootstrap "${debootstrap_opts[@]}" --make-tarball="$base_tarball.part" "$release_name" "$tarball_work" "$mirror"
    mv "$base_tarball.part" "$base_tarball"
  fi
  debootstrap_opts+=(--unpack-tarball="$base_tarball")
fi

print_info "bootstrapping debian $release_name"
debootstrap "${debootstrap_opts[@]}" "$release_name" "$rootfs_dir" "$mirror"

print_info "copying rootfs setup scripts"
cp -a "$base_dir/rootfs/." "$rootfs_dir/"

systemd_source="shimboot"
if [ "${args['systemd_repo']}" ]; then
  systemd_repo="$(realpath -m "${args['systemd_repo']}")"
  if [ ! -f "$systemd_repo/Packages" ]; then
    print_error "$systemd_repo is not a repo made by build_systemd.sh"
    exit 1
  fi
  rm -rf "$rootfs_dir/var/lib/reshimboot/systemd-repo"
  mkdir -p "$rootfs_dir/var/lib/reshimboot/systemd-repo"
  cp "$systemd_repo/"*.deb "$systemd_repo/Packages" "$rootfs_dir/var/lib/reshimboot/systemd-repo/"
  systemd_source="local"
fi
#this is a copy of the host's dns config for use during the build only
cp -L /etc/resolv.conf "$rootfs_dir/etc/resolv.conf.build"
rm -f "$rootfs_dir/etc/resolv.conf"
cp "$rootfs_dir/etc/resolv.conf.build" "$rootfs_dir/etc/resolv.conf"

#networks that intercept https need their certificate trusted inside the
#chroot as well. it is only used during the build and removed afterwards.
extra_ca="${args['extra_ca']}"
if [ "$extra_ca" ]; then
  if [ ! -f "$extra_ca" ]; then
    print_error "the certificate $extra_ca does not exist"
    exit 1
  fi
  mkdir -p "$rootfs_dir/usr/local/share/ca-certificates"
  cp "$extra_ca" "$rootfs_dir/usr/local/share/ca-certificates/reshimboot-build.crt"
fi

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

#share downloaded packages between builds
apt_cache_shared=""
if [ "$cache_dir" ]; then
  rm -f "$rootfs_dir/var/cache/apt/archives/"*.deb
  mount --bind "$cache_dir/apt-archives" "$rootfs_dir/var/cache/apt/archives"
  apt_cache_shared="1"
fi

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
  DEFAULT_PASSWORD="${args['default_password']}" \
  APT_CACHE_SHARED="$apt_cache_shared" \
  SYSTEMD_SOURCE="$systemd_source" \
  /bin/bash /opt/setup_rootfs.sh

run_cleanups
rm -f "$rootfs_dir/usr/sbin/policy-rc.d" "$rootfs_dir/opt/setup_rootfs.sh" "$rootfs_dir/etc/resolv.conf.build"

print_info "rootfs has been created"
