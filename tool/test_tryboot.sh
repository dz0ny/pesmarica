#!/usr/bin/env bash
# Covers nix/scripts/tryboot.sh against fake boot partitions.
#
# This is the script that decides whether a box that has just been updated stays
# updated, and whether one that failed gets another go. Both directions are a
# card reader trip if they are wrong, and the retry has the shape that loops
# forever if the counter is written in the wrong order -- so the count is pinned
# here as carefully as the refusals are.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TRYBOOT="$ROOT/nix/scripts/tryboot.sh"
SWITCH="$ROOT/nix/scripts/system_switch.sh"
pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# A boot partition with both slots complete, config.txt naming slot a, plus a
# fake reboot that records that it was called instead of restarting the laptop.
fixture() { # fixture <dir> <running slot>
	local d="$1"
	printf 'kernel=kernel.img\nos_prefix=nixos-a/default/\ninitramfs initrd followkernel\n' > "$d/config.txt"
	for s in a b; do
		mkdir -p "$d/nixos-$s/default/overlays"
		touch "$d/nixos-$s/default"/{initrd,cmdline.txt,rootfs.img,kernel.img,.complete} \
			"$d/nixos-$s/default/bcm2710-rpi-zero-2-w.dtb" \
			"$d/nixos-$s/default/overlays/vc4-kms-v3d.dtbo"
	done
	printf '%s\n' "$2" > "$d/slot"
	printf '#!/bin/sh\necho rebooted >> "%s/reboots"\n' "$d" > "$d/reboot"
	chmod +x "$d/reboot"
}

# $1 dir, $2 probe command ("true"/"false"), rest: environment overrides
run() { # run <dir> <probe> [LIMIT]
	FIRMWARE="$1" SLOT_FILE="$1/slot" SWITCH="$SWITCH" REBOOT="$1/reboot" \
		PROBE="$2" LIMIT="${3:-3}" bash "$TRYBOOT" >/dev/null 2>&1
}
prefix() { grep '^os_prefix=' "$1/config.txt"; }
reboots() { grep -c . "$1/reboots" 2>/dev/null || echo 0; }

# --- a trial boot that works ------------------------------------------------

d="$(mktemp -d)"; fixture "$d" b        # running b, config.txt still says a
FIRMWARE="$d" bash "$SWITCH" --try b >/dev/null 2>&1
printf 'slot=b\nattempts=1\n' > "$d/tryboot.state"
run "$d" true
[ "$(prefix "$d")" = "os_prefix=nixos-b/default/" ] && ok "an app that answers promotes its slot" || no "an app that answers promotes its slot"
[ ! -e "$d/tryboot.state" ] && ok "and the attempt counter is cleared" || no "and the attempt counter is cleared"
[ ! -e "$d/tryboot.txt" ] && ok "and the trial file is cleared" || no "and the trial file is cleared"
[ "$(reboots "$d")" -eq 0 ] && ok "and nothing is restarted" || no "and nothing is restarted"
rm -rf "$d"

# --- a trial boot that comes up broken --------------------------------------
# The point of the whole design: nothing is promoted, so the next restart --
# which may be somebody pulling the plug -- lands on the slot that worked.

d="$(mktemp -d)"; fixture "$d" b
printf 'slot=b\nattempts=1\n' > "$d/tryboot.state"
run "$d" false
[ "$(prefix "$d")" = "os_prefix=nixos-a/default/" ] && ok "an app that never answers is not promoted" || no "an app that never answers is not promoted"
[ -e "$d/tryboot.state" ] && ok "and the attempt is remembered for next boot" || no "and the attempt is remembered for next boot"
[ "$(reboots "$d")" -eq 0 ] && ok "and the box is left alone rather than looped" || no "and the box is left alone rather than looped"
rm -rf "$d"

# --- the retry --------------------------------------------------------------

d="$(mktemp -d)"; fixture "$d" a        # back on the good slot after a failure
printf 'slot=b\nattempts=1\n' > "$d/tryboot.state"
run "$d" true
[ "$(reboots "$d")" -eq 1 ] && ok "a staged slot with attempts left is tried again" || no "a staged slot with attempts left is tried again"
[ "$(grep '^os_prefix=' "$d/tryboot.txt")" = "os_prefix=nixos-b/default/" ] && ok "and it is armed, not switched to" || no "and it is armed, not switched to"
[ "$(prefix "$d")" = "os_prefix=nixos-a/default/" ] && ok "and config.txt still names the working slot" || no "and config.txt still names the working slot"
[ "$(sed -n 's/^attempts=//p' "$d/tryboot.state")" = "2" ] && ok "and the count goes up before the restart, not after" || no "and the count goes up before the restart, not after"
rm -rf "$d"

# Three attempts and then it stops. Without this the box restarts forever, which
# on a screen in a hall is indistinguishable from a dead one.
d="$(mktemp -d)"; fixture "$d" a
printf 'slot=b\nattempts=3\n' > "$d/tryboot.state"
run "$d" true
[ "$(reboots "$d")" -eq 0 ] && ok "a slot that has used its attempts is not tried again" || no "a slot that has used its attempts is not tried again"
[ ! -e "$d/tryboot.state" ] && ok "and the box stops asking" || no "and the box stops asking"
[ "$(prefix "$d")" = "os_prefix=nixos-a/default/" ] && ok "and stays on the slot that works" || no "and stays on the slot that works"
rm -rf "$d"

# A half-written slot must not be armed: the flag would boot it once and the box
# would come up with no kernel, which from the back of a hall looks like a brick.
d="$(mktemp -d)"; fixture "$d" a; rm -f "$d/nixos-b/default/kernel.img"
printf 'slot=b\nattempts=1\n' > "$d/tryboot.state"
run "$d" true
[ "$(reboots "$d")" -eq 0 ] && ok "an incomplete slot is not tried" || no "an incomplete slot is not tried"
[ ! -e "$d/tryboot.state" ] && ok "and is given up on rather than retried" || no "and is given up on rather than retried"
rm -rf "$d"

# --- nothing staged ---------------------------------------------------------

d="$(mktemp -d)"; fixture "$d" a
run "$d" true
[ "$(reboots "$d")" -eq 0 ] && ok "an ordinary boot with nothing staged does nothing" || no "an ordinary boot with nothing staged does nothing"
[ ! -e "$d/tryboot.txt" ] && ok "and arms nothing" || no "and arms nothing"
rm -rf "$d"

# State naming the slot we are already running is left over from something that
# already happened. Clear it rather than reason about it.
d="$(mktemp -d)"; fixture "$d" a
printf 'slot=a\nattempts=1\n' > "$d/tryboot.state"
run "$d" true
[ "$(reboots "$d")" -eq 0 ] && ok "state naming the running slot is not acted on" || no "state naming the running slot is not acted on"
[ ! -e "$d/tryboot.state" ] && ok "and is cleared" || no "and is cleared"
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
