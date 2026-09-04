#!/usr/bin/env bash
# Covers nix/scripts/system_switch.sh against fake boot partitions. The nix
# half of a system update cannot be built or booted here, but the switch can,
# and the switch is what decides whether a box comes back. Every refusal below
# is a card reader trip that did not happen.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SWITCH="$ROOT/nix/scripts/system_switch.sh"
pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# A boot partition running slot a, with slot b staged and complete.
fixture() { # fixture <dir>
	local d="$1"
	printf 'kernel=kernel.img\nos_prefix=nixos-a/default/\ninitramfs initrd followkernel\n' > "$d/config.txt"
	for s in a b; do
		mkdir -p "$d/nixos-$s/default/overlays"
		touch "$d/nixos-$s/default"/{initrd,cmdline.txt,rootfs.img,kernel.img,.complete} \
			"$d/nixos-$s/default/bcm2710-rpi-zero-2-w.dtb" \
			"$d/nixos-$s/default/overlays/vc4-kms-v3d.dtbo"
	done
}
switch() { FIRMWARE="$1" bash "$SWITCH" "$2" >/dev/null 2>&1; }
arm() { FIRMWARE="$1" bash "$SWITCH" --try "$2" >/dev/null 2>&1; }
prefix() { grep '^os_prefix=' "$1/config.txt"; }

d="$(mktemp -d)"; fixture "$d"
if switch "$d" b; then ok "a complete slot is switched to"; else no "a complete slot is switched to"; fi
[ "$(prefix "$d")" = "os_prefix=nixos-b/default/" ] && ok "os_prefix names the new slot" || no "os_prefix names the new slot"
[ "$(grep -c . "$d/config.txt")" -eq 3 ] && ok "the rest of config.txt is untouched" || no "the rest of config.txt is untouched"
[ -e "$d/nixos-a/default/rootfs.img" ] && ok "the previous slot is kept" || no "the previous slot is kept"
[ ! -e "$d/config.txt.tmp" ] && ok "no temp file left behind" || no "no temp file left behind"
rm -rf "$d"

for missing in .complete kernel.img initrd cmdline.txt rootfs.img; do
	d="$(mktemp -d)"; fixture "$d"; rm -f "$d/nixos-b/default/$missing"
	if switch "$d" b; then no "refuses a slot with no $missing"; else ok "refuses a slot with no $missing"; fi
	[ "$(prefix "$d")" = "os_prefix=nixos-a/default/" ] && ok "and leaves os_prefix alone ($missing)" || no "and leaves os_prefix alone ($missing)"
	rm -rf "$d"
done

d="$(mktemp -d)"; fixture "$d"; rm -f "$d"/nixos-b/default/*.dtb
if switch "$d" b; then no "refuses a slot with no device tree"; else ok "refuses a slot with no device tree"; fi; rm -rf "$d"
d="$(mktemp -d)"; fixture "$d"; rm -rf "$d/nixos-b/default/overlays"
if switch "$d" b; then no "refuses a slot with no overlays"; else ok "refuses a slot with no overlays"; fi; rm -rf "$d"
d="$(mktemp -d)"; fixture "$d"
if switch "$d" c; then no "refuses a slot that is not a or b"; else ok "refuses a slot that is not a or b"; fi; rm -rf "$d"
d="$(mktemp -d)"; fixture "$d"; printf 'kernel=kernel.img\n' > "$d/config.txt"
if switch "$d" b; then no "refuses a config.txt with no os_prefix"; else ok "refuses a config.txt with no os_prefix"; fi; rm -rf "$d"

d="$(mktemp -d)"; fixture "$d"; switch "$d" b; switch "$d" a
[ "$(prefix "$d")" = "os_prefix=nixos-a/default/" ] && ok "switching back works" || no "switching back works"; rm -rf "$d"


# --- the trial boot ---------------------------------------------------------
# The firmware loads tryboot.txt instead of config.txt for exactly one boot,
# and clears the flag before it starts. So arming must not touch config.txt:
# the whole rollback is that the box already knows where to go back to.

d="$(mktemp -d)"; fixture "$d"
if arm "$d" b; then ok "a complete slot can be armed for a trial boot"; else no "a complete slot can be armed for a trial boot"; fi
[ "$(prefix "$d")" = "os_prefix=nixos-a/default/" ] && ok "arming leaves config.txt on the working slot" || no "arming leaves config.txt on the working slot"
[ "$(grep '^os_prefix=' "$d/tryboot.txt")" = "os_prefix=nixos-b/default/" ] && ok "tryboot.txt names the slot being tried" || no "tryboot.txt names the slot being tried"
[ "$(grep -c . "$d/tryboot.txt")" -eq 3 ] && ok "tryboot.txt keeps every other firmware line" || no "tryboot.txt keeps every other firmware line"
[ ! -e "$d/tryboot.txt.tmp" ] && ok "no temp file left behind by arming" || no "no temp file left behind by arming"
rm -rf "$d"

# An armed slot that turns out to be half-written must be refused for the same
# reasons a permanent switch is: the flag would boot it once and the box would
# come up with no kernel, which looks exactly like a dead box.
for missing in .complete kernel.img initrd rootfs.img; do
	d="$(mktemp -d)"; fixture "$d"; rm -f "$d/nixos-b/default/$missing"
	if arm "$d" b; then no "refuses to arm a slot with no $missing"; else ok "refuses to arm a slot with no $missing"; fi
	[ ! -e "$d/tryboot.txt" ] && ok "and writes no tryboot.txt ($missing)" || no "and writes no tryboot.txt ($missing)"
	rm -rf "$d"
done

# Promoting a trial to permanent takes the trial file away with it. A stale one
# would be picked up by the next tryboot flag anybody sets, months later,
# pointing at whatever was being tried at the time.
d="$(mktemp -d)"; fixture "$d"
arm "$d" b
switch "$d" b
[ ! -e "$d/tryboot.txt" ] && ok "a permanent switch clears the trial file" || no "a permanent switch clears the trial file"
[ "$(prefix "$d")" = "os_prefix=nixos-b/default/" ] && ok "and config.txt names the promoted slot" || no "and config.txt names the promoted slot"
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]