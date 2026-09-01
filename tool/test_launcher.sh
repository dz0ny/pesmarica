#!/usr/bin/env bash
# Exercises the slot picking and rollback in nix/modules/pesmarica.nix.
#
# That script is the half of the A/B updater that runs when the deployed app
# cannot, so it is the half worth testing -- and the one the Dart suite cannot
# reach. Building the image needs Docker and a real Zero 2 W; this needs
# neither. It lifts the launch script out of the module, substitutes the store
# paths for stubs, and runs it against slot directories it lays out itself.
#
#   ./tool/test_launcher.sh
#
# The coupling is textual: it reads the block between the `writeShellScript`
# line and its closing quotes. If that line is reworded, reword it here too --
# the script says so rather than silently testing nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODULE="$ROOT/nix/modules/pesmarica.nix"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SLOTS="$WORK/bundles"
STORE_BUNDLE="$WORK/store-bundle"
LAUNCHED="$WORK/launched"

# --- Render the launcher --------------------------------------------------

BODY="$WORK/launch.sh"
START="$(grep -n -F 'writeShellScript "pesmarica-launch"' "$MODULE" | cut -d: -f1 | head -1)"
[ -n "$START" ] || {
	echo "!! could not find the launch script in $MODULE -- has it been renamed?" >&2
	exit 1
}
# The first line that closes a Nix multi-line string after that point.
END=""
while IFS=: read -r line _; do
	if [ "$line" -gt "$START" ]; then END="$line"; break; fi
done < <(grep -n -F -x "  '';" "$MODULE")
[ -n "$END" ] || { echo "!! no end of the launch script in $MODULE" >&2; exit 1; }

sed -n "$((START + 1)),$((END - 1))p" "$MODULE" > "$BODY.raw"
[ -s "$BODY.raw" ] || { echo "!! the launch script came out empty" >&2; exit 1; }

# Nix escapes a shell ${...} as ''${...}; store paths become stubs.
sed \
	-e "s|''\\\${|\${|g" \
	-e 's|\${pkgs.coreutils}/bin/||g' \
	-e 's|\${pkgs.jq}/bin/jq|jq|g' \
	-e "s|\${slots}|$SLOTS|g" \
	-e 's|\${toString trialAttempts}|3|g' \
	-e "s|\${lib.getExe flutter-pi}|$WORK/flutter-pi-stub|g" \
	-e "s|\${bundle}|$STORE_BUNDLE|g" \
	"$BODY.raw" > "$BODY"

# Anything still referring to the Nix side would be tested as a literal string,
# which is worse than not testing it. Shell expansions survive on purpose.
if grep -nE '\$\{(pkgs\.|lib\.|toString |slots\}|bundle\})' "$BODY" >&2; then
	echo "!! unsubstituted Nix interpolation above -- add it to the sed below" >&2
	exit 1
fi
chmod +x "$BODY"

# Stands in for flutter-pi: records the bundle directory it was asked to run.
cat > "$WORK/flutter-pi-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\${@: -1}" > "$LAUNCHED"
STUB
chmod +x "$WORK/flutter-pi-stub"

mkdir -p "$STORE_BUNDLE"

# --- Helpers --------------------------------------------------------------

fill() { # fill <slot> [--incomplete]
	local dir="$SLOTS/$1"
	mkdir -p "$dir"
	touch "$dir/app.so" "$dir/icudtl.dat" "$dir/libflutter_engine.so"
	[ "${2:-}" = --incomplete ] || printf 'ok\n' > "$dir/.complete"
}

reset() {
	rm -rf "$SLOTS" "$LAUNCHED"
	mkdir -p "$SLOTS"
}

run() { bash "$BODY" >/dev/null 2>&1 || true; }

ran() { cat "$LAUNCHED" 2>/dev/null || echo "(nothing)"; }

pointer() { tr -d '[:space:]' < "$SLOTS/active" 2>/dev/null || echo "(none)"; }

FAILED=0
check() { # check <what> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf '  ok   %s\n' "$1"
	else
		printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3" >&2
		FAILED=1
	fi
}

# --- Cases ----------------------------------------------------------------

echo "== a card nobody has deployed to runs the image's own bundle"
reset
run
check "runs the store bundle" "$STORE_BUNDLE" "$(ran)"

echo "== a deployed slot is what runs"
reset
fill b
printf 'b\n' > "$SLOTS/active"
run
check "runs slot b" "$SLOTS/b" "$(ran)"

echo "== a bundle on trial is given its attempts, then reverted"
reset
fill a; fill b
printf 'b\n' > "$SLOTS/active"
printf '0\n' > "$SLOTS/trial"
run; check "attempt 1 runs the new slot" "$SLOTS/b" "$(ran)"
run; check "attempt 2 runs the new slot" "$SLOTS/b" "$(ran)"
run; check "attempt 3 runs the new slot" "$SLOTS/b" "$(ran)"
run
check "the fourth start reverts" "$SLOTS/a" "$(ran)"
check "and the pointer follows" "a" "$(pointer)"
check "and the trial is over" "gone" "$([ -f "$SLOTS/trial" ] && echo present || echo gone)"

echo "== a bundle that comes up clears the trial and is never reverted"
reset
fill a; fill b
printf 'b\n' > "$SLOTS/active"
printf '0\n' > "$SLOTS/trial"
run
rm -f "$SLOTS/trial"        # what the app does once it has drawn a frame
for _ in 1 2 3 4 5; do run; done
check "still on the new slot" "$SLOTS/b" "$(ran)"
check "pointer untouched" "b" "$(pointer)"

echo "== an upload cut short is not mistaken for a bundle"
reset
fill a
fill b --incomplete
printf 'b\n' > "$SLOTS/active"
run
check "falls back to the complete slot" "$SLOTS/a" "$(ran)"
check "and repoints at it" "a" "$(pointer)"

echo "== both slots unusable falls back to the store"
reset
fill a --incomplete
fill b --incomplete
printf 'a\n' > "$SLOTS/active"
run
check "runs the store bundle" "$STORE_BUNDLE" "$(ran)"

echo "== a garbled pointer does not strand the box"
reset
fill a
printf 'nonsense\n' > "$SLOTS/active"
run
check "runs slot a" "$SLOTS/a" "$(ran)"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "launcher: all cases pass"
else
	echo "launcher: FAILURES above" >&2
	exit 1
fi
