#!/usr/bin/env bash
# Looks for a newer release on GitHub and puts it in the slot the box is not
# running from. It never switches and never reboots: that is one button on the
# management page, pressed by whoever is standing in front of the screen.
#
# It is opt-in. `autoUpdate` in settings.json is off until somebody turns it on,
# because this downloads half a gigabyte over whatever connection the box was
# given, and a box on a hall's guest wifi is not the place to do that unasked.
#
# The box is normally its own access point with no uplink at all, so the first
# thing this does is decide there is nothing to do -- most runs end in the first
# twenty lines, silently.
#
# Installed in the image as pesmarica-update-check and run by a timer; it also
# runs on a laptop against a fake tree, which is what tool/test_update_check.sh
# does. Hence every path being an environment variable with a default.
set -euo pipefail

FIRMWARE="${FIRMWARE:-/boot/firmware}"
RUNTIME="${RUNTIME:-/run/pesmarica}"
CLIENT_MARKER="${CLIENT_MARKER:-$RUNTIME/client}"
STATUS="${STATUS:-$RUNTIME/update.json}"
SLOT_FILE="${SLOT_FILE:-/etc/pesmarica-slot}"
SETTINGS="${SETTINGS:-/var/lib/pesmarica/settings.json}"
REPO="${PESMARICA_REPO:-dz0ny/pesmarica}"
API="${PESMARICA_API:-https://api.github.com}"

# The status file is what the web interface reads, and the only thing this
# script leaves behind. It is in tmpfs: a card that browns out every winter has
# no business holding a progress note, and a box that has just booted has
# nothing to say about an update it has not looked for yet.
say() { # say <state> [key=value ...]
	mkdir -p "$(dirname "$STATUS")"
	{
		printf '{"state":"%s"' "$1"
		shift
		for pair in "$@"; do
			[ -n "${pair#*=}" ] || continue
			printf ',"%s":"%s"' "${pair%%=*}" "${pair#*=}"
		done
		# +%Y-... rather than -Is: the same string out of both GNU date on the
		# box and BSD date on the laptop the test runs on.
		printf ',"checked":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$STATUS.tmp"
	mv "$STATUS.tmp" "$STATUS"
}

# -- which slot, and which version -------------------------------------------

running=$(tr -d '[:space:]' < "$SLOT_FILE" 2>/dev/null || true)
case "$running" in
	a) free=b ;;
	b) free=a ;;
	*) say failed "error=ta sistem ne pove, iz katerega razdelka teče"; exit 1 ;;
esac

# The marker the deploy and this script write last, holding the version that
# was installed. A card flashed from an image carries one too; anything else
# -- an older image, a slot half written -- reads as unknown, and then any
# release counts as newer. That costs one download and is self-correcting.
version_of() { # version_of <slot>
	{ head -1 "$FIRMWARE/nixos-$1/default/.complete" 2>/dev/null || true; } | tr -d '[:space:]'
}
have=$(version_of "$running")

# -- is there anything to do at all? ---------------------------------------

enabled=$(jq -r '.autoUpdate // false' "$SETTINGS" 2>/dev/null || echo false)
if [ "$enabled" != "true" ]; then
	say off "running=$have"
	exit 0
fi

# No marker means the box is its own access point, and being on a network is
# still not being on the internet -- a hall's wifi with a dead uplink looks
# exactly the same from here until the route is gone. Neither is a failure, and
# neither is worth a line in the journal an hour at a time; the page says so
# instead, which is where somebody is looking.
if [ ! -e "$CLIENT_MARKER" ] || ! ip route show default 2>/dev/null | grep -q .; then
	say offline "running=$have"
	exit 0
fi

# -- what is out there -------------------------------------------------------

release=$(curl -fsSL --max-time 30 --retry 2 \
	-H "Accept: application/vnd.github+json" \
	"$API/repos/$REPO/releases/latest" 2>/dev/null) || {
	say failed "running=$have" "error=do GitHuba ni bilo mogoče"
	exit 0
}

# jq rather than a regex: a release body is somebody's prose and it is in the
# same JSON. An answer that is not a release at all leaves this empty.
latest=$(printf '%s' "$release" | jq -r '.tag_name // empty' 2>/dev/null) || latest=""
[ -n "$latest" ] || { say failed "running=$have" "error=GitHub ni vrnil izdaje"; exit 0; }

# A release carries a payload per slot, and a system is built for the slot it
# lives in: the wrong one boots its own kernel against the previous squashfs.
asset_field() { # asset_field <key>
	printf '%s' "$release" |
		jq -r --arg p "pesmarica-system-$free-" --arg k "$1" \
			'[.assets[]? | select(.name | startswith($p) and endswith(".tar.zst"))][0][$k] // empty' \
		2>/dev/null || true
}
asset=$(asset_field browser_download_url)
size=$(asset_field size)

# Newer means a bigger vN, and anything unrecognised on either side means
# different-is-newer: an operator who tags v8.1 or moves a box between branches
# should get the release, not silence.
newer() { # newer <have> <latest>
	[ "$1" != "$2" ] || return 1
	if printf '%s' "$1" | grep -qE '^v[0-9]+$' && printf '%s' "$2" | grep -qE '^v[0-9]+$'; then
		[ "${2#v}" -gt "${1#v}" ] || return 1
	fi
	return 0
}

if ! newer "$have" "$latest"; then
	say current "running=$have" "available=$latest"
	exit 0
fi

# Already downloaded, waiting for somebody to press the button. Checking the
# free slot rather than remembering in tmpfs: a reboot forgets, and the card is
# what actually holds the answer.
if [ "$(version_of "$free")" = "$latest" ]; then
	say ready "running=$have" "available=$latest" "slot=$free"
	exit 0
fi

[ -n "$asset" ] || { say failed "running=$have" "available=$latest" "error=izdaja nima paketa za razdelek $free"; exit 0; }

# -- the download ------------------------------------------------------------

# The slot being replaced is emptied first and counted as free: while this is
# being written the running system is the fallback, and it is in the other
# slot. The size below is a guess at the unpacked tree, and the
# partition is sized for two slots, so this only ever catches a card that has
# been filled with something else.
#
# A quarter over the compressed size, not three times it: nearly all of the
# payload is rootfs.img, a zstd squashfs that barely shrinks again inside the
# tarball. Three times was enough to refuse every real release on a card that
# had room for it.
if [ -n "$size" ] && [ "$size" != "null" ]; then
	need=$(( size / 1024 * 5 / 4 + 32768 ))
	have_kb=$(df -k "$FIRMWARE" | awk 'NR==2 {print $4}')
	reclaim=$(du -sk "$FIRMWARE/nixos-$free" 2>/dev/null | awk '{s+=$1} END {print s+0}')
	if [ $(( have_kb + reclaim )) -lt "$need" ]; then
		say failed "running=$have" "available=$latest" "error=na kartici ni dovolj prostora"
		exit 0
	fi
fi

say downloading "running=$have" "available=$latest" "slot=$free"

rm -rf "${FIRMWARE:?}/nixos-$free"
mkdir -p "$FIRMWARE/nixos-$free"

# --no-same-owner/permissions: FAT carries neither, they come from the mount,
# and tar would fail trying to set them. --exclude .complete so the marker can
# only ever be the one written below: an archive that carried its own would
# make a download cut halfway look like a finished one, and the box would be
# pointed at a system that is missing its kernel.
if ! curl -fsSL --max-time 3600 "$asset" |
		zstd -dc |
		tar -C "$FIRMWARE/nixos-$free" -xf - \
			--exclude .complete --no-same-owner --no-same-permissions; then
	rm -rf "${FIRMWARE:?}/nixos-$free"
	say failed "running=$have" "available=$latest" "error=prenos ni uspel"
	exit 0
fi

for f in cmdline.txt initrd kernel.img rootfs.img; do
	[ -e "$FIRMWARE/nixos-$free/default/$f" ] && continue
	rm -rf "${FIRMWARE:?}/nixos-$free"
	say failed "running=$have" "available=$latest" "error=paket je nepopoln ($f)"
	exit 0
done

# Last, as in the deploy: its presence is what says the transfer ran to the
# end, and pesmarica-system-switch refuses a slot without it.
printf '%s\n' "$latest" > "$FIRMWARE/nixos-$free/default/.complete"
say ready "running=$have" "available=$latest" "slot=$free"
