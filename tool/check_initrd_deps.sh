#!/usr/bin/env bash
# Checks that everything the initrd's own scripts call is actually in the initrd.
#
# The initrd is built from a list of store paths, and the list is not read: a
# service script goes in whole, but a binary it calls only comes along if
# somebody named it separately in boot.initrd.systemd.storePaths. Miss that and
# nothing complains until the box is on a shelf -- the service exits 127, the
# mount that requires it fails, and the screen shows a few unit lines and then
# nothing. v13 shipped exactly that, and it cost a card reader trip.
#
# So: unpack the built initrd, read every unit-script-* in it, and check that
# each /nix/store path they name is present. Only the scripts, deliberately --
# a unit file's Environment= may point at a locale archive that is genuinely
# not needed and genuinely not there.
#
#   tool/check_initrd_deps.sh nix/out/firmware/nixos/default/initrd
#
# Runs wherever the initrd was built, which in practice is CI: this needs an
# aarch64 Linux builder, so it is the one check here that cannot run on a
# laptop against a stub.
set -uo pipefail

IMG="${1:?usage: check_initrd_deps.sh <initrd>}"
[ -r "$IMG" ] || { echo "!! $IMG is not readable" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# The compressor is a NixOS option, so do not assume it. The magic bytes say.
magic="$(head -c 4 "$IMG" | od -An -tx1 | tr -d ' \n')"
case "$magic" in
	28b52ffd*) zstd -dc "$IMG" > "$WORK/cpio" 2>/dev/null ;;
	1f8b*)     gzip -dc "$IMG" > "$WORK/cpio" 2>/dev/null ;;
	fd377a58*) xz -dc   "$IMG" > "$WORK/cpio" 2>/dev/null ;;
	*)         cp "$IMG" "$WORK/cpio" ;;
esac
[ -s "$WORK/cpio" ] || { echo "!! could not decompress $IMG (magic $magic)" >&2; exit 1; }

mkdir "$WORK/root"
if command -v cpio >/dev/null 2>&1; then
	(cd "$WORK/root" && cpio -idm --quiet < "$WORK/cpio") 2>/dev/null
elif command -v bsdtar >/dev/null 2>&1; then
	bsdtar -xf "$WORK/cpio" -C "$WORK/root" 2>/dev/null
else
	echo "!! neither cpio nor bsdtar is here; cannot unpack the initrd" >&2; exit 1
fi

shopt -s nullglob
scripts=("$WORK"/root/nix/store/*-unit-script-*/bin/*)
shopt -u nullglob
[ ${#scripts[@]} -gt 0 ] || { echo "!! no unit scripts in $IMG; is this an initrd?" >&2; exit 1; }

missing=0
for s in "${scripts[@]}"; do
	[ -f "$s" ] || continue
	# The shebang counts too: an interpreter that is not there fails the same
	# way, and is just as easy to leave out.
	refs=$({ head -1 "$s" | sed 's|^#!||'; cat "$s"; } |
		grep -oh '/nix/store/[a-z0-9]\{32\}-[^ "'"'"'`)]*' | sort -u)
	for ref in $refs; do
		# A reference may name a file inside a package; the package is what the
		# initrd either has or has not.
		rest="${ref#/nix/store/}"
		pkg="/nix/store/${rest%%/*}"
		script="$(basename "$(dirname "$(dirname "$s")")")"
		script="${script#*-unit-script-}"
		if [ -e "$WORK/root$ref" ] || [ -e "$WORK/root$pkg" ]; then
			printf '  ok      %s -> %s\n' "$script" "${rest%%/*}"
		else
			printf '  MISSING %s calls %s\n' "$script" "$ref"
			missing=$((missing + 1))
		fi
	done
done

printf '\n%d initrd script(s) checked' "${#scripts[@]}"
if [ "$missing" -gt 0 ]; then
	printf ', %d dependency the initrd does not carry.\n' "$missing"
	printf 'Add it to boot.initrd.systemd.storePaths in nix/modules/pesmarica.nix.\n'
	exit 1
fi
printf ', every dependency present.\n'
