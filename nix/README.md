# Pesmarica appliance image

Builds a bootable SD-card image for a **Raspberry Pi Zero 2 W**: NixOS,
flutter-pi, this app, and an access point people connect to in order to reach
the web interface. Flash it, power on, the songbook is on screen and
`Pesmarica` is in the wifi list.

This image is the single definition of the system. The unit files, the access
point, the addresses and the paths live here and nowhere else.

## Why this shape

- **NixOS over buildroot.** Buildroot produced a smaller, much faster-booting
  image, but every change meant compiling a kernel, mesa and systemd locally.
  Here `cache.nixos.org` serves prebuilt aarch64 binaries and raspberry-pi-nix's
  cachix serves the Raspberry Pi kernel, so nothing is compiled that somebody
  else already built. Boot time is the price, and it was paid deliberately.
- **The Flutter engine is not built from source.** flutter-pi `dlopen()`s
  `libflutter_engine.so` at runtime, so we take the prebuilt engine that
  `flutterpi_tool` puts in the app bundle and build only the embedder. Building
  the engine costs hours and tens of GB for a binary Google publishes.
- **Two build hosts.** The Dart AOT snapshotter only exists as an x86_64 binary,
  so the bundle is built on macOS under Rosetta; Nix itself runs inside the
  colima VM, which is aarch64 Linux and can therefore use the substituters.
- **Flutter is pinned to 3.44.x** in `../mise.toml`. `flutterpi_tool` compiles
  against `flutter_tools` internals, so a newer SDK does not warn — it fails to
  build. `scripts/build-bundle.sh` refuses to run outside 3.44.x.

## One-time setup

```bash
brew install colima docker
colima start --cpu 6 --memory 12 --disk 60
softwareupdate --install-rosetta   # only if not already installed
mise install                       # Flutter 3.44.4, pinned in ../mise.toml
```

## Build and flash

```bash
make image
```

```bash
diskutil list                    # find the card
make flash DISK=/dev/rdisk4      # note the r: raw device, much faster
```

## The access point

The box never joins a network — there is rarely one to join in the rooms this
ends up in, and a box waiting for an uplink is a box showing a blank screen.
Instead:

| Piece | Job |
|---|---|
| hostapd | the radio, from `/var/lib/pesmarica/hostapd.conf` |
| systemd-networkd | the address `192.168.4.1/24` and the DHCP pool |
| dnsmasq | every name resolves to the box, so phones open the captive-portal sheet on the songbook |

The web interface rewrites `hostapd.conf` and restarts hostapd. Because that is
the only way into the box, `pesmarica-ap-preflight` validates the file first and
restores the shipped default if it cannot work — a bad SSID typed into a phone
must not lock you out.

Change the shipped default (SSID `Pesmarica`, passphrase `pesmarica`, country
`SI`) in `modules/pesmarica.nix` before this leaves your desk.

## Iterating without reflashing

The unit runs the bundle from the nix store. `../tool/deploy_pi.sh` pushes a
working build to `/var/lib/pesmarica/bundle-override`, which the launcher
prefers when it exists:

```bash
HOST=root@192.168.4.1 ../tool/deploy_pi.sh
```

Delete that directory on the box to go back to the image's own bundle.

## Known sharp edges

- **raspberry-pi-nix is stale** — last pushed March 2025, which pins this to
  NixOS 24.11, and its `board` option only knows `bcm2711`/`bcm2712`. The Zero
  2 W rides in as `bcm2711` (the same kernel config buildroot used) but is not a
  tested target there.
- **512 MB of RAM is the open question.** A NixOS userland plus the Flutter
  engine on a Zero 2 W has not been verified on hardware.
- The bundle `flutterpi_tool` produces lands in `build/flutter-pi/<cpu>/` and
  contains a prebuilt `flutter-pi` binary. We drop it and use the one from
  `pkgs/flutter-pi.nix`, linked against this system's libraries.
