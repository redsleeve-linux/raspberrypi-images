# RedSleeve 9 Raspberry Pi image

Builds a [RedSleeve Linux 9](https://redsleeve.org) image for the 32-bit Raspberry Pi boards.
RedSleeve is a community rebuild of Enterprise Linux 9 for `armv6hl`, which covers the boards
the 64-bit AlmaLinux images no longer can: the Pi 1, Zero, Zero W, Zero 2 W, Pi 2 and Pi 3.

The build approach is borrowed from the [AlmaLinux Raspberry Pi image](https://github.com/AlmaLinux/raspberry-pi)
repository: one kickstart file, `appliance-creator`, cloud-init for first-boot configuration.

## Supported boards

| Board | Kernel | Wi-Fi / Bluetooth |
|-|-|-|
| Pi 1 A/B/A+/B+, Compute Module 1 | `kernel.img` | n/a |
| Pi Zero, Zero W | `kernel.img` | BCM43430 |
| Pi Zero 2 W | `kernel7.img` | BCM43436 / 43430B0 |
| Pi 2 | `kernel7.img` | n/a |
| Pi 3 B, Compute Module 3 | `kernel7.img` | BCM43430 |
| Pi 3 A+/B+ | `kernel7.img` | BCM43455 |

Not covered: Pi 4, 400, 5. Use AlmaLinux or RockyLinux if wanting EL based distribution

## Quick start

1. Flash `RedSleeve-RaspberryPi-mbr-<release>-<date>.armv6hl.raw.xz` to an SD card (4 GB or larger)
   with Raspberry Pi Imager, Fedora Media Writer, Balena Etcher or `xzcat ... | dd`.
2. Optional: mount the first partition (`CIDATA`) and edit `user-data` (hostname, SSH keys, password),
   or add a `network-config` file for Wi-Fi (see below).
3. Boot. The first boot relabels the filesystem for SELinux and reboots once; the second boot grows
   the root partition, generates the SSH host keys and applies `user-data`.
4. Log in on the console, the serial console (`enable_uart=1`, 115200 baud) or over SSH.

First-boot timing measured on a Pi 2 with a class 10 card:

| Phase | Time |
|-|-|
| Power-on to SELinux relabel done and automatic reboot | about 5 min |
| Second boot: filesystem resize, SSH host keys, cloud-init | about 2 min |
| Total until SSH accepts logins | 7 to 8 min |
| Every later boot to SSH | under 1 min |

The Pi is not reachable on the network during the relabel. Slower boards (Pi 1, Zero) take longer.

Defaults:

| | |
|-|-|
| User / password | `redsleeve` / `redsleeve` (sudo without password, root locked) |
| Hostname | `redsleeve` |
| Network | DHCP on Ethernet via NetworkManager |
| SSH | enabled, password login **on** so a headless board can be reached; change the password or switch to keys |
| Swap | 1 GiB `/swapfile` |
| SELinux | enforcing |
| Firewall | firewalld, only port 22 open |

### Wi-Fi at first boot

Put a `network-config` file next to `user-data` on the `CIDATA` partition:

```yaml
version: 2
wifis:
  wlan0:
    dhcp4: true
    access-points:
      "MyNetwork":
        password: "MyPassword"
```

### Where things come from

- Packages: RedSleeve 9 BaseOS, AppStream and the `raspberrypi` repository (kernels, GPU firmware).
  All repositories are configured on the image for `dnf update`.
- Broadcom Wi-Fi/Bluetooth firmware: the Raspberry Pi OS packages `firmware-brcm80211` and
  `bluez-firmware`, unpacked at build time into `/usr/lib/firmware` (versions recorded in
  `/usr/lib/firmware/RASPBERRYPI-FIRMWARE-VERSIONS`). They are not owned by an RPM. RedSleeve's own
  `linux-firmware` is a single 707 MB package without the Pi Bluetooth files, and the Pi kernels
  cannot load its `.xz`-compressed firmware anyway.
- `vcgencmd` and the rest of `raspberrypi-userland` are not available for RedSleeve.

## Building

Everything runs inside a privileged AlmaLinux 9 container; the host only needs Docker (or Podman
run as root) and a kernel with loop devices, device-mapper and `binfmt_misc`. Linux, a Fedora or
Ubuntu WSL2 instance, or Docker Desktop on WSL2 all work; keep the checkout on the Linux filesystem.

```sh
./build                     # builds kickstart/RedSleeve-9-RaspberryPi-console-mbr.armv6hl.ks
ls rpi-image/               # <variant>-<date>.armv6hl.raw and .raw.xz, plus logs
```

The script registers the `qemu-arm` binfmt handler on the host (`tonistiigi/binfmt`), builds the
container from `ci/Dockerfile` and runs `ci/appliance-creator.sh` in it. A build takes a few minutes
on a fast machine (about 3 minutes on a 32-core WSL2 host): dnf and rpm run natively, only the rpm
scriptlets and the kickstart `%post` run under qemu-arm emulation.

The GitHub Actions workflow `.github/workflows/build-rpi-redsleeve.yml` does the same on an
`ubuntu-24.04` runner and uploads the image as a workflow artifact. Pushing a version tag also
publishes it as a GitHub release; see `RELEASE.md`.

### How the cross-architecture build works

There is no armv6hl build host, so the image is built the way `mock --forcearch` works:

- `dnf` and `rpm` run natively in the container. A small patch to livecd-tools
  (`ci/patches/dnfinst-forcearch.patch`) makes them resolve and install `armv6hl` packages when
  `LIVECD_FORCEARCH=armv6hl` is set.
- The rpm scriptlets and the kickstart `%post` run chroot'ed into the install root. They are ARM
  binaries, executed through `binfmt_misc` and `qemu-arm` registered on the host kernel with the
  `F` flag.
- Downloads happen in `%post --nochroot` on the host side, because livecd-tools gives the chroot
  no network configuration.
- The root filesystem is created without ext4 `dir_index` and re-indexed after the build
  (`ci/patches/fs-mkfs-opts.patch`, `LIVECD_MKFS_EXT_OPTS`). 32-bit programs without large-file
  support (for example libsemanage, run by the SELinux policy scriptlet) otherwise fail with
  `Value too large for defined data type` when reading hashed directories under qemu-user.

`ci/patches/fs.py.patch` is the same lazy-unmount fix the AlmaLinux workflow applies.

### Checking an image without hardware

```sh
sudo losetup -Pf --show rpi-image/<image>.raw      # e.g. /dev/loop0
sudo mount /dev/loop0p1 /mnt/boot; sudo mount /dev/loop0p2 /mnt/root
ls /mnt/boot                                       # kernel.img kernel7.img *.dtb overlays/ cmdline.txt user-data ...
grep root= /mnt/boot/cmdline.txt                   # root=PARTUUID=xxxxxxxx-02
file /mnt/root/bin/bash                            # ELF 32-bit LSB ... ARM, EABI5
cat /mnt/root/etc/rpm/platform                     # armv6hl-redhat-linux-gnu
rpm -qa --root /mnt/root | sort                    # no linux-firmware, no grubby
find /mnt/root/usr/lib/firmware -xtype l           # must print nothing
ls -l /mnt/root/swapfile                           # 1 GiB
```

## RedSleeve package quirks this image works around

Found while testing on a Pi 2; all are handled in the kickstart `%post` and worth reporting upstream.

- **cloud-init thinks it is Ubuntu.** RedSleeve's cloud-init (a rebuild of Rocky's package) was
  built on a RedSleeve host, so its config template rendered the "unknown distro" fallback:
  `distro: ubuntu`, default user `linux`, Debian unit ordering. Symptoms: the `locale` module tries
  `apt`, cloud-init looks for a service called `ssh`, the fingerprint helper path is wrong. The image
  overrides this with `/etc/cloud/cloud.cfg.d/90-redsleeve-raspberrypi.cfg` (RHEL settings) and a
  `cloud-init.service` drop-in.
- **No `disable *` preset.** `redsleeve-release` lacks the system-wide
  `99-default-disable.preset` every EL release package ships, so every unit a package installs ends
  up enabled (`rdisc`, `nftables`, `chrony-wait`, `chronyd-restricted`, `arp-ethers`,
  `wpa_supplicant`, `systemd-sysupdate`, `fstrim.timer`, `sshd.socket`, ...). Consequences seen on a
  Pi 2:
  - **sshd randomly not started at boot** (about half of all boots). `sshd.socket` and `sshd.service`
    were both enabled and declare `Conflicts=` on each other, so every boot transaction contained
    conflicting start/stop jobs for both; systemd resolves that in hash order and, depending on the
    order, silently drops both start jobs. Nothing is logged at normal log levels, the boot still
    reaches `multi-user.target`, and `systemctl start sshd` works fine afterwards.
  - `rdisc.service` fails on every boot (`socket: Operation not permitted`, an EL9 iputils packaging
    bug nobody sees because the unit is normally disabled); `chronyd-restricted` conflicts with
    `chronyd`; `chrony-wait` holds `multi-user.target` back until NTP has synced.

  The image adds the preset, runs `systemctl preset-all` and enables the services it needs
  explicitly, which yields the same unit set as an AlmaLinux 9 minimal install.
- **`linux-firmware`** is a single 707 MB package without the Pi Bluetooth files, and the Pi kernels
  cannot load its `.xz`-compressed firmware; see the firmware section above.
- **Journal** storage is enabled (`/var/log/journal`) so the logs of a failed boot survive a
  power cycle.

## Layout

```
build                        local Docker-based build script
kickstart/                   the kickstart file(s)
ci/Dockerfile                build container (AlmaLinux 9 + appliance-tools from EPEL)
ci/appliance-creator.sh      entrypoint: binfmt check, loop nodes, appliance-creator
ci/patches/                  livecd-tools patches applied in the container
tools/verify-image.sh        offline checklist for a built .raw (loop-mount)
tools/rapid-boot-test.sh     reboot a Pi N times and health-check each boot over SSH
tools/wsl-build.sh           build from a Windows checkout inside WSL2
.github/workflows/           GitHub Actions build and release
RELEASE.md                   maintainer notes: tag scheme, cutting a release
NOTES.md                     work log, findings
```

## Credits

- The [AlmaLinux Raspberry Pi image](https://github.com/AlmaLinux/raspberry-pi) project for the
  kickstart and workflow this is based on.
