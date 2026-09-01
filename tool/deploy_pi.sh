#!/usr/bin/env bash
# Ships the bundle, the songbook and the systemd unit to a Pi over SSH.
#
#   HOST=pi@signage.local ./tool/deploy_pi.sh
#
# The songbook is synced without --delete: pages created on the Pi through the
# web interface must survive a redeploy.
set -euo pipefail

HOST="${HOST:?set HOST=user@hostname}"
PREFIX="${PREFIX:-/opt/pesmarica}"
CONTENT="${CONTENT:-/var/lib/pesmarica}"

cd "$(dirname "$0")/.."
[ -d build/flutter_assets ] || ./tool/build_pi.sh

echo "==> $HOST:$PREFIX"
ssh "$HOST" "sudo mkdir -p $PREFIX/bundle $CONTENT && sudo chown -R \$(id -u):\$(id -g) $PREFIX $CONTENT"
rsync -a --delete build/flutter_assets/ "$HOST:$PREFIX/bundle/"
rsync -a content/ "$HOST:$CONTENT/"
rsync -a packaging/pesmarica.service "$HOST:/tmp/pesmarica.service"

ssh "$HOST" "sudo install -m644 /tmp/pesmarica.service /etc/systemd/system/pesmarica.service \
  && sudo systemctl daemon-reload \
  && sudo systemctl enable --now pesmarica \
  && sudo systemctl restart pesmarica \
  && systemctl --no-pager status pesmarica | head -20"
