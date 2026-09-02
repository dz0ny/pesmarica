#!/usr/bin/env bash
# Exercises the boot-partition preconfiguration in nix/modules/pesmarica.nix.
#
# That script decides whether the box is a network or on one, which is the
# decision that can put it out of reach: it runs before anything else touches
# the radio, and everything downstream only reads the marker it leaves. The
# files it parses are typed on a laptop, so the cases here are the ones a
# laptop produces -- CRLF, a BOM, a passphrase with an = in it.
#
#   ./tool/test_boot_config.sh
#
# Same textual coupling as test_launcher.sh: it reads the block between the
# `writeShellApplication` name line and the end of its `text`. If that is
# reworded, reword it here too -- the script says so rather than silently
# testing nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODULE="$ROOT/nix/modules/pesmarica.nix"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BOOT="$WORK/boot"   # stands in for /boot/firmware
RUN="$WORK/run"     # for /run/pesmarica
NET="$WORK/net"     # for /run/systemd/network

# --- Render the script ----------------------------------------------------

BODY="$WORK/boot-config.sh"
NAMED="$(grep -n -F 'name = "pesmarica-boot-config"' "$MODULE" | cut -d: -f1 | head -1)"
[ -n "$NAMED" ] || {
	echo "!! could not find the boot config script in $MODULE -- has it been renamed?" >&2
	exit 1
}
START=""
while IFS=: read -r line _; do
	if [ "$line" -gt "$NAMED" ]; then START="$line"; break; fi
done < <(grep -n -F -x "    text = ''" "$MODULE")
END=""
while IFS=: read -r line _; do
	if [ -n "$START" ] && [ "$line" -gt "$START" ]; then END="$line"; break; fi
done < <(grep -n -F -x "    '';" "$MODULE")
[ -n "$START" ] && [ -n "$END" ] || {
	echo "!! no boot config script body in $MODULE" >&2
	exit 1
}

# Nix strips the common indentation from a '' string and unescapes ''${...};
# the store and runtime paths become directories under $WORK.
sed -n "$((START + 1)),$((END - 1))p" "$MODULE" |
	sed \
		-e 's/^      //' \
		-e "s|''\\\${|\${|g" \
		-e "s|/boot/firmware|$BOOT|g" \
		-e "s|\${runtimeDir}|$RUN|g" \
		-e "s|\${supplicantConf}|$RUN/wpa_supplicant.conf|g" \
		-e "s|\${clientMarker}|$RUN/client|g" \
		-e "s|\${rotationFile}|$RUN/rotation|g" \
		-e "s|\${clientNetwork}|$NET/10-wlan-client.network|g" \
		-e "s|/run/systemd/network|$NET|g" \
		> "$BODY.raw"
[ -s "$BODY.raw" ] || { echo "!! the boot config script came out empty" >&2; exit 1; }

if grep -nE '\$\{[a-zA-Z]' "$BODY.raw" | grep -vE '\$\{(1|2|WIFI|DISPLAY_CONF)\}' >&2; then
	echo "!! unsubstituted Nix interpolation above -- add it to the sed above" >&2
	exit 1
fi

# writeShellApplication supplies these, and shellcheck runs over the result at
# build time; here they have to be written out.
{
	echo '#!/usr/bin/env bash'
	echo 'set -euo pipefail'
	cat "$BODY.raw"
} > "$BODY"
chmod +x "$BODY"

# Stands in for wpa_supplicant's own hasher: same shape of output, including
# the cleartext comment line the script is expected to drop.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/wpa_passphrase" <<'STUB'
#!/usr/bin/env bash
printf 'network={\n\tssid="%s"\n\t#psk="%s"\n\tpsk=0123456789abcdef\n}\n' "$1" "$2"
STUB
chmod +x "$WORK/bin/wpa_passphrase"
export PATH="$WORK/bin:$PATH"

# --- Helpers --------------------------------------------------------------

FAILED=0
check() { # check <what> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf '  ok   %s\n' "$1"
	else
		printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3" >&2
		FAILED=1
	fi
}

boot() { # boot [--wifi <text>] [--display <text>]
	rm -rf "$BOOT" "$RUN" "$NET"
	mkdir -p "$BOOT" "$RUN" "$NET"
	while [ $# -gt 0 ]; do
		case "$1" in
			--wifi) printf '%b' "$2" > "$BOOT/wifi.conf"; shift 2 ;;
			--display) printf '%b' "$2" > "$BOOT/display.conf"; shift 2 ;;
			*) echo "boot: $1?" >&2; exit 1 ;;
		esac
	done
	bash "$BODY" >/dev/null 2>&1 || true
}

mode() { [ -e "$RUN/client" ] && echo client || echo "access point"; }
rotation() { cat "$RUN/rotation" 2>/dev/null || echo "(none)"; }
supplicant() { cat "$RUN/wpa_supplicant.conf" 2>/dev/null || true; }
mode_of() { # mode_of <file>: the permission bits, GNU or BSD stat
	stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo "(no file)"
}

# --- Cases ----------------------------------------------------------------

echo "== a card with nothing on it is an access point"
boot
check "stays an access point" "access point" "$(mode)"
check "and upright" "(none)" "$(rotation)"

echo "== a wifi.conf typed on Windows is still readable"
boot --wifi '\xef\xbb\xbfssid=Zupnija\r\npsk=nekogeslo\r\ncountry=SI\r\n'
check "joins the network" "client" "$(mode)"
check "past the byte order mark" 'ssid="Zupnija"' "$(supplicant | grep -o 'ssid="[^"]*"' | head -1)"
check "with the regulatory domain" "country=SI" "$(supplicant | grep '^country=' || true)"
check "and finds a hidden network" "1" "$(supplicant | grep -c 'scan_ssid=1')"

echo "== the passphrase is hashed, never copied"
boot --wifi 'ssid=Zupnija\npsk=nekogeslo\n'
check "no cleartext anywhere in it" "" "$(supplicant | grep -F 'nekogeslo' || true)"
check "and nobody but root may read it" "600" "$(mode_of "$RUN/wpa_supplicant.conf")"
check "while networkd can read its own" "644" "$(mode_of "$NET/10-wlan-client.network")"

echo "== an open network needs no passphrase"
boot --wifi 'ssid=Gost\n'
check "joins the network" "client" "$(mode)"
check "with no key management" "1" "$(supplicant | grep -c 'key_mgmt=NONE')"

echo "== a passphrase may contain an ="
boot --wifi 'ssid=Zupnija\npsk=a=b=cdefgh\n'
check "joins the network" "client" "$(mode)"

echo "== what wpa_supplicant would refuse is refused here"
boot --wifi 'ssid=Zupnija\npsk=kratko\n'
check "too short: stays reachable" "access point" "$(mode)"
boot --wifi "ssid=$(printf 'x%.0s' $(seq 33))\n"
check "ssid over 32 bytes: stays reachable" "access point" "$(mode)"

echo "== the screen is configured on its own"
boot --display 'rotation=270\r\n'
check "turned" "270" "$(rotation)"
check "without joining anything" "access point" "$(mode)"
boot --display 'rotation=45\n'
check "a rotation no panel is mounted at is ignored" "(none)" "$(rotation)"

echo "== last boot's decision is not this boot's"
mkdir -p "$RUN"
: > "$RUN/client"
: > "$RUN/rotation"
boot --wifi 'ssid=\n'
check "the marker is cleared" "access point" "$(mode)"
check "and so is the rotation" "(none)" "$(rotation)"

echo
if [ "$FAILED" = 0 ]; then
	echo "boot config: all cases pass"
else
	echo "boot config: FAILURES above" >&2
	exit 1
fi
