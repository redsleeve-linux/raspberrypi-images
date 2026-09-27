# Build container for the RedSleeve 9 (armv6hl) Raspberry Pi image.
#
# dnf and rpm run natively in this AlmaLinux 9 container (x86_64 or aarch64);
# the armv6hl rpm scriptlets and the kickstart %post run inside the install
# root through binfmt_misc + qemu-arm. The handler must be registered on the
# *host* kernel with the 'F' (fix binary) flag before this container runs:
#
#   docker run --privileged --rm tonistiigi/binfmt --install arm
#
# The container itself must run with --privileged (loop devices, device-mapper,
# chroot). Build context is the repository root:
#
#   docker build -t rs-appliance-creator -f ci/Dockerfile .
#
# Keep the base on AlmaLinux 9: its rpm (4.16, sqlite db) matches RedSleeve 9's.
FROM almalinux:9

RUN dnf -y -q update \
 && dnf -y -q install epel-release \
 && dnf -y -q install appliance-tools dnf-plugins-core patch xz cpio binutils tar gzip \
                      dosfstools kpartx parted e2fsprogs util-linux \
 && dnf -y -q clean all

# 1) fs.py.patch: lazy-umount /sys at the end of the build (same as the AlmaLinux workflow)
# 2) dnfinst-forcearch.patch: LIVECD_FORCEARCH makes dnf resolve/install a foreign
#    architecture (armv6hl) the way 'mock --forcearch' does
# 3) fs-mkfs-opts.patch: LIVECD_MKFS_EXT_OPTS adds mkfs options for ext filesystems
#    (used to build without dir_index, see appliance-creator.sh)
COPY ci/patches/ /tmp/patches/
RUN cd /usr/lib/python3.9/site-packages/imgcreate \
 && patch -p2 --no-backup-if-mismatch < /tmp/patches/fs.py.patch \
 && patch -p2 --no-backup-if-mismatch < /tmp/patches/dnfinst-forcearch.patch \
 && patch -p2 --no-backup-if-mismatch < /tmp/patches/fs-mkfs-opts.patch \
 && grep -q LIVECD_FORCEARCH dnfinst.py \
 && grep -q LIVECD_MKFS_EXT_OPTS fs.py \
 && python3 -m py_compile dnfinst.py fs.py \
 && rm -rf /tmp/patches

COPY ci/appliance-creator.sh /appliance-creator.sh
RUN chmod +x /appliance-creator.sh

WORKDIR /work
ENTRYPOINT ["/bin/bash", "/appliance-creator.sh"]
