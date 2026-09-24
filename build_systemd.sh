#!/bin/bash

#build systemd for a debian release with the chrome os kernel patch applied,
#for releases where the shimboot repo does not have a matching version.
#the result is a small apt repository that build_rootfs.sh can install from.

. ./common.sh

print_help() {
  echo "Usage: ./build_systemd.sh output_dir release_name"
  echo "Builds patched systemd packages into output_dir/release_name."
  echo "Nothing is rebuilt if that directory already has the current Debian version."
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  mirror    - The Debian mirror to use. Defaults to http://deb.debian.org/debian"
  echo "  cache_dir - Keep downloaded Debian packages here."
  echo "  extra_ca  - A CA certificate to trust during the build, for networks that intercept HTTPS."
  echo "  force     - Rebuild even if the packages are up to date."
  echo "  source_release - Take the systemd source from this release instead, for example"
  echo "                   trixie's systemd for forky. Newer systemd needs a newer kernel than 5.4."
}

assert_root
assert_deps "debootstrap curl xz python3 findmnt"
assert_args "$2"
parse_args "$@"

output_dir="$(realpath -m "$1")"
release_name="$2"
mirror="${args['mirror']:-http://deb.debian.org/debian}"
cache_dir="${args['cache_dir']}"
extra_ca="${args['extra_ca']}"
source_release="${args['source_release']:-$release_name}"
repo_dir="$output_dir/$release_name"

#the systemd source version that debian currently has for this release
debian_systemd_version() {
  curl -fsSL "$mirror/dists/$source_release/main/source/Sources.xz" | xz -d | awk '
    $1 == "Package:" {pkg = $2}
    $1 == "Version:" && pkg == "systemd" {print $2; exit}
  '
}

debian_version="$(retry_cmd debian_systemd_version)"
if [ ! "$debian_version" ]; then
  print_error "could not find the systemd version in debian $source_release"
  exit 1
fi
patched_version="${debian_version}+reshimboot1"

if ! is_true "${args['force']}" && [ -f "$repo_dir/Packages" ] && [ "$(cat "$repo_dir/version" 2>/dev/null)" = "$patched_version" ]; then
  print_info "patched systemd $patched_version for $release_name is already built"
  exit 0
fi

print_info "building patched systemd $patched_version (from $source_release) for debian $release_name"
mkdir -p "$output_dir"
work_dir="$(mktemp -d "$output_dir/.systemd_build.XXXXXX")"
chroot_dir="$work_dir/chroot"
#--one-file-system keeps this from ever deleting through a leftover bind mount
add_cleanup "rm -rf --one-file-system '$work_dir'"

unmount_chroot() {
  local mountpoint
  for mountpoint in var/cache/apt/archives run dev/pts dev sys proc; do
    if mountpoint -q "$chroot_dir/$mountpoint"; then
      umount -l "$chroot_dir/$mountpoint"
    fi
  done
}

mount_point="$(findmnt -n -o TARGET -T "$output_dir")"
if findmnt -n -o OPTIONS -T "$output_dir" | grep -qe noexec -e nodev; then
  mount -o remount,dev,exec "$mount_point"
fi

debootstrap --variant=buildd --arch "$SHIMBOOT_ARCH" "$release_name" "$chroot_dir" "$mirror"

cat > "$chroot_dir/etc/apt/sources.list" << EOF
deb $mirror $release_name main
deb-src $mirror $release_name main
EOF
if [ "$source_release" != "$release_name" ]; then
  echo "deb-src $mirror $source_release main" >> "$chroot_dir/etc/apt/sources.list"
fi
cp -L /etc/resolv.conf "$chroot_dir/etc/resolv.conf"
if [ "$extra_ca" ]; then
  mkdir -p "$chroot_dir/usr/local/share/ca-certificates"
  cp "$extra_ca" "$chroot_dir/usr/local/share/ca-certificates/reshimboot-build.crt"
fi
cp "$tools_dir/patch_systemd.py" "$chroot_dir/opt/patch_systemd.py"

add_cleanup unmount_chroot
for mountpoint in proc sys dev; do
  mount --make-rslave --rbind "/$mountpoint" "$chroot_dir/$mountpoint"
done
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$chroot_dir/run"
if [ "$cache_dir" ]; then
  cache_dir="$(realpath -m "$cache_dir")"
  mkdir -p "$cache_dir/apt-archives/partial"
  mount --bind "$cache_dir/apt-archives" "$chroot_dir/var/cache/apt/archives"
fi

#the build profiles skip the test suite, man pages, and installer packages,
#which saves most of the build time
cat > "$chroot_dir/opt/build.sh" << 'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
profiles="nocheck,nodoc,noinsttest,noudeb"
if [ -f /usr/local/share/ca-certificates/reshimboot-build.crt ]; then
  apt-get install -y ca-certificates
  update-ca-certificates
fi
apt-get update
apt-get install -y python3

mkdir -p /build
cd /build
apt-get source "systemd=$DEBIAN_VERSION"
cd "$(find /build -mindepth 1 -maxdepth 1 -type d | head -n1)"
#install the build dependencies of this exact source, which can be from
#an older release than the one it is built for
apt-get build-dep -y -P "$profiles" ./
python3 /opt/patch_systemd.py .

#a higher version than debian's, so apt always prefers the patched packages
{
  printf 'systemd (%s) UNRELEASED; urgency=medium\n\n' "$PATCHED_VERSION"
  printf '  * Make mount_nofollow() call mount() directly, which Chrome OS kernels need.\n'
  printf '    Built by reshimboot.\n\n'
  printf ' -- reshimboot <reshimboot@users.noreply.github.com>  %s\n\n' "$(date -R)"
  cat debian/changelog
} > debian/changelog.new
mv debian/changelog.new debian/changelog

DEB_BUILD_OPTIONS="nocheck nodoc noddebs parallel=$(nproc)" DEB_BUILD_PROFILES="${profiles//,/ }" \
  dpkg-buildpackage -b -uc -us

mkdir -p /out
cp /build/*.deb /out/
cd /out
dpkg-scanpackages --multiversion . > Packages
EOF

LC_ALL=C.UTF-8 chroot "$chroot_dir" /usr/bin/env -i \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME=/root \
  DEBIAN_VERSION="$debian_version" \
  PATCHED_VERSION="$patched_version" \
  /bin/bash /opt/build.sh

rm -rf "$repo_dir"
mkdir -p "$repo_dir"
cp "$chroot_dir/out/"* "$repo_dir/"
echo "$patched_version" > "$repo_dir/version"
run_cleanups
print_info "patched systemd packages are in $repo_dir"
