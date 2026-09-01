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
  Here `cache.nixos.org` serves prebuilt aarch64 binaries for all of userland.
  Boot time and image size are the price, and were paid deliberately.
- **The kernel is still compiled here.** raspberry-pi-nix says its CI pushes
  kernel builds to `nix-community.cachix.org`, but the repo has not been touched
  since March 2025 and none of the three kernel versions it offers resolve in
  that cache or in `cache.nixos.org` -- all 404, most likely garbage collected.
  So the vendor kernel is a local build, the same as under buildroot. Since it
  costs a compile either way, `kernel-version` is pinned to the newest of the
  three (`v6_12_17`) rather than the March 2025 default.
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

## Writes to the card

The SD card is the part that dies, so in steady state the only thing that
reaches it is the songbook: the front matter the display stamps as pages are
shown, and `hostapd.conf` when someone changes the network in the web UI.

Everything else is in RAM -- the journal (`Storage=volatile`, capped at 16M),
`/tmp`, `/var/log`, and `/var/lib/systemd`, so the random seed and the DHCP
leases start fresh each boot. The root filesystem is mounted `noatime` with
`commit=600`, which lets ext4 batch ten minutes of metadata rather than
flushing every five seconds; a power cut then costs at most a view counter.

Activation used to be the largest remaining writer: NixOS rewrites the whole of
`/etc` on every boot. It no longer does. `system.etc.overlay` mounts `/etc`
from an erofs image in the store through a systemd stage-1 mount unit, with no
writable layer at all, which is the same copy-on-write shape composefs gives
you. `systemd.sysusers` then creates the accounts from that closure rather than
editing `/etc/passwd` in place, so the `users`, `groups` and `var` activation
scripts are empty and the `etc` one only runs on a configuration switch.

The root filesystem is still mounted read-write, because the songbook has to
land somewhere and it lives on it. Mounting the root read-only would mean a
separate data partition for `/var/lib/pesmarica`, which the sd-image module does
not produce -- worth doing, but it needs a card you can reflash while trying it.

## Known sharp edges

- **gcc segfaults inside the Nix build sandbox here**, and disabling the
  sandbox only moves the failure: cc1 has died on a trivial `int main(){}` in
  three different derivations (the kernel config step, flutter-pi, perl-env)
  while the same compiler builds it fine outside a build. The colima VM is
  allocated 12 GiB on a 16 GiB Mac, which is the first thing to suspect --
  try `colima start --memory 8` before hunting further. Reruns resume from the
  store, so a flaky build makes progress each time.

- **raspberry-pi-nix is stale** — last pushed March 2025, which pins this to
  NixOS 24.11, and its `board` option only knows `bcm2711`/`bcm2712`. The Zero
  2 W rides in as `bcm2711` (the same kernel config buildroot used) but is not a
  tested target there.
- **512 MB of RAM is the open question.** A NixOS userland plus the Flutter
  engine on a Zero 2 W has not been verified on hardware.
- The bundle `flutterpi_tool` produces lands in `build/flutter-pi/<cpu>/` and
  contains a prebuilt `flutter-pi` binary. We drop it and use the one from
  `pkgs/flutter-pi.nix`, linked against this system's libraries.
