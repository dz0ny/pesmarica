#!/usr/bin/env bash
# Pushes a new build onto an appliance that is already running the image.
#
# This does NOT install anything: the system layout — the unit, the mount, the
# paths — is defined once, by the image in `os/`. Reflashing is how you change
# the system; this is how you change the app between reflashes.
#
#   HOST=root@pesmarica.local ./tool/deploy_pi.sh
#
# The songbook is synced without --delete, because pages created on the box
# through the web interface must survive a redeploy.
set -euo pipefail

HOST="${HOST:?set HOST=root@pesmarica.local}"

# These mirror os/external/board/pesmarica/rootfs-overlay. If you change one,
# change the image, not this script.
BUNDLE_DIR="${BUNDLE_DIR:-/opt/pesmarica/bundle}"
CONTENT_DIR="${CONTENT_DIR:-/var/lib/pesmarica}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

"$ROOT/os/scripts/build-bundle.sh"
BUNDLE="$(cat "$ROOT/build/flutter-pi/.bundle-path")"

echo "==> $HOST:$BUNDLE_DIR"
rsync -a --delete --exclude flutter-pi --exclude .last_build_id \
	"$BUNDLE/" "$HOST:$BUNDLE_DIR/"

echo "==> $HOST:$CONTENT_DIR"
rsync -a "$ROOT/content/" "$HOST:$CONTENT_DIR/"

ssh "$HOST" 'systemctl restart pesmarica && systemctl --no-pager status pesmarica | head -12'
