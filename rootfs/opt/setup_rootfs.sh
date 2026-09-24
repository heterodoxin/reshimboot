#!/bin/bash

#set up the debian rootfs for dedede
#this is meant to be run within the chroot created by build_rootfs.sh
#all settings are passed in as environment variables

set -e
if [ "$DEBUG" ]; then
  set -x
fi

export DEBIAN_FRONTEND="noninteractive"
export LC_ALL="C.UTF-8"

#the patched systemd lives here, see https://github.com/ading2210/chromeos-systemd
shimboot_repo="https://shimboot.ading.dev/debian"
shimboot_repo_domain="shimboot.ading.dev"

apt_opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

print_step() {
  printf '\033[1;34m[setup_rootfs] %s\033[0m\n' "$1"
}

print_warning() {
  printf '\033[1;33m[setup_rootfs] %s\033[0m\n' "$1" >&2
}

apt_install() {
  apt-get install "${apt_opts[@]}" "$@"
}

#install only the packages that exist in the current release
#this keeps the package lists working on both bookworm and trixie
apt_install_available() {
  local available=()
  local pkg
  for pkg in "$@"; do
    if apt-cache show "$pkg" > /dev/null 2>&1; then
      available+=("$pkg")
    else
      print_warning "package $pkg is not available in $RELEASE, skipping it"
    fi
  done
  if [ "${#available[@]}" -gt 0 ]; then
    apt_install "${available[@]}"
  fi
}

#dns inside the chroot needs the build machine's config, even after
#systemd-resolved replaces /etc/resolv.conf with a symlink
restore_build_dns() {
  if [ -f /etc/resolv.conf.build ]; then
    rm -f /etc/resolv.conf
    cp /etc/resolv.conf.build /etc/resolv.conf
  fi
}

write_apt_sources() {
  local components="main contrib non-free non-free-firmware"
  if [ "$RELEASE" = "bookworm" ]; then
    components="main contrib non-free non-free-firmware"
  fi

  rm -f /etc/apt/sources.list
  if [ "$RELEASE" = "sid" ] || [ "$RELEASE" = "unstable" ]; then
    cat > /etc/apt/sources.list.d/debian.sources << EOF
Types: deb
URIs: $MIRROR
Suites: $RELEASE
Components: $components
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  else
    cat > /etc/apt/sources.list.d/debian.sources << EOF
Types: deb
URIs: $MIRROR
Suites: $RELEASE $RELEASE-updates
Components: $components
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $RELEASE-security
Components: $components
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  fi
}

#the shimboot repo has to be listed first. debian and the shimboot repo
#publish systemd with identical version numbers, and apt downloads an
#identical version from whichever source it reads first.
write_shimboot_sources() {
  cat > /etc/apt/sources.list.d/00-shimboot.sources << EOF
Types: deb
URIs: $shimboot_repo
Suites: $RELEASE
Components: main
Architectures: amd64
Trusted: yes
EOF

  cat > /etc/apt/preferences.d/00-shimboot << EOF
Package: *
Pin: origin $shimboot_repo_domain
Pin-Priority: 1001
EOF
}

#the packages from the shimboot repo that are currently installed
installed_shimboot_packages() {
  local list_file
  list_file="$(ls /var/lib/apt/lists/*"${shimboot_repo_domain}"*"_binary-amd64_Packages" 2>/dev/null | head -n1)"
  if [ ! "$list_file" ]; then
    return 0
  fi
  local pkg
  for pkg in $(awk '$1 == "Package:" {print $2}' "$list_file" | sort -u); do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      echo "$pkg"
    fi
  done
}

#make sure that the systemd we just installed is really the patched one
#an unpatched systemd fails to boot with "Failed to mount API filesystems"
verify_patched_systemd() {
  local list_file pkg version expected actual deb
  list_file="$(ls /var/lib/apt/lists/*"${shimboot_repo_domain}"*"_binary-amd64_Packages" 2>/dev/null | head -n1)"
  if [ ! "$list_file" ]; then
    echo "The shimboot package list could not be downloaded from $shimboot_repo." >&2
    return 1
  fi

  for pkg in systemd libsystemd-shared libsystemd0; do
    version="$(dpkg-query -W -f='${Version}' "$pkg")"
    expected="$(awk -v p="$pkg" -v v="$version" '
      $1 == "Package:" {name = $2}
      $1 == "Version:" {ver = $2}
      $1 == "SHA256:" && name == p && ver == v {print $2}
    ' "$list_file")"
    if [ ! "$expected" ]; then
      echo "$pkg $version is installed, but the shimboot repo does not provide that version." >&2
      echo "Debian $RELEASE probably has a newer systemd than the patched one. Try building trixie instead." >&2
      return 1
    fi
    deb="$(ls /var/cache/apt/archives/"${pkg}_${version//:/%3a}_"*.deb 2>/dev/null | head -n1)"
    if [ "$deb" ]; then
      actual="$(sha256sum "$deb" | cut -d' ' -f1)"
      if [ "$actual" != "$expected" ]; then
        echo "$pkg $version was downloaded from Debian instead of the shimboot repo." >&2
        return 1
      fi
    fi
  done
}

install_patched_systemd() {
  print_step "installing the patched systemd"
  apt-get upgrade "${apt_opts[@]}" --allow-downgrades

  #reinstall anything that also exists in the shimboot repo, since the
  #versions can be identical. delete the cached copies first so that the
  #ones downloaded from debian are not reused. only these packages are
  #removed, so a shared package cache between builds keeps working.
  local shimboot_pkgs pkg
  shimboot_pkgs="$(installed_shimboot_packages)"
  for pkg in $shimboot_pkgs; do
    rm -f "/var/cache/apt/archives/${pkg}_"*.deb
  done
  if [ "$shimboot_pkgs" ]; then
    # shellcheck disable=SC2086
    apt_install --reinstall --allow-downgrades $shimboot_pkgs
  fi
  apt_install --allow-downgrades systemd-resolved systemd-timesyncd
  restore_build_dns

  if ! verify_patched_systemd; then
    echo "Error: the patched systemd was not installed correctly. The image would not boot." >&2
    exit 1
  fi
}

install_base_packages() {
  print_step "installing base packages"
  local packages=(
    #general utilities
    sudo bash-completion command-not-found nano less curl wget ca-certificates
    locales tzdata zram-tools cloud-guest-utils e2fsprogs file pciutils usbutils
    #networking
    network-manager wpasupplicant iw rfkill iptables
    #bluetooth
    bluez
    #audio: pipewire replaces pulseaudio
    pipewire-audio wireplumber pipewire-pulse pipewire-alsa alsa-utils alsa-ucm-conf
    #firmware for the wifi, bluetooth, gpu, and audio dsp on dedede
    firmware-iwlwifi firmware-realtek firmware-sof-signed firmware-intel-graphics
    firmware-intel-misc firmware-misc-nonfree firmware-linux-free
    #hardware video decoding on the jasper lake gpu
    intel-media-va-driver vainfo
    #the shim kernel has no exfat or ntfs driver, so use the fuse ones
    fuse3 exfat-fuse exfatprogs ntfs-3g dosfstools
    #libfuse2 is needed by appimages
    libfuse2t64 libfuse2
    #chromebook keyboard layout (search key, top row keys)
    croskbd
  )
  apt_install_available "${packages[@]}"

  if [ "$ENABLE_FLATPAK" = "1" ]; then
    apt_install_available flatpak
    if command -v flatpak > /dev/null; then
      flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
        || print_warning "could not add the flathub repo, run 'flatpak remote-add flathub https://dl.flathub.org/repo/flathub.flatpakrepo' later"
    fi
  fi

  #update the command-not-found database
  if command -v apt-file > /dev/null; then
    apt-file update || true
  fi
}

configure_zram() {
  #the shim kernel has lzo and lzo-rle, but not zstd or lz4
  if [ -f /etc/default/zramswap ]; then
    sed -i '/^ALGO=/d; /^PERCENT=/d; /^SIZE=/d; /^PRIORITY=/d' /etc/default/zramswap
    cat >> /etc/default/zramswap << EOF
ALGO=lzo-rle
PERCENT=100
PRIORITY=100
EOF
  fi
}

#dedede's kernel has no nf_tables support, only the legacy iptables api
configure_iptables() {
  local tool
  for tool in iptables ip6tables arptables ebtables; do
    if [ -x "/usr/sbin/$tool-legacy" ]; then
      update-alternatives --set "$tool" "/usr/sbin/$tool-legacy"
    fi
  done
}

#the shim kernel does not allow unprivileged user namespaces, so bubblewrap
#(used by flatpak, steam, and others) needs to be setuid. using
#dpkg-statoverride means that this survives package upgrades.
configure_bwrap() {
  if [ -e /usr/bin/bwrap ]; then
    if ! dpkg-statoverride --list /usr/bin/bwrap > /dev/null; then
      dpkg-statoverride --update --add root root 4755 /usr/bin/bwrap
    fi
  fi
}

configure_locale() {
  print_step "setting up the locale ($NEW_LOCALE) and timezone ($TIMEZONE)"
  local charset="${NEW_LOCALE#*.}"
  if [ "$charset" = "$NEW_LOCALE" ]; then
    charset="UTF-8"
  fi
  if ! grep -q "^$NEW_LOCALE " /etc/locale.gen; then
    echo "$NEW_LOCALE $charset" >> /etc/locale.gen
  fi
  if [ "$NEW_LOCALE" != "en_US.UTF-8" ]; then
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  fi
  locale-gen
  update-locale LANG="$NEW_LOCALE"

  if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
  else
    print_warning "unknown timezone $TIMEZONE, using UTC"
    ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
    echo "Etc/UTC" > /etc/timezone
  fi
  dpkg-reconfigure -f noninteractive tzdata
}

configure_hostname() {
  if [ ! "$NEW_HOSTNAME" ]; then
    read -rp "Enter the hostname for the system: " NEW_HOSTNAME
  fi
  echo "$NEW_HOSTNAME" > /etc/hostname
  cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $NEW_HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
}

install_desktop() {
  print_step "installing the desktop: $PACKAGES"
  # shellcheck disable=SC2086
  apt_install $PACKAGES

  #extras that the task packages do not always pull in
  if [ "$PACKAGES" ]; then
    #zenity runs the first login welcome, mesa-utils is used by shimboot-doctor
    apt_install_available zenity mesa-utils
  fi
  case "$PACKAGES" in
    *xfce*|*lxde*|*mate*|*lxqt*|*cinnamon*)
      apt_install_available blueman pavucontrol network-manager-gnome
      ;;
    *kde*)
      apt_install_available plasma-nm bluedevil plasma-pa
      ;;
  esac

  #apply the gnome defaults from /usr/share/glib-2.0/schemas/90-reshimboot.gschema.override
  if command -v glib-compile-schemas > /dev/null; then
    glib-compile-schemas /usr/share/glib-2.0/schemas
  fi

  #make sure pipewire won and pulseaudio is gone
  apt_install_available pipewire-audio
  if dpkg-query -W -f='${Status}' pulseaudio 2>/dev/null | grep -q "install ok installed"; then
    apt-get purge "${apt_opts[@]}" pulseaudio
  fi
  restore_build_dns
}

set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd "$user"; do
      echo "Failed to set password for $user, please try again."
    done
  else
    printf '%s:%s\n' "$user" "$password" | chpasswd
  fi
}

create_user() {
  if [ ! "$NEW_USERNAME" ]; then
    read -rp "Enter the username for the user account: " NEW_USERNAME
  fi

  local groups="sudo"
  local group
  for group in audio video input netdev plugdev bluetooth render lpadmin; do
    if getent group "$group" > /dev/null; then
      groups="$groups,$group"
    fi
  done
  useradd -m -s /bin/bash -G "$groups" "$NEW_USERNAME"

  if [ "$ENABLE_ROOT" ]; then
    echo "Enter a root password:"
    set_password root "$ROOT_PASSWD"
  else
    passwd -l root > /dev/null
  fi

  echo "Enter a user password:"
  set_password "$NEW_USERNAME" "$USER_PASSWD"

  #prebuilt images all share the same password, so the welcome app and the
  #terminal greeter keep asking to change it until this marker is removed
  if [ "$DEFAULT_PASSWORD" = "1" ]; then
    local state_dir="/home/$NEW_USERNAME/.config/reshimboot"
    mkdir -p "$state_dir"
    touch "$state_dir/default-password"
    chown -R "$NEW_USERNAME:$NEW_USERNAME" "/home/$NEW_USERNAME/.config"
  fi
}

unit_exists() {
  local dir
  for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    if [ -e "$dir/$1" ]; then
      return 0
    fi
  done
  return 1
}

enable_services() {
  print_step "enabling services"
  systemctl enable kill-frecon.service
  local unit
  for unit in NetworkManager.service systemd-resolved.service systemd-timesyncd.service \
              zramswap.service fstrim.timer bluetooth.service; do
    if unit_exists "$unit"; then
      systemctl enable "$unit"
    fi
  done
  if [ "$AUTO_EXPAND" = "1" ]; then
    systemctl enable shimboot-expand-rootfs.service
  fi

  #the hostname, locale, timezone, and users are already set up, and
  #systemd-firstboot would otherwise wait for input on a console that you
  #cannot see when the fresh machine id triggers first boot mode
  systemctl mask systemd-firstboot.service
  #hibernation is not possible with the shim kernel
  systemctl mask systemd-hibernate-resume.service > /dev/null 2>&1 || true
}

finalize() {
  print_step "cleaning up"
  #remove the certificate that was only trusted for the build
  if [ -f /usr/local/share/ca-certificates/reshimboot-build.crt ]; then
    rm -f /usr/local/share/ca-certificates/reshimboot-build.crt
    update-ca-certificates --fresh > /dev/null
  fi

  #disable selinux to prevent a harmless error from showing up during the boot
  mkdir -p /etc/selinux
  echo "SELINUX=disabled" > /etc/selinux/config

  #enable the greeter for interactive shells
  if ! grep -q shimboot_greeter "/home/$NEW_USERNAME/.bashrc"; then
    echo '[[ $- == *i* ]] && /usr/local/bin/shimboot_greeter' >> "/home/$NEW_USERNAME/.bashrc"
  fi

  #with a shared package cache, the cache is a bind mount that is removed
  #after the build, so the image ends up without the packages either way
  if [ "$APT_CACHE_SHARED" != "1" ]; then
    apt-get clean
  fi

  #a fresh machine id is generated on the first boot, so that every
  #prebuilt image does not share the same one
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id

  #use systemd-resolved on the real system
  rm -f /etc/resolv.conf
  ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
}

main() {
  print_step "configuring apt for debian $RELEASE"
  write_apt_sources
  apt-get update
  apt_install ca-certificates
  #pick up a build-only certificate from extra_ca, if there is one
  update-ca-certificates > /dev/null

  write_shimboot_sources
  if [ "$ENABLE_I386" = "1" ]; then
    dpkg --add-architecture i386
  fi
  apt-get update

  install_patched_systemd
  configure_hostname

  #the bootloader copies this to check the rootfs before booting it
  apt_install_available e2fsck-static

  if [ ! "$DISABLE_BASE" ]; then
    install_base_packages
    configure_zram
    configure_iptables
  else
    apt_install_available locales sudo
  fi
  restore_build_dns

  configure_locale
  install_desktop
  configure_bwrap
  create_user
  enable_services

  #the desktop can pull in a different systemd package, so check again
  if ! verify_patched_systemd; then
    echo "Error: installing the desktop replaced the patched systemd. The image would not boot." >&2
    exit 1
  fi
  finalize
}

main
