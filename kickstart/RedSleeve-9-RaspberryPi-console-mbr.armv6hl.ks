# RedSleeve 9 Raspberry Pi image: armv6hl, MBR partition table, console.
#
# Modelled on the AlmaLinux kickstart AlmaLinux-9-RaspberryPi-console-mbr.aarch64.ks
# from https://github.com/AlmaLinux/raspberry-pi.
# Built with appliance-creator on an x86_64/aarch64 host with dnf forced to
# armv6hl and qemu-arm (binfmt) for the chroot, see ci/ and ./build.
#
# Boards: Raspberry Pi 1 / Zero / Zero W / Zero 2 W / 2 / 3 / 3+ / CM1 / CM3
# (32-bit kernel.img and kernel7.img). Pi 4 / 5 are not covered.

# Basic setup information
url --mirrorlist="http://ftp.redsleeve.org/pub/el9/mirrors_baseos"
# root password is locked but can be reset by cloud-init later
rootpw --plaintext --lock redsleeve

# Repositories to use: the official RedSleeve mirrorlists. Do not use
# $basearch/$releasever here, livecd-tools would substitute the build host's.
repo --name="baseos"      --mirrorlist="http://ftp.redsleeve.org/pub/el9/mirrors_baseos"
repo --name="appstream"   --mirrorlist="http://ftp.redsleeve.org/pub/el9/mirrors_appstream"
repo --name="raspberrypi" --mirrorlist="http://ftp.redsleeve.org/pub/el9/mirrors_raspberrypi"

# install
keyboard us --xlayouts=us --vckeymap=us
timezone --utc UTC
selinux --enforcing
firewall --enabled --port=22:tcp
network --bootproto=dhcp --device=link --activate --onboot=on
# no cpupower: RedSleeve has no kernel-tools package
services --enabled=sshd,NetworkManager,chronyd,bluetooth
shutdown
# The Raspberry Pi firmware loads the kernel directly, no bootloader is installed
bootloader --location=none
lang en_US.UTF-8

# Disk setup (MBR). Root holds ~1.2 GB of packages plus the 1 GB swapfile;
# 500 + 3000 MiB keeps the raw image small enough for a "4 GB" card.
# cloud-init grows the root partition to the card size at first boot.
clearpart --initlabel --all
part /boot --asprimary --fstype=vfat --size=500 --label=boot --ondisk=sda
part / --asprimary --fstype=ext4 --size=3000 --label=rootfs --ondisk=sda

# Package setup
%packages
@core
# linux-firmware is a single 707 MB package in RedSleeve 9 (no per-vendor
# subpackages to exclude like on AlmaLinux 10). The Broadcom Wi-Fi/Bluetooth
# firmware the Pi needs is added in the '%post --nochroot' section instead.
-linux-firmware
# raspberrypi2-firmware Obsoletes grubby; make sure nothing pulls it in
-grubby
# IBM Power RAID tools, mandatory in RedSleeve's @core but useless here
-iprutils
redsleeve-release
# not part of RedSleeve's @core, needed for 'firewall --enabled'
firewalld
NetworkManager-wifi
wireless-regdb
iw
bluez
chrony
cloud-init
cloud-utils-growpart
e2fsprogs
net-tools
nano
libgpiod-utils
# 32-bit kernels: kernel.img (Pi 1 / Zero / Zero W / CM1) and
# kernel7.img (Pi 2 / 3 / 3+ / Zero 2 W / CM3). No initramfs is used.
raspberrypi-kernel
raspberrypi2-kernel
# GPU firmware and bootloader (bootcode.bin, start*.elf, fixup*.dat) for all
# pre-Pi-4 boards; raspberrypi-firmware ships the same files, one is enough.
raspberrypi2-firmware
%end

%post
# Mandatory README file
cat >/boot/README.txt << EOF
== RedSleeve Linux 9 ==

Default user: redsleeve   password: redsleeve   (sudo without password)

SSH password login is ENABLED on this image so that a headless board can be
reached over the network right after the first boot. Change the password
immediately (passwd), or better: put your SSH public key into the user-data
file on this partition and set 'ssh_pwauth: false' there *before* inserting
the SD card into the Raspberry Pi.

The first boot relabels the filesystem for SELinux and reboots once, then
the second boot resizes the root filesystem, generates SSH host keys and
applies user-data. On a Pi 2 with a class 10 card this takes about 5 + 2
minutes: expect 7-8 minutes before SSH accepts logins. Later boots take
under a minute.

EOF

# Data sources for cloud-init (NoCloud, this partition is labelled CIDATA)
touch /boot/meta-data /boot/user-data

cat >/boot/user-data << "EOF"
#cloud-config
#
# This is the default cloud-init config file for the RedSleeve Raspberry Pi image.
#
# If you want additional customization, refer to cloud-init documentation and
# examples. Please note configurations written in this file will be usually
# applied only once at very first boot.
#
# https://cloudinit.readthedocs.io/en/latest/reference/examples.html

hostname: redsleeve.local

# Password login over SSH is enabled so the board is reachable headlessly.
# Set this to false once you have registered an SSH public key below.
ssh_pwauth: true

users:
  - name: redsleeve
    groups: [ adm, systemd-journal ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    lock_passwd: false
    # password: redsleeve
    passwd: $6$oVTGINRP7VyfjzEb$2dSRKhibupp0cxHrUoLnjmawX51ihNGnH8M0ctr1bZzmpomya13QaUbv4XwfEqsNY3yL5cKOt9C9SHZ9LaMZx1
    # Uncomment below to add your SSH public keys as YAML array
    #ssh_authorized_keys:
      #- ssh-ed25519 AAAAC3Nz...

EOF

# RedSleeve's cloud-init package was built on a RedSleeve host, so its
# /etc/cloud/cloud.cfg was rendered for an "unknown" distro: it selects the
# Ubuntu distro class (locale via apt, service name 'ssh', wrong helper paths).
# Override it with the RHEL-variant settings (module lists are replaced as a
# whole, system_info is merged). Only the NoCloud data source (the CIDATA
# partition) makes sense on a Raspberry Pi; skipping the others avoids network
# probing on slow boards.
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/90-redsleeve-raspberrypi.cfg << "EOF"
# RedSleeve Raspberry Pi image: RHEL-style cloud-init configuration
datasource_list: [ NoCloud, None ]

ssh_deletekeys: true
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']

cloud_init_modules:
  - seed_random
  - bootcmd
  - write_files
  - growpart
  - resizefs
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca_certs
  - rsyslog
  - users_groups
  - ssh
  - set_passwords

cloud_config_modules:
  - ssh_import_id
  - locale
  - yum_add_repo
  - ntp
  - timezone
  - disable_ec2_metadata
  - runcmd

cloud_final_modules:
  - package_update_upgrade_install
  - write_files_deferred
  - ansible
  - scripts_vendor
  - scripts_per_once
  - scripts_per_boot
  - scripts_per_instance
  - scripts_user
  - ssh_authkey_fingerprints
  - keys_to_console
  - install_hotplug
  - phone_home
  - final_message
  - power_state_change

system_info:
  distro: rhel
  default_user:
    name: redsleeve
    lock_passwd: true
    gecos: RedSleeve Cloud User
    groups: [adm, systemd-journal]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
  network:
    renderers: ['network-manager', 'sysconfig', 'eni', 'netplan', 'networkd']
  paths:
    cloud_dir: /var/lib/cloud/
    templates_dir: /etc/cloud/templates/
  ssh_svcname: sshd
EOF

# The same build problem gave cloud-init.service the Debian ordering; make the
# network stage wait for NetworkManager like the RHEL unit does.
mkdir -p /etc/systemd/system/cloud-init.service.d
cat > /etc/systemd/system/cloud-init.service.d/10-redsleeve-networkmanager.conf << EOF
[Unit]
After=NetworkManager.service
After=NetworkManager-wait-online.service
EOF

# Keep the journal across reboots (debugging headless boards)
mkdir -p /var/log/journal
chgrp systemd-journal /var/log/journal
chmod 2755 /var/log/journal

cat > /boot/config.txt << EOF
# This file is provided as a placeholder for user options
# RedSleeve - few default config options
[all]
# enable serial console
enable_uart=1
# drive HDMI even if the monitor was not connected at power-on
hdmi_force_hotplug=1
EOF

# Kernel command line string
cat > /boot/cmdline.txt << EOF
console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait
EOF

# The repo file shipped by redsleeve-release does not include the raspberrypi
# repository; add it so 'dnf update' also picks up kernel and firmware updates.
# (The raspberrypi RPMs are signed with the same key as BaseOS.)
cat > /etc/yum.repos.d/RedSleeve-raspberrypi.repo << EOF
[Redsleeve_raspberrypi]
name=RedSleeve-9 - Raspberry Pi
mirrorlist=http://ftp.redsleeve.org/pub/el9/mirrors_raspberrypi
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redsleeve-9
EOF

# The swapfile is created in the '%post --nochroot' section, not here: mkswap
# rejects a target listed in /proc/swaps, matching the path by exact strcmp, and
# chroot does not rewrite /proc/swaps. A GitHub runner's own swap is /swapfile,
# so the paths collide and mkswap refuses. See NOTES.md finding 10.
cat >> /etc/fstab << EOF
/swapfile	none	swap	defaults	0	0
EOF

# Remove ifcfg-link on pre generated images
rm -f /etc/sysconfig/network-scripts/ifcfg-link

# redsleeve-release does not ship the system-wide 'disable *' preset that
# every EL release package has, so systemd's fallback policy enabled every
# unit the packages installed (rdisc, nftables, chrony-wait, chronyd-restricted,
# arp-ethers, wpa_supplicant, systemd-sysupdate, sshd.socket, ...). The enabled
# sshd.socket conflicts with sshd.service and made systemd drop the sshd start
# job on roughly every second boot. Add the preset, re-apply presets to
# everything and enable the services this image needs (the AlmaLinux 9 set).
cat > /usr/lib/systemd/system-preset/99-default-disable.preset << EOF
disable *
EOF
systemctl preset-all
systemctl enable sshd NetworkManager chronyd bluetooth firewalld auditd crond irqbalance dnf-makecache.timer logrotate.timer
systemctl enable cloud-init-local cloud-init cloud-config cloud-final
systemctl is-enabled sshd.socket || true
ls /etc/systemd/system/multi-user.target.wants/ /etc/systemd/system/sockets.target.wants/ /etc/systemd/system/cloud-init.target.wants/

# rebuild dnf cache
dnf clean all
/bin/date +%Y%m%d_%H%M > /etc/BUILDTIME
echo '%_install_langs C.utf8' > /etc/rpm/macros.image-language-conf
echo 'LANG="C.utf8"' >  /etc/locale.conf
rpm --rebuilddb

# Remove machine-id on pre generated images
rm -f /etc/machine-id
touch /etc/machine-id

#auto relabel SELinux
touch /.autorelabel

%end

%post --nochroot --erroronfail

/usr/sbin/blkid
# loop[0-9]+ : hosts with many loop devices (snap, other builds) go past loop9
LOOPPART=$(cat /proc/self/mounts | /usr/bin/grep -E '^/dev/mapper/loop[0-9]+p[0-9]+ '"$INSTALL_ROOT " | /usr/bin/sed 's/ .*//g')
VFATPART=$(cat /proc/self/mounts | /usr/bin/grep -E '^/dev/mapper/loop[0-9]+p[0-9]+ '"$INSTALL_ROOT"/boot | /usr/bin/sed 's/ .*//g')
echo "Found loop part for PARTUUID $LOOPPART"
BOOTDEV=$(/usr/sbin/blkid $LOOPPART|grep 'PARTUUID="........-02"'|sed 's/.*PARTUUID/PARTUUID/g;s/ .*//g;s/"//g')
echo "no chroot selected bootdev=$BOOTDEV"
if [ -n "$BOOTDEV" ];then
    cat $INSTALL_ROOT/boot/cmdline.txt
    echo sed -i "s|root=/dev/mmcblk0p2|root=${BOOTDEV}|g" $INSTALL_ROOT/boot/cmdline.txt
    sed -i "s|root=/dev/mmcblk0p2|root=${BOOTDEV}|g" $INSTALL_ROOT/boot/cmdline.txt
else
    echo "WARNING: could not determine the PARTUUID of the root partition, keeping root=/dev/mmcblk0p2"
fi

# Everything below must succeed
set -e

# cloud-init: NoCloud data source must have volume label "CIDATA"
#
# This didn't work for some reasons so using fatlabel instead.
#    part /boot --asprimary --fstype=vfat --mkfsoptions="-n CIDATA"
/usr/sbin/fatlabel $VFATPART "CIDATA"

# Broadcom Wi-Fi / Bluetooth firmware for the Pi, taken from the Raspberry Pi OS
# packages firmware-brcm80211 and bluez-firmware (the exact files Raspberry Pi
# OS ships, uncompressed, with the per-model symlinks). Reasons not to use
# linux-firmware: it is a single 707 MB package in RedSleeve 9, it has no
# Raspberry Pi Bluetooth (.hcd) firmware, it lacks the Zero 2 W (43436) files,
# and the Raspberry Pi kernels cannot load its .xz-compressed files at all.
#
# The files are not owned by any RPM. The versions used are recorded in
# /usr/lib/firmware/RASPBERRYPI-FIRMWARE-VERSIONS.
RPI_ARCHIVE="http://archive.raspberrypi.com/debian"
RPI_SUITE="bookworm"
FWTMP=$(mktemp -d)
curl -fsSL "$RPI_ARCHIVE/dists/$RPI_SUITE/main/binary-armhf/Packages.gz" | gzip -dc > "$FWTMP/Packages"
mkdir -p "$INSTALL_ROOT/usr/lib/firmware"
: > "$INSTALL_ROOT/usr/lib/firmware/RASPBERRYPI-FIRMWARE-VERSIONS"
for pkg in firmware-brcm80211 bluez-firmware; do
    stanza=$(awk -v RS= -v p="$pkg" '$1 == "Package:" && $2 == p' "$FWTMP/Packages")
    filename=$(sed -n 's/^Filename: //p' <<< "$stanza")
    sha256=$(sed -n 's/^SHA256: //p' <<< "$stanza")
    version=$(sed -n 's/^Version: //p' <<< "$stanza")
    if [ -z "$filename" ] || [ -z "$sha256" ]; then
        echo "ERROR: $pkg not found in the $RPI_SUITE Packages index" >&2
        exit 1
    fi
    echo "Fetching $pkg $version ($filename)"
    curl -fsSL -o "$FWTMP/$pkg.deb" "$RPI_ARCHIVE/$filename"
    echo "$sha256  $FWTMP/$pkg.deb" | sha256sum -c -
    mkdir "$FWTMP/$pkg"
    (cd "$FWTMP/$pkg" && ar x "../$pkg.deb" && tar -xf data.tar.*)
    # Debian ships /lib/firmware (merged-usr); copy the tree, keeping symlinks
    for d in lib/firmware usr/lib/firmware; do
        if [ -d "$FWTMP/$pkg/$d" ]; then
            cp -a "$FWTMP/$pkg/$d/." "$INSTALL_ROOT/usr/lib/firmware/"
        fi
    done
    echo "$pkg $version" >> "$INSTALL_ROOT/usr/lib/firmware/RASPBERRYPI-FIRMWARE-VERSIONS"
done
rm -rf "$FWTMP"
# Raspberry Pi OS ships some firmware in '-standard' and '-minimal' variants and
# lets dpkg alternatives create the plain name (e.g. cypress/cyfmac43455-sdio.bin,
# the target of all brcmfmac43455-sdio.*.bin symlinks). Pick 'standard' like
# Raspberry Pi OS does by default.
for std in "$INSTALL_ROOT"/usr/lib/firmware/cypress/*-standard.bin; do
    [ -e "$std" ] || continue
    plain="${std%-standard.bin}.bin"
    [ -e "$plain" ] || ln -s "$(basename "$std")" "$plain"
done
if [ -n "$(find "$INSTALL_ROOT/usr/lib/firmware" -xtype l)" ]; then
    echo "ERROR: dangling firmware symlinks:" >&2
    find "$INSTALL_ROOT/usr/lib/firmware" -xtype l >&2
    exit 1
fi
cat "$INSTALL_ROOT/usr/lib/firmware/RASPBERRYPI-FIRMWARE-VERSIONS"
ls -l "$INSTALL_ROOT/usr/lib/firmware/brcm"

ls -l $INSTALL_ROOT/boot
cat $INSTALL_ROOT/boot/cmdline.txt

# Create and initialize the 1 GiB swapfile (512 MB / 1 GB boards). Here rather
# than in the chroot %post: "$INSTALL_ROOT/swapfile" cannot collide with the
# host's /proc/swaps, and this section is --erroronfail. -p 4096 pins the page
# size to the Pi's rather than the build host's.
(umask 077; dd if=/dev/zero of="$INSTALL_ROOT/swapfile" bs=1M count=1024)
/usr/sbin/mkswap -p 4096 -L "_swap" "$INSTALL_ROOT/swapfile"
chmod 0600 "$INSTALL_ROOT/swapfile"
chown 0:0 "$INSTALL_ROOT/swapfile"

# The file is zeros apart from that 4 KiB header, so a refused write still
# leaves the right size and block count and only fails on the board with
# 'swapon: read swap header failed'. Check the signature, not the file.
if [ "$(dd if="$INSTALL_ROOT/swapfile" bs=1 skip=4086 count=10 status=none)" != "SWAPSPACE2" ]; then
    echo "ERROR: /swapfile has no SWAPSPACE2 signature after mkswap" >&2
    od -A d -t x1 -N 32 "$INSTALL_ROOT/swapfile" >&2
    exit 1
fi
echo "swapfile: ok, SWAPSPACE2 signature present"

%end
