#!/bin/bash
# vim: ts=4 sw=4 expandtab
#
# Runs appliance-creator for a RedSleeve (armv6hl) kickstart inside the build
# container (see Dockerfile).
#
# Usage: appliance-creator.sh <kickstart> <image-name>
#   kickstart  : path relative to /work, e.g. kickstart/RedSleeve-9-RaspberryPi-console-mbr.armv6hl.ks
#   image-name : base name of the resulting image (without extension)
#
# Results go to /rpi-image, the dnf package cache to /work/cache (bind-mount both).

set -euo pipefail

KS=${1:?usage: $0 <kickstart> <image-name>}
NAME=${2:?usage: $0 <kickstart> <image-name>}
ARCH=${LIVECD_FORCEARCH:-armv6hl}
RESULTDIR=${RESULTDIR:-/rpi-image}
CACHEDIR=${CACHEDIR:-/work/cache}

# qemu-arm must be registered on the host kernel with the 'F' (fix binary) flag,
# otherwise armv6hl binaries cannot be executed from inside the chroot.
# binfmt_misc is not mounted in a fresh container; mount it to look at the
# host's registrations (works in a privileged container).
BINFMT=/proc/sys/fs/binfmt_misc/qemu-arm
if [ ! -e "$BINFMT" ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi
if [ -r "$BINFMT" ]; then
    if ! grep -q '^enabled' "$BINFMT" || ! grep -qE '^flags:.*F' "$BINFMT"; then
        echo "ERROR: the qemu-arm binfmt handler is disabled or not registered with the 'F' flag:" >&2
        cat "$BINFMT" >&2
        echo "       On the host run: docker run --privileged --rm tonistiigi/binfmt --install arm" >&2
        exit 1
    fi
    echo "==> qemu-arm binfmt handler: $(grep '^flags' "$BINFMT")"
else
    echo "WARNING: cannot see the binfmt_misc registrations from inside the container;" >&2
    echo "         assuming qemu-arm is registered on the host with the 'F' flag." >&2
fi

# Loop device nodes: the container only sees the nodes that existed when it
# started, and 'losetup -f' may pick a high number on hosts with many loop
# devices in use (snap, other builds).
[ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237
for i in $(seq 0 63); do
    [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i
done

# There is no udev inside the container: let libdevmapper create the
# /dev/mapper/loopNpM nodes itself.
export DM_DISABLE_UDEV=1
export LIVECD_FORCEARCH=$ARCH

# 32-bit programs that read directories without large-file support (glibc's
# non-LFS readdir, used e.g. by libsemanage) get EOVERFLOW on ext4 hashed
# directories when they run under qemu-user, because the kernel hands the
# 64-bit qemu process 64-bit directory offsets. Build the root filesystem
# without dir_index (linear directories, small offsets) and put the index
# back once the image is finished (see below). Needs fs-mkfs-opts.patch.
export LIVECD_MKFS_EXT_OPTS="-O ^dir_index"

mkdir -p "$RESULTDIR" "$CACHEDIR"

echo "==> appliance-creator: kickstart=$KS name=$NAME arch=$ARCH"
appliance-creator \
    -c "$KS" \
    -d -v --logfile "$RESULTDIR/$NAME.log" \
    --cache "$CACHEDIR" --no-compress \
    -o "$RESULTDIR" --format raw --name "$NAME" | \
    tee "$RESULTDIR/$NAME.log.2"

# Rename image to avoid 'sda' in the file name (same as the AlmaLinux workflow)
mv -f "$RESULTDIR/$NAME/$NAME-sda.raw" "$RESULTDIR/$NAME.raw"

# Re-enable dir_index on the root filesystem and build the directory indexes
# (e2fsck -D). e2fsck exits 1 when it modified the filesystem, which is expected.
echo "==> Re-enabling dir_index on the root filesystem"
LOOPDEV=$(losetup -f --show "$RESULTDIR/$NAME.raw")
kpartx -a "$LOOPDEV"
ROOTPART="/dev/mapper/$(basename "$LOOPDEV")p2"
tune2fs -O dir_index "$ROOTPART"
e2fsck -fyD "$ROOTPART" || [ $? -le 1 ]
tune2fs -l "$ROOTPART" | grep -E '^Filesystem features'
kpartx -d "$LOOPDEV"
losetup -d "$LOOPDEV"
if [ -f "$RESULTDIR/$NAME/$NAME.xml" ]; then
    sed -i 's/-sda//g' "$RESULTDIR/$NAME/$NAME.xml"
    mv -f "$RESULTDIR/$NAME/$NAME.xml" "$RESULTDIR/$NAME.xml"
fi
rmdir "$RESULTDIR/$NAME" 2>/dev/null || true

echo "==> done"
ls -l "$RESULTDIR"
