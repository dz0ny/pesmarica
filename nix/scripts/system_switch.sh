#!/usr/bin/env bash
# Points the firmware at a slot on the boot partition.
#
# A system lives in nixos-a/default/ or nixos-b/default/, and its slot is
# baked into it: config.txt's os_prefix names the folder the firmware boots,
# and the system's own fstab names the same folder for its rootfs.img. So an
# update never touches the running slot -- it fills the other one and moves
# os_prefix, which is one line in a plain file. Nothing that is open moves.
#
# Two ways to point it:
#
#   system_switch.sh <slot>          config.txt. This is where the box boots
#                                    from now on, and it is what the trial
#                                    boot below is promoted to once it works.
#   system_switch.sh --try <slot>    tryboot.txt, which the firmware loads
#                                    instead of config.txt exactly once, when
#                                    the box is restarted with the tryboot
#                                    flag set. The flag is cleared before the
#                                    firmware starts, so a crash, a hang or a
#                                    power cut between here and a working
#                                    system means the next boot reads
#                                    config.txt again and comes up on the slot
#                                    that was already working. That is the
#                                    whole rollback: no bootloader of ours in
#                                    the chain, and nothing written per boot.
#
# It runs three ways, which is why it lives under nix/ and takes FIRMWARE from
# the environment rather than hardcoding a path: piped in over ssh by
# tool/deploy_system.sh, installed in the image as pesmarica-system-switch and
# run by pesmarica-update-install.service, and on a laptop against a fake tree,
# which is what tool/test_system_switch.sh does. One copy of the refusals: they
# are what decides whether a box comes back, and two of them could disagree.
set -euo pipefail

FIRMWARE="${FIRMWARE:-/boot/firmware}"

TRIAL=""
if [ "${1:-}" = "--try" ]; then TRIAL=1; shift; fi
SLOT="${1:?usage: system_switch.sh [--try] <a|b>}"
case "$SLOT" in a|b) ;; *) echo "!! slot must be a or b, not '$SLOT'" >&2; exit 1 ;; esac

slot="$FIRMWARE/nixos-$SLOT/default"
config="$FIRMWARE/config.txt"
# The trial file is written from config.txt, so it inherits every other line --
# the firmware settings, the overlays, the display. Only os_prefix differs, and
# only for the one boot the flag survives.
target="$config"
[ -z "$TRIAL" ] || target="$FIRMWARE/tryboot.txt"

# The firmware loads all of these by name out of os_prefix. A payload missing
# one is a transfer cut short, and pointing the box at it costs a trip with a
# card reader -- so check before touching anything. The marker is written last
# by the deploy, so its presence means the transfer ran to the end.
for f in .complete cmdline.txt initrd kernel.img rootfs.img; do
	[ -e "$slot/$f" ] || { echo "!! $slot/$f missing; refusing to switch" >&2; exit 1; }
done
# The board needs its device tree, and the display the vc4-kms-v3d overlay:
# without those the box boots to a black screen rather than failing outright.
shopt -s nullglob
dtbs=("$slot"/*.dtb)
overlays=("$slot"/overlays/*.dtbo)
shopt -u nullglob
[ ${#dtbs[@]} -gt 0 ] || { echo "!! no device tree in $slot; refusing to switch" >&2; exit 1; }
[ ${#overlays[@]} -gt 0 ] || { echo "!! no overlays in $slot; refusing to switch" >&2; exit 1; }

grep -q '^os_prefix=' "$config" || { echo "!! $config has no os_prefix; this is not the image" >&2; exit 1; }

# One line, written to a temp file and renamed into place: FAT has no journal,
# and a power cut between truncating config.txt and rewriting it would leave
# a card the firmware cannot boot from at all.
sed "s|^os_prefix=.*|os_prefix=nixos-$SLOT/default/|" "$config" > "$target.tmp"
mv "$target.tmp" "$target"

if [ -n "$TRIAL" ]; then
	echo "==> tryboot.txt -> nixos-$SLOT/default/ (one boot)"
else
	# A stale trial file would be loaded by the next tryboot flag anybody sets,
	# pointing at whatever was being tried weeks ago. It has done its job.
	rm -f "$FIRMWARE/tryboot.txt"
	echo "==> os_prefix -> nixos-$SLOT/default/"
fi
