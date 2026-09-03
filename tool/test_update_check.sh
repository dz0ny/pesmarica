#!/usr/bin/env bash
# Covers nix/scripts/update_check.sh against a fake boot partition and a fake
# GitHub. The nix half of the appliance cannot be built or booted here, but the
# updater is a shell script that takes every path from the environment, so it
# can be run as it is -- with curl and ip replaced by stubs on PATH.
#
#   ./tool/test_update_check.sh
#
# What is worth pinning is not that a download works, but that a download going
# wrong costs only the slot the box is not running from: half a release, a dead
# uplink or an archive carrying its own .complete must never leave a slot that
# pesmarica-system-switch would accept.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$ROOT/nix/scripts/update_check.sh"

for tool in jq zstd tar curl; do
	command -v "$tool" >/dev/null || { echo "!! $tool is needed to run this" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
is() { # is <what> <expected> <actual>
	if [ "$2" = "$3" ]; then ok "$1"; else
		printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3" >&2
		fail=$((fail + 1))
	fi
}

# --- A release, and the stubs that serve it -------------------------------

# The payload a release carries per slot: one directory, `default`, holding
# what the firmware loads by name. .complete is in it on purpose -- the
# updater must not let the archive's own marker land.
payload() { # payload <tar.zst path> [missing file]
	local out="$1" skip="${2:-}" d="$WORK/payload"
	rm -rf "$d"; mkdir -p "$d/default/overlays"
	for f in cmdline.txt initrd kernel.img rootfs.img bcm2710-rpi-zero-2-w.dtb; do
		[ "$f" = "$skip" ] || echo "$f" > "$d/default/$f"
	done
	echo "v99" > "$d/default/.complete"
	touch "$d/default/overlays/vc4-kms-v3d.dtbo"
	(cd "$d" && tar -cf - default) | zstd -q -o "$out" -f
}

release_json() { # release_json <tag> [slot ...]
	local tag="$1"; shift
	local assets=""
	for slot in "$@"; do
		[ -z "$assets" ] || assets="$assets,"
		assets="$assets{\"name\":\"pesmarica-system-$slot-abc1234.tar.zst\",\"size\":4096,\"browser_download_url\":\"https://example.invalid/$slot.tar.zst\"}"
	done
	printf '{"tag_name":"%s","assets":[%s]}\n' "$tag" "$assets"
}

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
# The last argument is the URL; everything before it is flags we ignore.
url="${!#}"
echo "$url" >> "$CALLS"
case "$url" in
	*/releases/latest) cat "$RELEASE" ;;
	*) [ "${DOWNLOAD_FAILS:-}" = 1 ] && exit 7; cat "$ASSET" ;;
esac
STUB
cat > "$WORK/bin/ip" <<'STUB'
#!/usr/bin/env bash
[ "${HAS_ROUTE:-1}" = 1 ] && echo "default via 192.168.1.1 dev wlan0"
exit 0
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/ip"
export PATH="$WORK/bin:$PATH"

# --- The box --------------------------------------------------------------

BOOT="$WORK/boot"
RUN="$WORK/run"
export FIRMWARE="$BOOT" RUNTIME="$RUN"
export STATUS="$RUN/update.json"
export CLIENT_MARKER="$RUN/client"
export SLOT_FILE="$WORK/pesmarica-slot"
export SETTINGS="$WORK/settings.json"
export PESMARICA_API="https://example.invalid"
export RELEASE="$WORK/release.json" ASSET="$WORK/asset.tar.zst" CALLS="$WORK/calls"

box() { # box [--running <version>] [--staged <version>] [--auto <true|false>]
	rm -rf "$BOOT" "$RUN"; mkdir -p "$BOOT/nixos-a/default" "$BOOT/nixos-b/default" "$RUN"
	echo a > "$SLOT_FILE"
	: > "$CALLS"
	touch "$RUN/client"
	local auto=true
	while [ $# -gt 0 ]; do
		case "$1" in
			--running) [ "$2" = "-" ] || echo "$2" > "$BOOT/nixos-a/default/.complete"; shift 2 ;;
			--staged) echo "$2" > "$BOOT/nixos-b/default/.complete"; shift 2 ;;
			--auto) auto="$2"; shift 2 ;;
			*) echo "box: $1?" >&2; exit 1 ;;
		esac
	done
	printf '{"autoUpdate": %s}\n' "$auto" > "$SETTINGS"
	# Something in the running slot, so "the running slot is untouched" means
	# something.
	echo kernel > "$BOOT/nixos-a/default/kernel.img"
	payload "$ASSET"
}

run() { bash "$CHECK" >/dev/null 2>&1; }
state() { jq -r '.state' "$STATUS" 2>/dev/null || echo "(no status)"; }
field() { jq -r ".$1 // \"\"" "$STATUS" 2>/dev/null; }
staged() { cat "$BOOT/nixos-b/default/.complete" 2>/dev/null || echo "(none)"; }
downloads() { grep -c 'tar.zst' "$CALLS" || true; }

# --- Nothing to do --------------------------------------------------------

box --running v7 --auto false; release_json v8 a b > "$RELEASE"; run
is "off until somebody turns it on" off "$(state)"
is "and nothing is downloaded" 0 "$(downloads)"

box --running v7; release_json v8 a b > "$RELEASE"; rm -f "$RUN/client"; run
is "an access point has no uplink to ask over" offline "$(state)"
is "and nothing is downloaded" 0 "$(downloads)"

box --running v7; release_json v8 a b > "$RELEASE"; HAS_ROUTE=0 run
is "on a network is not on the internet" offline "$(state)"
is "and nothing is downloaded" 0 "$(downloads)"

box --running v8; release_json v8 a b > "$RELEASE"; run
is "the running version is the latest" current "$(state)"
is "and nothing is downloaded" 0 "$(downloads)"

box --running v10; release_json v9 a b > "$RELEASE"; run
is "v10 is newer than v9, not older" current "$(state)"

box --running v7 --staged v8; release_json v8 a b > "$RELEASE"; run
is "an update already in the slot is not fetched twice" ready "$(state)"
is "and nothing is downloaded" 0 "$(downloads)"
is "the slot it names is the free one" b "$(field slot)"

# --- The download ---------------------------------------------------------

box --running v7; release_json v8 a b > "$RELEASE"; run
is "a newer release lands in the free slot" ready "$(state)"
is "the marker holds the release, not the archive's own" v8 "$(staged)"
is "the version it came from is reported" v7 "$(field running)"
[ -e "$BOOT/nixos-b/default/kernel.img" ] && ok "the payload is unpacked" || no "the payload is unpacked"
[ "$(cat "$BOOT/nixos-a/default/kernel.img")" = kernel ] && ok "the running slot is untouched" || no "the running slot is untouched"
[ -e "$BOOT/nixos-a/default/.complete" ] && ok "and keeps its own marker" || no "and keeps its own marker"

box --running -; release_json v8 a b > "$RELEASE"; run
is "a system that does not say its version takes the release" ready "$(state)"

box --running v7; release_json v8 a > "$RELEASE"; run
is "a release with no payload for the free slot is refused" failed "$(state)"
[ ! -e "$BOOT/nixos-b/default/.complete" ] && ok "and stages nothing" || no "and stages nothing"

# --- When it goes wrong ---------------------------------------------------

box --running v7; release_json v8 a b > "$RELEASE"; DOWNLOAD_FAILS=1 run
is "a download that dies is a failure" failed "$(state)"
[ ! -d "$BOOT/nixos-b/default" ] && ok "and leaves no slot to switch to" || no "and leaves no slot to switch to"
[ "$(cat "$BOOT/nixos-a/default/kernel.img")" = kernel ] && ok "and costs the running slot nothing" || no "and costs the running slot nothing"

box --running v7; release_json v8 a b > "$RELEASE"; payload "$ASSET" kernel.img; run
is "a payload without a kernel is a failure" failed "$(state)"
[ ! -d "$BOOT/nixos-b/default" ] && ok "and is thrown away rather than left" || no "and is thrown away rather than left"

box --running v7; echo 'not json' > "$RELEASE"; run
is "an answer that is not a release is a failure" failed "$(state)"
is "and nothing is downloaded" 0 "$(downloads)"

box --running v7; release_json v8 a b > "$RELEASE"; echo c > "$SLOT_FILE"; run
is "a box that cannot say which slot it runs is a failure" failed "$(state)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
