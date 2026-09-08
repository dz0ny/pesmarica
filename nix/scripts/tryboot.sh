#!/usr/bin/env bash
# Decides, once per boot, whether this box is on trial and whether to try again.
#
# There are two situations and the box can tell them apart without being told:
# the slot it is running is baked into the system (/etc/pesmarica-slot), and the
# slot it is *supposed* to run is one line of config.txt. When they disagree,
# the firmware got here through tryboot.txt and this is a trial boot.
#
#   trial boot     wait for the app to actually answer, then promote the slot
#                  into config.txt. Nothing else makes it permanent, so a
#                  system that comes up broken -- black screen, no radio, an
#                  app that will not start -- is simply never promoted, and the
#                  next restart reads config.txt and lands on the slot that was
#                  already working.
#
#   ordinary boot  if an update is staged and has attempts left, arm it and
#                  restart. This is the retry, and it is here rather than in a
#                  bootloader on purpose: the counter is written by the system
#                  that is known to work, not incremented on every boot of a
#                  healthy box.
#
# The retry matters more than it looks. A trial boot is one shot -- the firmware
# clears the flag before it starts -- so a hall that browns out mid-boot would
# otherwise revert a perfectly good update, and nobody would ever know why.
#
# Everything comes from the environment so that tool/test_tryboot.sh can run it
# against a directory and a fake probe.
set -euo pipefail

FIRMWARE="${FIRMWARE:-/boot/firmware}"
SLOT_FILE="${SLOT_FILE:-/etc/pesmarica-slot}"
SWITCH="${SWITCH:-pesmarica-system-switch}"
REBOOT="${REBOOT:-pesmarica-tryboot-reboot}"
# What counts as "this system works". Anything that answers only when the app is
# serving: it means the store mounted, the songbook loaded and Dart is running.
PROBE="${PROBE:-}"
# How many times a staged update may be tried before it is left alone. Three
# because the failure this guards against is a power cut, and a fourth attempt
# says something is wrong with the release rather than with the mains.
LIMIT="${LIMIT:-3}"

state="$FIRMWARE/tryboot.state"
config="$FIRMWARE/config.txt"

running="$(tr -d '[:space:]' < "$SLOT_FILE" 2>/dev/null || true)"
booted="$(sed -n 's|^os_prefix=nixos-\(.\)/default/.*|\1|p' "$config" 2>/dev/null | head -1)"

case "$running" in
	a | b) ;;
	*) echo "pesmarica-tryboot: this system does not say which slot it runs" >&2; exit 0 ;;
esac
[ -n "$booted" ] || { echo "pesmarica-tryboot: config.txt has no os_prefix" >&2; exit 0; }

# -- on trial ----------------------------------------------------------------

if [ "$running" != "$booted" ]; then
	if [ -n "$PROBE" ] && ! eval "$PROBE"; then
		# Deliberately not a failure: there is nothing to fix from here, and the
		# way back is already arranged. Say so where somebody will find it.
		echo "pesmarica-tryboot: slot $running did not come up; a restart returns to $booted" >&2
		exit 0
	fi
	"$SWITCH" "$running"
	rm -f "$state"
	echo "pesmarica-tryboot: slot $running confirmed and made permanent"
	exit 0
fi

# -- on the slot that works --------------------------------------------------

[ -e "$state" ] || exit 0

slot="$(sed -n 's/^slot=//p' "$state" | head -1)"
attempts="$(sed -n 's/^attempts=//p' "$state" | head -1)"
[ -n "$attempts" ] || attempts=0

# A staged slot that is the one we are running is nonsense left over from
# something; clear it rather than reasoning about it.
if [ "$slot" != "a" ] && [ "$slot" != "b" ] || [ "$slot" = "$running" ]; then
	rm -f "$state"
	exit 0
fi

if [ "$attempts" -ge "$LIMIT" ]; then
	rm -f "$state"
	echo "pesmarica-tryboot: slot $slot failed $attempts times; leaving this box on $running" >&2
	exit 0
fi

# The count goes up *before* the restart, and to the card, because the whole
# purpose is to survive a boot that never finishes. Incrementing afterwards
# would be a loop with no end.
printf 'slot=%s\nattempts=%s\n' "$slot" "$((attempts + 1))" > "$state.tmp"
mv "$state.tmp" "$state"

if ! "$SWITCH" --try "$slot"; then
	rm -f "$state"
	echo "pesmarica-tryboot: slot $slot is not bootable; not trying it" >&2
	exit 0
fi

echo "pesmarica-tryboot: trying slot $slot, attempt $((attempts + 1)) of $LIMIT"
exec "$REBOOT"
