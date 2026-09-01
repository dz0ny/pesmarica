#!/usr/bin/env bash
# Pushes a new build onto an appliance that is already running the image.
#
# This does NOT install anything: the system layout — the unit, the network, the
# paths — is defined once, by the NixOS image in `nix/`. Rebuilding the image is
# how you change the system; this is how you change the app between reflashes.
#
#   HOST=root@pesmarica.local ./tool/deploy_pi.sh
#
# The bundle goes into whichever of the two slots is *not* running, and only
# then does the box get pointed at it — so an interrupted deploy leaves the
# appliance on the bundle it was already running, and a bundle that never draws
# a frame is reverted by the launcher after a few tries. See
# lib/src/update/bundle_slots.dart for the on-disk format.
#
# The songbook is synced without --delete, because pages created on the box
# through the web interface must survive a redeploy.
set -euo pipefail

HOST="${HOST:?set HOST=root@pesmarica.local}"

# If you change these, change nix/modules/pesmarica.nix, not this script.
SLOTS_DIR="${SLOTS_DIR:-/var/lib/pesmarica/bundles}"
CONTENT_DIR="${CONTENT_DIR:-/var/lib/pesmarica}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

"$ROOT/nix/scripts/build-bundle.sh"
BUNDLE="$(cat "$ROOT/build/flutter-pi/.bundle-path")"

# What the web interface will call this build.
VERSION="${VERSION:-$(git -C "$ROOT" describe --always --dirty 2>/dev/null || date +%Y-%m-%d)}"

# Ask the box which slot is free rather than guessing: the web interface can
# have flipped it since the last deploy.
ACTIVE="$(ssh "$HOST" "cat $SLOTS_DIR/active 2>/dev/null | tr -d '[:space:]'" || true)"
case "$ACTIVE" in
	a) SLOT=b ;;
	*) SLOT=a ;;
esac

echo "==> $HOST:$SLOTS_DIR/$SLOT ($VERSION)"
# --delete: a bundle is a set of files that have to match each other, and a
# leftover from two versions ago is exactly the kind of thing that works until
# it doesn't. The markers go last, so a cut-short rsync leaves an unusable slot
# rather than a plausible one.
ssh "$HOST" "mkdir -p $SLOTS_DIR/$SLOT"
rsync -a --delete --exclude flutter-pi --exclude .last_build_id \
	--exclude .complete --exclude .version \
	"$BUNDLE/" "$HOST:$SLOTS_DIR/$SLOT/"

echo "==> $HOST:$CONTENT_DIR"
rsync -a "$ROOT/content/" "$HOST:$CONTENT_DIR/"

# Mark the slot complete, arm the trial, then flip the pointer — the same order
# the app's own installer uses, and the flip is a rename.
ssh "$HOST" "
	set -e
	cd $SLOTS_DIR/$SLOT
	for f in app.so icudtl.dat libflutter_engine.so; do
		[ -f \"\$f\" ] || { echo \"!! \$f missing from the deployed slot\" >&2; exit 1; }
	done
	printf '%s\n' '$VERSION' > .version
	printf 'ok\n' > .complete
	printf '0\n' > $SLOTS_DIR/trial
	printf '%s\n' '$SLOT' > $SLOTS_DIR/active.tmp
	mv $SLOTS_DIR/active.tmp $SLOTS_DIR/active
	systemctl restart pesmarica
	systemctl --no-pager status pesmarica | head -12
"
