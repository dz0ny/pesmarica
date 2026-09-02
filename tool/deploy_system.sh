#!/usr/bin/env bash
# Replaces the *system* on an appliance that is already running the image,
# over ssh, instead of pulling the card and reflashing it.
#
#   HOST=root@pesmarica.local ./tool/deploy_system.sh
#
# This is the heavier sibling of deploy_pi.sh: that one pushes the Flutter
# bundle between reflashes, this one pushes the kernel, the initrd and the
# whole closure as one squashfs. Expect minutes, not seconds -- it is a few
# hundred megabytes over the box's own 2.4 GHz access point onto an SD card.
# If all you changed is Dart, use deploy_pi.sh.
#
# The new system is written beside the live one and then swapped in by rename,
# so an interrupted transfer touches nothing that boots. See tool/system_swap.sh
# for that half, which is also what tool/test_system_swap.sh covers.
#
# There is no automatic rollback: the Pi firmware picks the kernel before
# anything of ours runs. The previous system stays whole on the card, so if
# the new one does not come up, the way back is a card reader and two renames
# on any laptop:
#
#   rm -rf FIRMWARE/nixos/default && mv FIRMWARE/nixos/default.old FIRMWARE/nixos/default
#
# Only nixos/default/ is replaced. The Pi's own firmware -- bootcode.bin,
# start*.elf, fixup*.dat -- and config.txt are left alone: they have no second
# copy to fall back to, and they change about once a year. The script says so
# when they have drifted, and then a reflash is the honest answer.
set -euo pipefail

HOST="${HOST:?set HOST=root@pesmarica.local}"
FIRMWARE="${FIRMWARE:-/boot/firmware}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# PAYLOAD lets you point at a tree you built yourself; otherwise build it the
# way the image is built, inside colima, because this needs aarch64 Linux.
PAYLOAD="${PAYLOAD:-}"
if [ -z "$PAYLOAD" ]; then
	make -C "$ROOT/nix" system
	PAYLOAD="$ROOT/nix/out/firmware"
fi
SRC="$PAYLOAD/nixos/default"
[ -d "$SRC" ] || { echo "!! $SRC is not there; is PAYLOAD a firmware tree?" >&2; exit 1; }

VERSION="$(git -C "$ROOT" describe --always --dirty 2>/dev/null || date +%Y-%m-%d)"
NEED_KB="$(du -sk "$SRC" | cut -f1)"

echo "==> $HOST:$FIRMWARE/nixos/default.new ($VERSION, $(( NEED_KB / 1024 )) MiB)"

# The partition holds two systems, so the previous one goes now rather than
# after the swap: otherwise the transfer would need room for three at once and
# the second update onto any box would run the card out of space. Nothing is
# lost by it -- the system that is *running* is the one to fall back to while
# a new one is being written, and that one is not touched until the swap.
# Check before spending ten minutes on a transfer that cannot land.
ssh "$HOST" "
	set -e
	free=\$(df -k $FIRMWARE | awk 'NR==2 {print \$4}')
	reclaim=\$(du -sk $FIRMWARE/nixos/default.new $FIRMWARE/nixos/default.old 2>/dev/null | awk '{s+=\$1} END {print s+0}')
	if [ \$(( free + reclaim )) -lt $(( NEED_KB + 32768 )) ]; then
		echo \"!! $FIRMWARE has \$(( (free + reclaim) / 1024 )) MiB free, needs $(( NEED_KB / 1024 + 32 ))\" >&2
		exit 1
	fi
	rm -rf $FIRMWARE/nixos/default.new $FIRMWARE/nixos/default.old
"

# tar, not rsync: rsync has to exist on the *box*, and on an appliance whose
# environment.defaultPackages is empty it did not -- which made this script
# unable to bootstrap itself onto any box flashed before rsync was added back.
# tar is in the closure regardless. There is nothing for rsync's delta to save
# here anyway: the staging directory was just deleted, so every byte goes over
# either way.
#
# --no-same-owner/permissions: FAT carries neither, and they come from the
# mount (umask=0077). tar would otherwise fail trying to set them.
tar -C "$SRC" -cf - . | ssh "$HOST" "
	mkdir -p $FIRMWARE/nixos/default.new
	tar -C $FIRMWARE/nixos/default.new -xf - --no-same-owner --no-same-permissions
"

# The marker goes last, so a cut-short rsync leaves an unusable directory
# rather than a plausible one. system_swap.sh refuses without it.
ssh "$HOST" "printf '%s\n' '$VERSION' > $FIRMWARE/nixos/default.new/.complete"

# Warn about the parts an ssh update cannot replace, rather than replacing
# them: there is no second copy of these to fall back to.
onbox="$(mktemp)"; inbuild="$(mktemp)"
trap 'rm -f "$onbox" "$inbuild"' EXIT
ssh "$HOST" "cd $FIRMWARE && md5sum config.txt start*.elf fixup*.dat bootcode.bin 2>/dev/null" > "$onbox" || true
(cd "$PAYLOAD" && md5sum config.txt start*.elf fixup*.dat bootcode.bin 2>/dev/null) > "$inbuild" || true
if ! diff -q "$onbox" "$inbuild" >/dev/null; then
	echo "!! the Pi firmware or config.txt differ from this build:"
	diff "$onbox" "$inbuild" || true
	echo "!! this update does not replace them -- reflash the card for those."
fi

ssh "$HOST" "FIRMWARE=$FIRMWARE bash -s" < "$HERE/system_swap.sh"

echo "==> rebooting $HOST"
# The connection dies with the box, which is not a failure.
ssh "$HOST" "systemctl reboot" || true
