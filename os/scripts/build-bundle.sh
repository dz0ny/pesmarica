#!/usr/bin/env bash
# Builds the flutter-pi app bundle on the macOS host.
#
# Why not in the container: the Dart AOT snapshotter (gen_snapshot) is only
# published as an x86_64 binary for macOS and Linux, and flutterpi_tool drives
# the Flutter SDK's own build system. On Apple Silicon the x86_64 snapshotter
# runs under Rosetta -- `softwareupdate --install-rosetta` once, if needed.
#
# The SDK is pinned to 3.44.x in ../../mise.toml: flutterpi_tool compiles
# against flutter_tools internals and does not build against anything newer.
# `flutter upgrade` here breaks the image build; the check below catches it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ARCH="${ARCH:-arm64}"
CPU="${CPU:-pi3}"        # Zero 2 W is BCM2710, same core as the Pi 3
MODE="${MODE:-release}"

cd "$ROOT"

VERSION="$(flutter --version --machine | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p')"
case "$VERSION" in
	3.44.*) ;;
	*)
		echo "!! Flutter $VERSION found, but flutterpi_tool needs 3.44.x."
		echo "   Restore the pin:  mise install flutter@3.44.4-stable"
		exit 1
		;;
esac

if ! command -v flutterpi_tool >/dev/null 2>&1; then
	echo "==> installing flutterpi_tool"
	dart pub global activate flutterpi_tool
fi
export PATH="$PATH:$HOME/.pub-cache/bin"

echo "==> building $MODE bundle for $ARCH/$CPU with Flutter $VERSION"
flutterpi_tool build --arch="$ARCH" --cpu="$CPU" "--$MODE"

# flutterpi_tool writes to build/flutter-pi/<cpu>/, not build/flutter_assets.
BUNDLE="$(dirname "$(find "$ROOT/build/flutter-pi" -name app.so -maxdepth 2 | head -1)")"
[ -d "$BUNDLE" ] || { echo "!! no bundle with an app.so under $ROOT/build/flutter-pi"; exit 1; }

for f in app.so icudtl.dat libflutter_engine.so; do
	[ -e "$BUNDLE/$f" ] || { echo "!! $f missing from $BUNDLE"; exit 1; }
done

# Hand the path to the Makefile.
echo "$BUNDLE" > "$ROOT/build/flutter-pi/.bundle-path"

echo "==> bundle ready: $BUNDLE ($(du -sh "$BUNDLE" | cut -f1))"
