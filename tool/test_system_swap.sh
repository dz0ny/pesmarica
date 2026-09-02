#!/usr/bin/env bash
# Covers tool/system_swap.sh against fake boot partitions.
#
# The nix half of a system update cannot be built or booted here -- it needs an
# aarch64 builder and a real Zero 2 W -- but the swap can, and the swap is the
# part that decides whether a box comes back. Every refusal below is a card
# reader trip that did not happen.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWAP="$HERE/system_swap.sh"

pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# A boot partition with a live system, and optionally a complete staged one.
fixture() { # fixture <dir> [staged]
	local d="$1"
	mkdir -p "$d/nixos/default/overlays"
	printf 'old\n' > "$d/nixos/default/kernel.img"
	touch "$d/nixos/default"/{initrd,cmdline.txt,rootfs.img} \
		"$d/nixos/default/bcm2710-rpi-zero-2-w.dtb" \
		"$d/nixos/default/overlays/vc4-kms-v3d.dtbo"
	[ "${2:-}" = staged ] || return 0
	mkdir -p "$d/nixos/default.new/overlays"
	printf 'new\n' > "$d/nixos/default.new/kernel.img"
	touch "$d/nixos/default.new"/{initrd,cmdline.txt,rootfs.img,.complete} \
		"$d/nixos/default.new/bcm2710-rpi-zero-2-w.dtb" \
		"$d/nixos/default.new/overlays/vc4-kms-v3d.dtbo"
}

swap() { FIRMWARE="$1" bash "$SWAP" >/dev/null 2>&1; }

# -- the good case ----------------------------------------------------------

d="$(mktemp -d)"; fixture "$d" staged
if swap "$d"; then ok "a complete payload swaps in"; else no "a complete payload swaps in"; fi
[ "$(cat "$d/nixos/default/kernel.img")" = new ] \
	&& ok "the new system is the one that boots" \
	|| no "the new system is the one that boots"
[ "$(cat "$d/nixos/default.old/kernel.img")" = old ] \
	&& ok "the previous system is kept" \
	|| no "the previous system is kept"
[ ! -e "$d/nixos/default.new" ] \
	&& ok "the staging directory is gone" \
	|| no "the staging directory is gone"
rm -rf "$d"

# -- what an interrupted transfer looks like --------------------------------

# Each of these is a file the Pi firmware loads by name out of os_prefix. The
# marker is the one that catches an rsync killed part way, since it is written
# after everything else.
for missing in .complete kernel.img initrd cmdline.txt rootfs.img; do
	d="$(mktemp -d)"; fixture "$d" staged
	rm -f "$d/nixos/default.new/$missing"
	if swap "$d"; then no "refuses a payload with no $missing"; else ok "refuses a payload with no $missing"; fi
	[ "$(cat "$d/nixos/default/kernel.img")" = old ] \
		&& ok "and leaves the running system alone ($missing)" \
		|| no "and leaves the running system alone ($missing)"
	rm -rf "$d"
done

d="$(mktemp -d)"; fixture "$d" staged
rm -f "$d"/nixos/default.new/*.dtb
if swap "$d"; then no "refuses a payload with no device tree"; else ok "refuses a payload with no device tree"; fi
rm -rf "$d"

d="$(mktemp -d)"; fixture "$d" staged
rm -rf "$d/nixos/default.new/overlays"
if swap "$d"; then no "refuses a payload with no overlays"; else ok "refuses a payload with no overlays"; fi
rm -rf "$d"

# -- pointed at something that is not a running box -------------------------

d="$(mktemp -d)"; mkdir -p "$d/nixos"
if swap "$d"; then no "refuses when there is nothing staged"; else ok "refuses when there is nothing staged"; fi
rm -rf "$d"

d="$(mktemp -d)"; fixture "$d" staged; rm -rf "$d/nixos/default"
if swap "$d"; then no "refuses when there is no live system"; else ok "refuses when there is no live system"; fi
rm -rf "$d"

# -- a box that has been updated before -------------------------------------

d="$(mktemp -d)"; fixture "$d" staged
mkdir -p "$d/nixos/default.old"; printf 'ancient\n' > "$d/nixos/default.old/kernel.img"
swap "$d"
[ "$(cat "$d/nixos/default.old/kernel.img")" = old ] \
	&& ok "only one previous system is kept" \
	|| no "only one previous system is kept"
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
