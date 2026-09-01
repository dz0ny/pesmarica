#!/usr/bin/env bash
# Builds a flutter-pi bundle for a Raspberry Pi.
#
# flutter-pi does not consume `flutter build linux` output; it needs the
# Flutter asset bundle plus an AOT snapshot cross-compiled for the Pi's CPU.
# flutterpi_tool does exactly that from a normal Flutter SDK.
set -euo pipefail

# flutterpi_tool only builds against the Flutter version it was compiled for;
# the SDK is pinned to 3.44.x in mise.toml for that reason.
ARCH="${ARCH:-arm64}"      # arm64 for Pi 3/4/5 on a 64-bit OS, arm for 32-bit
CPU="${CPU:-pi3}"          # generic | pi3 | pi4 | pi5; Zero 2 W is pi3
MODE="${MODE:-release}"    # debug | profile | release

cd "$(dirname "$0")/.."

if ! command -v flutterpi_tool >/dev/null 2>&1; then
  echo "==> installing flutterpi_tool"
  dart pub global activate flutterpi_tool
  export PATH="$PATH:$HOME/.pub-cache/bin"
fi

echo "==> building $MODE bundle for $ARCH/$CPU"
flutterpi_tool build --arch="$ARCH" --cpu="$CPU" "--$MODE"

BUNDLE="$(dirname "$(find build/flutter-pi -name app.so -maxdepth 2 | head -1)")"

echo
echo "Bundle: $(pwd)/$BUNDLE"
echo "Copy it to the Pi together with the content/ folder, then run:"
echo "  flutter-pi --release /opt/pesmarica/bundle"
