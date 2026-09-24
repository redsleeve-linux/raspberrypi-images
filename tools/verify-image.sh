#!/bin/bash
# Verify a built RedSleeve Raspberry Pi raw image without hardware (run as root on Linux).
# Usage: sudo tools/verify-image.sh rpi-image/<image>.raw
set -u
IMG=${1:?usage: $0 <image.raw>}
FAIL=0
MNT=$(mktemp -d)
mkdir -p "$MNT/boot" "$MNT/root"
LOOP=$(losetup -Pf --show "$IMG") || { echo "losetup failed"; exit 1; }
sleep 1
cleanup() { umount "$MNT/boot" 2>/dev/null; umount "$MNT/root" 2>/dev/null; losetup -d "$LOOP"; rm -rf "$MNT"; }
trap cleanup EXIT
R="$MNT/root"; B="$MNT/boot"
echo "=== image ==="; ls -l "$IMG"
echo "=== partition table ==="; fdisk -l "$LOOP" | grep -E '^Disklabel|^/dev'
echo "=== blkid (boot must be CIDATA) ==="; blkid "${LOOP}p1" "${LOOP}p2"
mount "${LOOP}p1" "$B" || exit 1
mount -o ro "${LOOP}p2" "$R" || exit 1
echo "=== /boot ==="; ls "$B" | grep -vE '\.dtb$' | tr '\n' ' '; echo; echo "dtb: $(ls "$B"/*.dtb | wc -l)  overlays: $(ls "$B/overlays" | wc -l)"
echo "=== cmdline.txt ==="; cat "$B/cmdline.txt"
echo "=== config.txt ==="; grep -vE '^#|^$' "$B/config.txt"
echo "=== rootfs arch ==="; file "$R/usr/bin/bash" | cut -c1-80; cat "$R/etc/rpm/platform"; grep PRETTY "$R/etc/os-release"
echo "=== rpm db ==="; rpm -qa --root "$R" --dbpath /var/lib/rpm --qf '%{name}.%{arch}\n' 2>/dev/null | sort > /tmp/rpmlist.txt
echo "packages: $(wc -l < /tmp/rpmlist.txt)"; sed 's/.*\.//' /tmp/rpmlist.txt | sort | uniq -c | tr '\n' ' '; echo
grep -E '^(raspberrypi|redsleeve-release|cloud-init|cloud-utils-growpart|linux-firmware|grubby|firewalld|NetworkManager-wifi|bluez|chrony)\.' /tmp/rpmlist.txt | tr '\n' ' '; echo
echo "=== kernels ==="; ls "$R/lib/modules"
echo "=== firmware ==="; cat "$R/usr/lib/firmware/RASPBERRYPI-FIRMWARE-VERSIONS"
echo "brcm files: $(ls "$R/usr/lib/firmware/brcm" | wc -l)  xz files: $(find "$R/usr/lib/firmware" -name '*.xz' | wc -l)  dangling symlinks: $(find "$R/usr/lib/firmware" -xtype l | wc -l)"
ls "$R/usr/lib/firmware/brcm" | grep -cE 'BCM4343|BCM4345' | sed 's/^/hcd files: /'
echo "=== swap / fstab ==="; ls -l "$R/swapfile" | awk '{print $5, $9}'; file "$R/swapfile" | cut -c1-70; cat "$R/etc/fstab"
# A swapfile is zeros apart from mkswap's 4 KiB header, so a lost header is
# invisible in the size and the block count: check the signature itself.
# Without it the board only ever says 'swapon: read swap header failed'.
if [ "$(dd if="$R/swapfile" bs=1 skip=4086 count=10 status=none)" = "SWAPSPACE2" ]
then echo "swap signature: ok"
else echo "swap signature: *** MISSING *** (/swapfile will not activate on the board)"; FAIL=1
fi
echo "=== first-boot state ==="; ls "$R/.autorelabel" 2>&1; echo "machine-id bytes: $(wc -c < "$R/etc/machine-id")  ssh host keys: $(ls "$R/etc/ssh" | grep -c host_)"
echo "=== enabled units ==="; find "$R/etc/systemd/system" -type l | sed "s#$R/etc/systemd/system/##" | grep -E 'wants/' | sort | tr '\n' ' '; echo
echo "presets: $(ls "$R/usr/lib/systemd/system-preset/" | tr '\n' ' ')"
echo "=== selinux ==="; grep -E '^SELINUX=' "$R/etc/selinux/config"; ls -l "$R/etc/selinux/targeted/policy/policy.33" | awk '{print $5, $9}'; ls -d "$R/var/lib/selinux/targeted/tmp" 2>/dev/null && echo "WARNING: leftover semanage sandbox"
echo "=== cloud-init ==="; ls "$R/etc/cloud/cloud.cfg.d/"; grep -E '^  distro:|ssh_svcname|datasource_list' "$R/etc/cloud/cloud.cfg.d/90-redsleeve-raspberrypi.cfg"
echo "=== repos ==="; ls "$R/etc/yum.repos.d/"
echo "=== ld.so.cache entries: $(ldconfig -p -C "$R/etc/ld.so.cache" 2>/dev/null | grep -c '=>')  (.so files in /usr/lib: $(find "$R/usr/lib" -maxdepth 1 -type f -name 'lib*.so*' | wc -l)) ==="
echo "=== sizes ==="; df -h "$R" "$B" | tail -2
if [ "$FAIL" -eq 0 ]
then echo "=== verify done: OK ==="
else echo "=== verify done: FAILED (see *** lines above) ==="
fi
exit "$FAIL"
