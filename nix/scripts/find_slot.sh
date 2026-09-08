#!/usr/bin/env bash
# Says which of the two slots this box is running from.
#
# It used to be baked in: a system was built for its slot, carried the answer
# in /etc/pesmarica-slot and named its own rootfs.img in its fstab. That made
# the two slots two different systems, so every release shipped two payloads of
# half a gigabyte that differed by a handful of bytes. The slot is out of the
# system now and worked out here instead, which is what lets one payload land
# in either slot.
#
# The firmware loaded this kernel out of one slot, and the cmdline it was given
# is that slot's cmdline.txt -- which names this system's own store path. Each
# slot says which system it holds in `system-link`, written beside the kernel.
# The slot whose system-link is what we were started with is the one we run.
#
# Nothing on the card is written, and nothing is remembered: the two files this
# reads are the same two the firmware read, so the answer cannot drift from
# what actually booted -- including on a trial boot, where config.txt still
# names the slot the box came from.
#
# Everything comes from the environment: it runs in the initrd against
# /sysroot/boot/firmware, on the box as pesmarica-find-slot, and on a laptop
# against a fake tree, which is what tool/test_find_slot.sh does.
set -euo pipefail

FIRMWARE="${FIRMWARE:-/boot/firmware}"
CMDLINE="${CMDLINE:-/proc/cmdline}"

# Only bash builtins below the reads: this runs in the initrd, where the store
# holds what the closure dragged in and nothing else.
read -r cmdline < "$CMDLINE" || cmdline=""

self=""
# shellcheck disable=SC2086 # the cmdline is a list of words; that is the point.
for word in $cmdline; do
	case "$word" in
		init=*/init) self="${word#init=}"; self="${self%/init}" ;;
	esac
done
[ -n "$self" ] || { echo "pesmarica-find-slot: $CMDLINE names no system" >&2; exit 1; }

found=""
for slot in a b; do
	link="$FIRMWARE/nixos-$slot/default/system-link"
	[ -r "$link" ] || continue
	read -r holds < "$link" || continue
	[ "$holds" = "$self" ] || continue
	found="$found$slot"
done

case "$found" in
	a | b)
		printf '%s\n' "$found"
		;;
	ab)
		# Both slots hold this same system -- two deploys of one release will do
		# that -- and then the payloads are identical and either answer boots
		# the same thing. config.txt breaks the tie so that a box which is not
		# on trial does not look like one.
		configured=""
		if [ -r "$FIRMWARE/config.txt" ]; then
			while read -r line || [ -n "$line" ]; do
				case "$line" in
					os_prefix=nixos-?/default/*)
						line="${line#os_prefix=nixos-}"
						configured="${line%%/*}"
						;;
				esac
			done < "$FIRMWARE/config.txt"
		fi
		case "$configured" in
			a | b) printf '%s\n' "$configured" ;;
			*) printf 'a\n' ;;
		esac
		;;
	*)
		echo "pesmarica-find-slot: no slot on $FIRMWARE holds $self" >&2
		exit 1
		;;
esac
