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
- **The kernel comes prebuilt.** This uses
  [nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi) rather than
  raspberry-pi-nix, for one checkable reason: its cache actually has the kernel
  in it. raspberry-pi-nix advertises the same thing, but every path it offers
  404s -- collected, most likely, in the year and a half since that repo was
  last touched. Here both the kernel and the Pi firmware resolve in
  `nixos-raspberrypi.cachix.org`, so flutter-pi is the only thing compiled.
- **The Zero 2 W is a real target here.** `raspberry-pi-02.base` builds
  `linux_rpi02` for it; under raspberry-pi-nix it had to ride in as `bcm2711`,
  a Pi 4 board that happens to boot on one.
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
| hostapd | the radio, from `hostapd.conf` on the songbook partition |
| systemd-networkd | the address `192.168.4.1/24` and the DHCP pool |
| dnsmasq | every name resolves to the box, so phones open the captive-portal sheet on the songbook |

The web interface rewrites `hostapd.conf` and restarts hostapd. Because that is
the only way into the box, `pesmarica-ap-preflight` validates the file first and
restores the shipped default if it cannot work — a bad SSID typed into a phone
must not lock you out.

Change the shipped default (SSID `Pesmarica`, passphrase `pesmarica`, country
`SI`) in `modules/pesmarica.nix` before this leaves your desk.

## Iterating without reflashing

The unit runs the bundle from the nix store until something is deployed.
`../tool/deploy_pi.sh` pushes a working build into one of two slots under
`/var/lib/pesmarica/bundles`, which the launcher prefers over the store copy:

```bash
HOST=root@192.168.4.1 ../tool/deploy_pi.sh
```

Empty that directory on the box to go back to the image's own bundle.

The two slots are the update mechanism, not just a deploy target. A deploy
fills the slot that is *not* running and flips `bundles/active` at it last, so
an interrupted push leaves the box on the build it was already running; and the
launcher reverts to the previous slot if the new one fails to draw a frame three
starts running. `bundles/trial` is what counts those starts — the app deletes it
once it is up. The format is documented in `lib/src/update/bundle_slots.dart`,
and `../tool/test_launcher.sh` exercises the launcher's half of it without a Pi.

## Writes to the card

The SD card is the part that dies, so in steady state nothing reaches it at all.
The display used to stamp a view counter and a timestamp into the front matter
after a page had been up for a few seconds, which meant a service wrote to the
card every few minutes to record something nobody read; it does not any more.
What is left is the songbook, written when a human edits a page, and
`hostapd.conf` when someone changes the network.

The songbook is not on the root filesystem at all. The image carries a third
partition labelled `PESMARICA` -- FAT32, 512 MiB, with the songbook and
`hostapd.conf` already written into it by `mtools` at build time -- and
`pesmarica-data` grows it into the rest of the card on the first boot with
`fatresize`, once, ever. `/var/lib/pesmarica` is that partition. So a freshly
flashed card already shows the pages on any laptop, and the writes the display
makes never touch the system filesystem. FAT carries no permissions, so they
come from the mount instead (`umask=0077`), and it carries no journal, so a
power cut mid-write can cost more than one file.

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

- **The flake is inside a git repository, so it only sees tracked files.**
  `bundle/` and `content/` are staged by `make bundle` and gitignored, which
  makes them invisible to a git flake; the error that follows names systemd
  units rather than the missing directory. Locally this never bites because the
  Makefile mounts this directory into the container without `.git`. CI builds
  with `path:` for the same reason.

- **gcc segfaults inside the Nix build sandbox here**, and disabling the
  sandbox only moves the failure: cc1 has died on a trivial `int main(){}` in
  three different derivations (the kernel config step, flutter-pi, perl-env)
  while the same compiler builds it fine outside a build. The colima VM is
  allocated 12 GiB on a 16 GiB Mac, which is the first thing to suspect --
  try `colima start --memory 8` before hunting further. Reruns resume from the
  store, so a flaky build makes progress each time.

- **CI pushes to a Cachix cache of its own** (repository variable
  `CACHIX_CACHE`, secret `CACHIX_AUTH_TOKEN`). That is for our own pieces --
  flutter-pi and the image -- not the kernel, which comes prebuilt from
  upstream's cache.

- **This tracks a moving upstream.** nixos-raspberrypi follows nixpkgs unstable
  (26.05 as of writing) and pushes often, which is what makes its cache worth
  having -- and also means `nix flake update` can move the kernel under you.
  The lock file is the pin.
- **512 MB of RAM is the open question.** A NixOS userland plus the Flutter
  engine on a Zero 2 W has not been verified on hardware.
- The bundle `flutterpi_tool` produces lands in `build/flutter-pi/<cpu>/` and
  contains a prebuilt `flutter-pi` binary. We drop it and use the one from
  `pkgs/flutter-pi.nix`, linked against this system's libraries.
