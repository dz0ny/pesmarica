#!/usr/bin/env bash
# Replaces the *system* on an appliance that is already running the image,
# over ssh, instead of pulling the card and reflashing it.
#
#   HOST=root@pesmarica.local ./tool/deploy_system.sh            # builds locally
#   HOST=root@pesmarica.local RELEASE=v7 ./tool/deploy_system.sh # from a release
#   HOST=... PAYLOAD=/path/to/firmware-b ./tool/deploy_system.sh # a tree you have
#
# This is how the box is updated at all: the app is in the closure, so there
# is nothing smaller to push. Expect minutes, not seconds -- half a gigabyte
# over the box's own 2.4 GHz access point onto an SD card.
#
# The boot partition has two slots, nixos-a and nixos-b, and a system is built
# for one of them: its fstab names its own slot, and config.txt's os_prefix
# names the slot the firmware boots. So the deploy asks the box which slot it
# is running, fills the other, and moves os_prefix. Nothing the running system
# has open is touched, and the previous system stays whole in its slot.
#
# There is no automatic rollback: the Pi firmware picks the kernel before
# anything of ours runs. If the new system does not come up, the way back is
# a card reader and one line of config.txt:
#
#   os_prefix=nixos-<the other letter>/default/
#
# Only the slot is written. The Pi's own firmware -- bootcode.bin, start*.elf,
# fixup*.dat -- is left alone: it has no second copy to fall back to, and it
# changes about once a year. The script says so when it has drifted, and then
# a reflash is the honest answer.
set -euo pipefail

HOST="${HOST:?set HOST=root@pesmarica.local}"
FIRMWARE="${FIRMWARE:-/boot/firmware}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Which slot is free. The box says which it is running; the image ships a.
RUNNING="$(ssh "$HOST" "cat /etc/pesmarica-slot 2>/dev/null | tr -d '[:space:]'" || true)"
case "$RUNNING" in
	a) SLOT=b ;;
	b) SLOT=a ;;
	*) echo "!! $HOST does not say which slot it runs; is it on an image with slots?" >&2; exit 1 ;;
esac

# Where the payload comes from: a release, a tree you point at, or a build
# in colima, in that order of preference -- the first two need no builder.
PAYLOAD="${PAYLOAD:-}"
if [ -n "${RELEASE:-}" ]; then
	dl="$(mktemp -d)"; trap 'rm -rf "$dl"' EXIT
	gh release download "$RELEASE" -p "pesmarica-system-$SLOT-*.tar.zst" -D "$dl"
	mkdir -p "$dl/tree/nixos-$SLOT"
	zstd -dc "$dl"/pesmarica-system-"$SLOT"-*.tar.zst | tar -C "$dl/tree/nixos-$SLOT" -xf -
	PAYLOAD="$dl/tree"
elif [ -z "$PAYLOAD" ]; then
	make -C "$ROOT/nix" system SLOT="$SLOT"
	PAYLOAD="$ROOT/nix/out/firmware-$SLOT"
fi
SRC="$PAYLOAD/nixos-$SLOT/default"
[ -d "$SRC" ] || { echo "!! $SRC is not there; is PAYLOAD a slot-$SLOT firmware tree?" >&2; exit 1; }

VERSION="${RELEASE:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || date +%Y-%m-%d)}"
NEED_KB="$(du -sk "$SRC" | cut -f1)"

echo "==> $HOST: slot $RUNNING running, writing $SLOT ($VERSION, $(( NEED_KB / 1024 )) MiB)"

# The partition is sized for two slots, so the one being replaced is emptied
# first, and the check counts it as free. Nothing is lost by that: while a
# new system is being written, the running one is the fallback, and it is in
# the other slot. Check before spending ten minutes on a transfer that cannot
# land.
ssh "$HOST" "
	set -e
	free=\$(df -k $FIRMWARE | awk 'NR==2 {print \$4}')
	reclaim=\$(du -sk $FIRMWARE/nixos-$SLOT 2>/dev/null | awk '{s+=\$1} END {print s+0}')
	if [ \$(( free + reclaim )) -lt $(( NEED_KB + 32768 )) ]; then
		echo \"!! $FIRMWARE has \$(( (free + reclaim) / 1024 )) MiB free, needs $(( NEED_KB / 1024 + 32 ))\" >&2
		exit 1
	fi
	rm -rf $FIRMWARE/nixos-$SLOT
	mkdir -p $FIRMWARE/nixos-$SLOT/default
"

# tar, not rsync: rsync would have to exist on the box, and it does not. tar
# is in the closure regardless. --no-same-owner/permissions: FAT carries
# neither, they come from the mount, and tar would fail trying to set them.
tar -C "$SRC" -cf - . | ssh "$HOST" "tar -C $FIRMWARE/nixos-$SLOT/default -xf - --no-same-owner --no-same-permissions"

# The marker goes last, so a cut-short transfer leaves an unusable slot rather
# than a plausible one. system_switch.sh refuses without it.
ssh "$HOST" "printf '%s\n' '$VERSION' > $FIRMWARE/nixos-$SLOT/default/.complete"

# Warn about the parts an ssh update cannot replace, rather than replacing
# them. Sorted: the two shells expand the globs in their own order. config.txt
# is not compared -- its os_prefix legitimately differs by slot.
onbox="$(mktemp)"; inbuild="$(mktemp)"
ssh "$HOST" "cd $FIRMWARE && md5sum start*.elf fixup*.dat bootcode.bin 2>/dev/null" | sort > "$onbox" || true
(cd "$PAYLOAD" && md5sum start*.elf fixup*.dat bootcode.bin 2>/dev/null) | sort > "$inbuild" || true
if ! diff -q "$onbox" "$inbuild" >/dev/null; then
	echo "!! the Pi firmware differs from this build:"
	diff "$onbox" "$inbuild" || true
	echo "!! this update does not replace it -- reflash the card for that."
fi
rm -f "$onbox" "$inbuild"

ssh "$HOST" "FIRMWARE=$FIRMWARE bash -s $SLOT" < "$HERE/system_switch.sh"

echo "==> rebooting $HOST"
# sync, then restart through sysrq. A clean shutdown tears down the loop
# device the store lives on, and this box does not come back from that. Root
# is a tmpfs and the store is read-only, so the sync is for the FAT partitions
# and is everything a clean shutdown would have done for them. The connection
# dies with the box, which is not a failure.
ssh "$HOST" "sync; echo s > /proc/sysrq-trigger; sleep 1; echo b > /proc/sysrq-trigger" || true
