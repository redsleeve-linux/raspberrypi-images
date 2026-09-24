#!/bin/bash
# Build from a Windows checkout inside WSL2 (Fedora/Ubuntu with Docker): sync the repo to the Linux
# filesystem (bind-mounting /mnt/c into the build container is slow and loop devices dislike it),
# run ./build there, verify the result and copy the deliverables back next to the checkout.
# Usage (as root in WSL): tools/wsl-build.sh [/mnt/c/repo/redsleeve] [/root/rs-build]
set -euo pipefail
SRC=${1:-/mnt/c/repo/redsleeve}
DST=${2:-/root/rs-build}
systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
mkdir -p "$DST"
(cd "$SRC" && tar --exclude=./cache --exclude=./rpi-image --exclude=./.git -cf - .) | tar -xf - -C "$DST"
chmod +x "$DST/build" "$DST/ci/appliance-creator.sh" "$DST"/tools/*.sh
cd "$DST"
./build 2>&1 | tee "$DST/build.log"
RAW=$(ls -t "$DST"/rpi-image/*.raw | head -1)
NAME=$(basename "$RAW" .raw)
bash "$DST/tools/verify-image.sh" "$RAW"
mkdir -p "$SRC/rpi-image"
cp -v "$DST/rpi-image/$NAME".{raw.xz,log,log.2,xml} "$SRC/rpi-image/"
(cd "$SRC/rpi-image" && sha256sum "$NAME.raw.xz" | tee "$NAME.raw.xz.sha256")
