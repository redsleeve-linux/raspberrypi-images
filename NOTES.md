# Work log and state (2026-09-22)

This is the "memory" of how the image was built and debugged, so work can continue later.

## Current state

- Image builds in ~3 min (Fedora WSL2 + Docker), verified offline, boots on a Pi 2.
- 15/15 rapid reboots good on the fixed image: sshd started by the boot transaction at 44-55 s,
  zero failed units, cloud-init done. Before the fixes: 3 of 8 and 4 of 6 boots had no sshd.
- Measured first boot on a Pi 2, class 10 card: ~5 min to relabel + automatic reboot, ~2 min second
  boot (resize, host keys, cloud-init), 7-8 min until SSH accepts logins. Later boots < 1 min.
- Latest deliverable: `rpi-image/RedSleeve-9-RaspberryPi-console-mbr-20260922-231844.armv6hl.raw.xz`
  (identical to the tested card apart from the `/boot/README.txt` wording).
- Repo is `git init`ed on `main`, nothing committed yet. Workflow `.github/workflows/build-rpi-redsleeve.yml`
  is written but has never run on GitHub. It now also publishes a GitHub release on a version tag
  (`9.8-20260923`, see `RELEASE.md`); the S3 and Mattermost steps inherited from AlmaLinux are gone,
  since the target repo <https://github.com/redsleeve-linux/raspberrypi-images> is public and
  release downloads are free and unmetered. Lints clean under actionlint 1.7.12 + shellcheck.

## Next steps

1. Re-cut the `9.8-20260923` tag once the swapfile fix (finding 10) is pushed. The first CI run
   (2026-09-23, run 35899835661) built the image in **8m26s** on a 4-core runner - far under the
   240 min timeout - and then failed at *Verify the image* on the empty swapfile, exactly as the
   gate is meant to. No release was created, so only the tag needs deleting and re-pushing.
   Still worth doing once: compare a CI image against a local build (same package set,
   `tools/verify-image.sh`) and boot-test before tagging.
2. Post the findings on https://github.com/redsleeve-linux/raspberrypi/issues/2 (draft below).
3. Optional follow-ups: package the two Raspberry Pi OS firmware debs as a noarch RPM so dnf owns the
   files; `chronyd -s` or a fake-hwclock equivalent for nicer pre-NTP timestamps; Wi-Fi/Bluetooth on a
   Pi 3/Zero W has not been exercised yet (firmware files are in place, `brcmfmac`/`hci_uart` untested).

## Decisions taken with the user

- Boards: Pi 0/1/2/3 family only (32-bit `kernel.img` + `kernel7.img`); no Pi 4/5.
- SSH password login enabled by default (`redsleeve`/`redsleeve`), README tells users to change it.
- Firmware extracted at build time from Raspberry Pi OS debs (not rpm-owned).
- Standalone repo `C:\repo\redsleeve` rather than inside the AlmaLinux repo.
- Docs excluded? No: `%packages` keeps docs (LICENCE files), size trimming only via firmware.

## Findings in order (what went wrong and how it was found)

1. **Build container**: `curl` conflicts with the base image's `curl-minimal` (dropped `curl`).
   `binfmt_misc` must be mounted inside the privileged container before the qemu-arm check can see it.
2. **Firmware deb**: the RPi `firmware-brcm80211` deb ships `cypress/cyfmac43455-sdio-{standard,minimal}.bin`
   and relies on dpkg alternatives for `cyfmac43455-sdio.bin`; the kickstart recreates that symlink
   (standard variant, priority 50 in the deb's postinst).
3. **EOVERFLOW under qemu**: `selinux-policy-targeted`'s `%post` (`semodule`) failed with
   "Value too large for defined data type" because 32-bit non-LFS `readdir` gets 64-bit ext4 htree
   offsets when the process is a 64-bit qemu. Fixed by building the root fs with `-O ^dir_index`
   (`ci/patches/fs-mkfs-opts.patch`, `LIVECD_MKFS_EXT_OPTS`) and `tune2fs -O dir_index` + `e2fsck -fD`
   afterwards in `ci/appliance-creator.sh`.
4. **cloud-init runs as Ubuntu**: RedSleeve's cloud-init (Rocky 24.4 rebuilt on a RedSleeve host) has
   `distro: ubuntu` in `/etc/cloud/cloud.cfg` because the Rocky spec renders templates in `%py3_install`
   without `--distro` and `ID=redsleeve` is unknown to cloud-init's `_get_variant`. Symptoms: `locale`
   module tries apt (cloud-config.service fails), service `ssh` instead of `sshd`, helper path wrong,
   Debian unit ordering. Fix in the image: `/etc/cloud/cloud.cfg.d/90-redsleeve-raspberrypi.cfg`
   (RHEL module lists, `system_info.distro: rhel`, `ssh_svcname: sshd`, NM renderer first) and a
   `cloud-init.service` drop-in ordering after NetworkManager-wait-online.
5. **Every unit enabled**: `redsleeve-release.spec` installs `99-default-disable.preset` (`disable *`)
   only into `user-preset/` and `90-default-user.preset` into `system-preset/` (destinations swapped;
   Rocky installs the disable preset into both). Result: `sshd.socket`, `rdisc`, `nftables`,
   `chrony-wait`, `chronyd-restricted`, `arp-ethers`, `wpa_supplicant`, `systemd-sysupdate*`,
   `fstrim.timer` all enabled. Fix in the image: write the preset, `systemctl preset-all`, then enable
   sshd NetworkManager chronyd bluetooth firewalld auditd crond irqbalance dnf-makecache.timer
   logrotate.timer and the four cloud-init services (their `Wants` links are not shipped by the RPM).
6. **sshd missing on ~50% of boots** (the hard one): the persisted journal + audit log showed the boot
   reaching multi-user without ever attempting `sshd.service`, no failure, no cycle message. Debug
   logging (`systemd.log_level=debug`, kmsg target) showed the sshd job was never in the transaction
   at run time, while `sshd-keygen.target` (pulled only by sshd's `Wants=`) did start, i.e. the job
   existed at build time and was dropped during transaction repair. `chronyd-restricted` vs `chronyd`
   was a red herring (disabling it: still 3/8 bad). Cause: `sshd.socket` enabled + `Conflicts=sshd.service`
   → mutually conflicting start/stop job pairs; systemd resolves them in hash order and one outcome
   drops both starts. Disabling `sshd.socket`: 8/8 and then 15/15 good.
7. **rdisc.service fails** every boot: unit has `PrivateUsers=yes` + raw socket (EL9 iputils bug,
   invisible on AlmaLinux because the unit is disabled there). Gone with the preset fix.
8. **Journald stalls** 30-40 s on first boots (SD card I/O, fstrim.timer firing) made journal timestamps
   misleading; `systemctl show -p *TimestampMonotonic` is the reliable source.
9. HDMI: firmware probes the display only at power-on; `hdmi_force_hotplug=1` added to config.txt.
10. **Swapfile empty when built on GitHub Actions** (local builds were fine, so this only appeared once
    CI produced an image): the board reported `swapon: /swapfile: read swap header failed` and
    `swapfile.swap` failed on every boot, while the file looked perfect - exactly 1 GiB, 5 extents, all
    blocks allocated, correct SELinux label, no AVCs. A swapfile is zeros apart from mkswap's 4 KiB
    header, so the header is the only part whose loss is visible. Cause, from the CI log:
    `mkswap: error: /swapfile is mounted; will not make swapspace`, from the chroot `%post`. The
    chroot `%post` is not `--erroronfail`, so the build shipped the broken image silently.

    **Mechanism, settled from the util-linux 2.37 source** (`disk-utils/mkswap.c`, `lib/ismounted.c`):
    `mkswap.c:582` calls `is_mounted(devname)` unconditionally - *before* `--force` is consulted, so
    `-f` does not help. `is_mounted` -> `check_mount_point` tries `is_swap_device()` **first**, and
    for a regular file that is the only thing that can set `MF_MOUNTED` (the mtab path matches mount
    *sources*, and a swapfile is never one). `is_swap_device()` reads `/proc/swaps` and does a plain
    `strcmp(buf, file)` on the first field of each line: an exact string compare, no canonicalisation,
    no stat/dev comparison. So that error is only reachable when `/proc/swaps` holds a line beginning
    exactly `/swapfile`.

    `/proc/swaps` is a kernel interface: chroot does not rewrite it and it is not namespaced (verified
    - inside a container it still shows the WSL host's `/dev/sdc`). Inside the chroot the image's
    swapfile is at the path `/swapfile`, and on a runner whose *own* swap is `/swapfile` the two
    strings collide byte for byte. Nothing is written; the file stays 1 GiB of zeros.

    **The runner enables `/swapfile` part-way through the job**, which is why this looked intermittent
    at first. Run 35908706867 printed `/proc/swaps` twice and caught it:

    ```
    19:23:14  (end of 'Free up disk space')   Filename Type Size Used Priority     <- empty
    19:24:19  (start of 'Create image')       /swapfile  file  3145724  0  -2      <- 3 GiB, active
    ```

    So `/swapfile` *is* active swap by the time the build runs, and the collision is the normal case
    on a GitHub runner rather than bad luck. Two earlier readings of "empty" were measured in *Free up
    disk space*, i.e. in the window before the runner's swap comes up, and led to two wrong
    conclusions recorded here and then withdrawn: first that the runner had no `/swapfile` at all,
    then that the runner *image version* decided it (run 35906968297 reused the failing run's image
    20260907.300.1 and still passed - because the kickstart fix was already in, not because that VM
    lacked swap). Measure at the moment mkswap runs, not at job start.

    What activates it mid-job is not identified and does not matter here; the 3 GiB size and the
    timing fit a systemd unit on the VM finishing shortly after the job starts. Local WSL builds
    always worked because WSL swaps on `/dev/sdc`, so there is no string to collide with.

    Consequence for the upstream report: if `/swapfile` is reliably active during Actions builds, an
    Actions-built AlmaLinux image would have an empty swapfile **every time**, not occasionally. Fixed by creating the swapfile in the `%post --nochroot --erroronfail` section as
    `$INSTALL_ROOT/swapfile` (no path collision, runs natively, failures abort), plus a SWAPSPACE2
    signature assert there and in `tools/verify-image.sh`, which now exits non-zero.
    **The AlmaLinux kickstarts (8, 9 and 10) do the same `dd` + `mkswap /swapfile` in their chroot
    `%post` with no check afterwards**, and they build on the same runners, so their published images
    are very likely shipping an empty swapfile too - silently, since nothing in their build looks at
    the result and a Pi with no swap simply runs without it. Verify before reporting: download a
    released image, loop-mount it and run
    `dd if=<root>/swapfile bs=1 skip=4086 count=10` - it should print `SWAPSPACE2`, and `file` should
    say "Linux/i386 swap file" rather than "data". This one is not RedSleeve-specific.

## Upstream report draft (redsleeve-linux/raspberrypi#2)

> I built a RedSleeve 9 image for the 32-bit Pis (kickstart + appliance-creator, same approach as the
> AlmaLinux images) and it boots on a Pi 2. Two packages needed workarounds on the board:
>
> **`redsleeve-release`**: the system-wide `99-default-disable.preset` is missing (only the user-preset
> copy is installed), so every unit a package installs ends up enabled: `sshd.socket`, `rdisc`, `nftables`,
> `chrony-wait`, `chronyd-restricted`, `arp-ethers`, `wpa_supplicant`, `systemd-sysupdate*`, `fstrim.timer`, ...
> Effects I saw: `sshd.socket` conflicts with `sshd.service`, and systemd silently drops the sshd start job
> on about every second boot (nothing listening on port 22 until `systemctl start sshd`); `rdisc.service`
> fails every boot; `chrony-wait` delays `multi-user.target` until NTP syncs.
> What I had to do: add `/usr/lib/systemd/system-preset/99-default-disable.preset` (`disable *`) in the
> kickstart, run `systemctl preset-all` and enable the services I need explicitly.
>
> **`cloud-init`** (rebuild of Rocky's 24.4-8.el9_8.1.rocky.0.1): the templates are rendered during the
> build from the build host's `/etc/os-release`, and `ID=redsleeve` is unknown to cloud-init, so the shipped
> `cloud.cfg` says `distro: ubuntu` (default user `linux`) and the unit gets the Debian ordering. cloud-init
> then runs as Ubuntu: the `locale` module tries `apt` (cloud-config.service fails), it looks for a service
> named `ssh` instead of `sshd`, and it looks for helpers in the wrong path.
> What I had to do: a `cloud.cfg.d` drop-in with the RHEL settings (`distro: rhel`, `ssh_svcname: sshd`,
> RHEL module lists) plus a `cloud-init.service` drop-in ordering it after NetworkManager. Building with
> `--distro rhel` would avoid it.

## Local environment (delete before publishing if you like)

- Windows box, repo at `C:\repo\redsleeve`; Fedora 43 WSL2 (`wsl -d Fedora -u root`) with Docker CE.
  `docker.service` is not enabled and WSL idles out between commands, so `tools/wsl-build.sh` starts it.
  Build copy lives in `/root/rs-build`, results in `/root/rs-build/rpi-image`.
- Test Pi: Pi 2 Model B, DHCP address 192.168.2.217, user `redsleeve`/`redsleeve`; `sshpass` is
  installed in the WSL Fedora for password SSH (key auth is not set up for the WSL root user).
- The AlmaLinux repo checkout at `C:\repo\alma\raspberry-pi` was only used as the reference; it is clean.

## Reference facts gathered while researching

- RedSleeve el9 mirror: `https://www.mirrorservice.org/sites/ftp.redsleeve.org/pub/el9/`; official mirrorlists
  `http://ftp.redsleeve.org/pub/el9/mirrors_{baseos,appstream,crb,epel,raspberrypi}`; BaseOS has comps.
  Pi kernels: `raspberrypi-kernel` (Pi 0/1), `raspberrypi2-kernel` (Pi 2/3), `raspberrypi4/5-kernel`
  (64-bit kernel8.img, noarch); `raspberrypi2-firmware` covers all pre-Pi-4 boards. RPMs are signed with
  `RPM-GPG-KEY-redsleeve-9` (same key as BaseOS), so the on-device raspberrypi repo has `gpgcheck=1`.
- Pi kernel defconfigs do not set `CONFIG_FW_LOADER_COMPRESS`; SELinux is compiled in and on by default.
- appliance-tools: with no grub package it only warns; `bootloader --location=none` skips grub.conf.
  livecd-tools gives the chroot no `resolv.conf`, so downloads happen in `%post --nochroot`.
- dnf resolution dry-run trick from the container: `dnf --assumeno --forcearch=armv6hl --installroot=/tmp/x
  --releasever=9 --repofrompath=rs-baseos,<url> ... install <pkgs>` (repo ids must not clash with the
  container's own `baseos`).
