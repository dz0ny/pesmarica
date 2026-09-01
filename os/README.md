# Pesmarica appliance image

Builds a bootable `sdcard.img` for a **Raspberry Pi Zero 2 W** containing a
minimal Linux (buildroot), flutter-pi, and this app. Copy the image to an SD
card, power on, the songbook is on screen. No Raspberry Pi OS, no `apt`, no
first-boot setup, nothing to deploy over SSH.

## Why this shape

- **buildroot**, not Yocto or a stripped Raspberry Pi OS. A full image is
  ~200 MB, boots in a few seconds, and one `make` produces it.
- **The Flutter engine is not built from source.** Buildroot ships a
  `flutter-pi` package that selects `flutter-engine`, which compiles the engine
  with depot_tools: hours of CPU and tens of GB. flutter-pi `dlopen()`s
  `libflutter_engine.so` at runtime, so we instead take the prebuilt engine that
  `flutterpi_tool` already puts in the app bundle, and build only the ~1-minute
  embedder. That is what `external/package/flutterpi` is for.
- **Two build hosts.** The Dart AOT snapshotter only exists as an x86_64 binary,
  and buildroot cannot run on macOS at all. So the bundle is built on macOS
  (Rosetta) and the image inside a Linux container.
- **Flutter is pinned to 3.44.x** in `../mise.toml`. `flutterpi_tool` compiles
  against `flutter_tools` internals, so a newer SDK does not just warn -- it
  fails to compile the tool. `flutter upgrade` in this project breaks the image
  build; `scripts/build-bundle.sh` refuses to run on anything outside 3.44.x.

## One-time setup

```bash
brew install colima docker
colima start --cpu 6 --memory 12 --disk 100
softwareupdate --install-rosetta   # only if not already installed
mise install                       # Flutter 3.44.4, pinned in ../mise.toml
```

Then set the wifi credentials in
`external/board/pesmarica/rootfs-overlay/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`.

## Build

```bash
cd os
make image
```

First run takes 30-60 minutes (toolchain, kernel, mesa, systemd). Later runs are
minutes; changing only the Flutter app is `make bundle && make image`. The
result is `os/out/sdcard.img`.

## Flash

```bash
diskutil list                    # find the card
make flash DISK=/dev/rdisk4      # note the r: raw device, much faster
```

## What ends up on the card

| Partition | Contents |
|---|---|
| 1, FAT, 48M | Pi firmware, `Image`, dtb + overlays, `config.txt`, `cmdline.txt` |
| 2, ext4, 480M | rootfs: systemd, mesa/vc4, flutter-pi, the app bundle in `/opt/pesmarica/bundle` |
| 3, ext4, 256M | `/var/lib/pesmarica` — songbook pages written by the web UI, survives a reflash of partitions 1-2 |

## Boot path

firmware → `Image` → systemd → `pesmarica.service` on tty1. There is no getty on
tty1, no X, no Wayland, no display manager: flutter-pi drives KMS/DRM directly.
`vc4-kms-v3d` with 128 MB CMA gives the GPU enough for a 1080p Flutter surface
set out of the Zero 2 W's 512 MB.

To watch a boot, attach a 3.3 V serial adapter to the GPIO header (115200 8N1) —
the kernel console is on `ttyAMA0` and off `tty1` so it never draws over the app.

## Common changes

| Want | Where |
|---|---|
| Different Pi | `external/configs/` — copy the defconfig, change `BR2_cortex_*`, the DTS name, the firmware variant, and `CPU=` in `scripts/build-bundle.sh` |
| Add a package | `make menuconfig`, then `make savedefconfig` inside `make shell` |
| Bump flutter-pi | `FLUTTERPI_VERSION` in `external/package/flutterpi/flutterpi.mk` |
| Bump Flutter | `../mise.toml` and the version guard in `scripts/build-bundle.sh` — only to a version `flutterpi_tool` supports, and bump flutter-pi with it |
| Shave more boot time | drop `dtoverlay=miniuart-bt` and the serial console, mask `systemd-timesyncd`, build the kernel with a trimmed defconfig |

## Known sharp edges

- `flutterpi_tool` 0.12.0 builds only against Flutter 3.44.x. It fails to
  compile against 3.47, which is where `flutter upgrade` had left this SDK; the
  pin in `../mise.toml` puts it back and `build-bundle.sh` guards it. The pinned
  checkout is on a detached tag, so `flutter upgrade` will refuse rather than
  silently drift again.
- The bundle `flutterpi_tool` produces lands in `build/flutter-pi/<cpu>/`, not
  `build/flutter_assets`, and already contains `libflutter_engine.so`,
  `icudtl.dat`, `app.so` *and* a prebuilt `flutter-pi` binary. We drop that
  binary and build the embedder in buildroot instead, so it links against our
  own glibc, libdrm, libinput and systemd rather than whatever distro it was
  built on.
- Buildroot output must stay inside the Docker volume. Bind-mounting it onto
  APFS breaks the build on filename case collisions.
