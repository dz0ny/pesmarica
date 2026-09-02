#!/usr/bin/env bash
# Swaps a staged system into place on the boot partition.
#
# The system is one directory -- kernel.img, initrd, cmdline.txt, the device
# trees and rootfs.img -- and config.txt's os_prefix names it. So an update is
# not a copy over the live files, which would leave a dead box if it stopped
# half way: it is a second directory beside them, and then two renames. The
# running system holds its squashfs by an open loop fd and does not notice the
# directory move out from under it.
#
# This runs on the box, piped in over ssh by tool/deploy_system.sh. It also
# runs on a laptop against a fake tree, which is what tool/test_system_swap.sh
# does -- hence FIRMWARE rather than a hardcoded path.
set -euo pipefail

FIRMWARE="${FIRMWARE:-/boot/firmware}"

live="$FIRMWARE/nixos/default"
staged="$live.new"
old="$live.old"

# The firmware loads all of these by name out of os_prefix. A payload missing
# one is an rsync cut short, and installing it costs a trip to the box with a
# card reader -- so check before touching anything. The marker is written last
# by the deploy, so its presence means the transfer ran to the end.
for f in .complete cmdline.txt initrd kernel.img rootfs.img; do
	[ -e "$staged/$f" ] || { echo "!! $staged/$f missing; refusing to swap" >&2; exit 1; }
done
# The board needs its device tree, and the display needs the vc4-kms-v3d
# overlay beside it: without those the box boots to a black screen rather
# than failing outright, which is the worst way to find out.
shopt -s nullglob
dtbs=("$staged"/*.dtb)
overlays=("$staged"/overlays/*.dtbo)
shopt -u nullglob
[ ${#dtbs[@]} -gt 0 ] || { echo "!! no device tree in $staged; refusing to swap" >&2; exit 1; }
[ ${#overlays[@]} -gt 0 ] || { echo "!! no overlays in $staged; refusing to swap" >&2; exit 1; }

[ -d "$live" ] || { echo "!! $live is not there; this box is not running the image" >&2; exit 1; }

# Only one previous system is kept: the partition is sized for two, and a
# third would be the one that fills the card on a Sunday morning.
rm -rf "$old"
mv "$live" "$old"
mv "$staged" "$live"

echo "==> $live replaced; the previous system is at $old"
