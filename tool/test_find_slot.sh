#!/usr/bin/env bash
# Covers nix/scripts/find_slot.sh against fake boot partitions.
#
# This is the one answer the whole slot machinery rests on now that a system is
# no longer built for a slot: get it wrong and the initrd loop-mounts the other
# slot's store against this kernel, which is a card reader trip. Every case
# below is one the box can actually be in.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIND="$ROOT/nix/scripts/find_slot.sh"
pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

SYS_A=/nix/store/aaaaaaaa-nixos-system-pesmarica-25.11
SYS_B=/nix/store/bbbbbbbb-nixos-system-pesmarica-25.11

# A boot partition with a system in each slot, config.txt naming a.
fixture() { # fixture <dir> <system in a> <system in b>
	local d="$1"
	printf 'kernel=kernel.img\nos_prefix=nixos-a/default/\n' > "$d/config.txt"
	mkdir -p "$d/nixos-a/default" "$d/nixos-b/default"
	printf '%s\n' "$2" > "$d/nixos-a/default/system-link"
	printf '%s\n' "$3" > "$d/nixos-b/default/system-link"
}
# What the firmware handed the kernel out of the slot holding <system>.
cmdline() { # cmdline <dir> <system>
	printf 'console=tty0 loglevel=4 init=%s/init\n' "$2" > "$d/cmdline"
}
find_slot() { FIRMWARE="$1" CMDLINE="$d/cmdline" bash "$FIND" 2>/dev/null; }

d="$(mktemp -d)"; fixture "$d" "$SYS_A" "$SYS_B"
cmdline "$d" "$SYS_A"
[ "$(find_slot "$d")" = a ] && ok "the slot holding this system is the one we run" \
	|| no "the slot holding this system is the one we run"
cmdline "$d" "$SYS_B"
[ "$(find_slot "$d")" = b ] && ok "and the same the other way round" \
	|| no "and the same the other way round"

# A trial boot: the firmware came through tryboot.txt, so config.txt still
# names the slot the box came from. The answer must be where we actually are,
# or nothing would ever be promoted.
cmdline "$d" "$SYS_B"
[ "$(find_slot "$d")" = b ] && ok "a trial boot says where it actually is" \
	|| no "a trial boot says where it actually is"
rm -rf "$d"

# Two deploys of one release leave the same system in both slots. Either answer
# boots the same bytes, so the tie goes to config.txt: a box that is not on
# trial must not look like one.
d="$(mktemp -d)"; fixture "$d" "$SYS_A" "$SYS_A"; cmdline "$d" "$SYS_A"
[ "$(find_slot "$d")" = a ] && ok "the same system in both slots follows config.txt" \
	|| no "the same system in both slots follows config.txt"
printf 'kernel=kernel.img\nos_prefix=nixos-b/default/\n' > "$d/config.txt"
[ "$(find_slot "$d")" = b ] && ok "and follows it the other way too" \
	|| no "and follows it the other way too"
rm -rf "$d"

# A slot that was never written, or emptied by a download that went wrong.
d="$(mktemp -d)"; fixture "$d" "$SYS_A" "$SYS_B"; cmdline "$d" "$SYS_A"
rm -rf "$d/nixos-b"
[ "$(find_slot "$d")" = a ] && ok "an empty free slot changes nothing" \
	|| no "an empty free slot changes nothing"
rm -rf "$d"

# Nothing on the card holds what we booted. There is no honest answer, and a
# guess would mount the wrong store -- so say so and stop.
d="$(mktemp -d)"; fixture "$d" "$SYS_A" "$SYS_B"; cmdline "$d" /nix/store/cccccccc-nixos-system
if find_slot "$d" >/dev/null; then no "refuses when no slot holds this system"; else ok "refuses when no slot holds this system"; fi

printf 'console=tty0 loglevel=4\n' > "$d/cmdline"
if find_slot "$d" >/dev/null; then no "refuses a cmdline with no init="; else ok "refuses a cmdline with no init="; fi
rm -rf "$d"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
