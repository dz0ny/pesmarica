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

To write a published release instead of a local build, stream it -- nothing
needs to land on the disk on the way:

```bash
sudo -v && diskutil unmountDisk /dev/rdisk4
```

```bash
curl -fL "$(gh release view --json assets -q '.assets[]|select(.name|endswith(".img.xz")).url')" | xz -dc | sudo dd of=/dev/rdisk4 bs=4m
```

```bash
sync && diskutil eject /dev/rdisk4
```

`.url`, not `browser_download_url` -- that is the REST API's field name and
`gh release view --json assets` does not carry it, so asking for it yields a
blank argument and an `xz` error that looks like a corrupt download. BSD `dd`
has no `status=progress`; curl keeps its own meter when stdout is a pipe, and
the card being slower than the connection is what makes it track the write.
[../README.md](../README.md#straight-from-a-release) has the longer version.

## The access point

The box never joins a network — there is rarely one to join in the rooms this
ends up in, and a box waiting for an uplink is a box showing a blank screen.
Instead:

| Piece | Job |
|---|---|
| hostapd | the radio, from `hostapd.conf` on the songbook partition |
| systemd-networkd | the address `192.168.4.1/24` and the DHCP pool |
| dnsmasq | every name resolves to the box, so phones open the captive-portal sheet on the songbook |

dnsmasq uses `bind-dynamic`, not `bind-interfaces`. The difference is what
happens before `wlan0` has `192.168.4.1` on it: `bind-interfaces` wants the
address at startup and exits without it, and the unit is only ordered after
`network.target` -- which means networkd has *started*, not that hostapd has
brought the link up and an address has landed. dnsmasq lost that race on every
boot, failed five times, and systemd's start limit then stopped it for good, so
the access point handed out no leases at all. The unit also has no start limit
now and retries every five seconds: a box whose DHCP server has given up is a
box nobody can reach, in a hall, mid-service.

The web interface rewrites `hostapd.conf` and restarts hostapd. Because that is
the only way into the box, `pesmarica-ap-preflight` validates the file first and
restores the shipped default if it cannot work — a bad SSID typed into a phone
must not lock you out.

Change the shipped default (SSID `Pesmarica`, passphrase `pesmarica`, country
`SI`) in `modules/pesmarica.nix` before this leaves your desk.

## Updating the system without reflashing

The app is in the closure, so updating the box is updating the system --
there is no separate bundle to push:

```bash
HOST=root@192.168.4.1 RELEASE=v7 ../tool/deploy_system.sh   # from a release
make system && HOST=... ../tool/deploy_system.sh            # built here
```

Expect minutes, not seconds: half a gigabyte over the box's own 2.4 GHz access
point onto an SD card.

The boot partition has two slots, `nixos-a` and `nixos-b`, and `config.txt`'s
`os_prefix` names the one the firmware boots. The deploy asks the box which
slot it runs, fills the other, and moves `os_prefix` — one line in a plain
file, written to a temp name and renamed. Nothing the running system has open
is touched. `scripts/system_switch.sh` is the on-box half -- piped over ssh by
the deploy, installed here as `pesmarica-system-switch` for the updater, and
covered without a Pi by `../tool/test_system_switch.sh`.

**The same system fits either slot.** It used to be built for one of them: its
fstab named its own `rootfs.img` by path and it carried the answer in
`/etc/pesmarica-slot`, so a release had to ship two payloads of half a gigabyte
that differed by a handful of bytes. Nothing in the closure names a slot now.
The system is built under upstream's plain `nixos/`, `modules/image.nix`
renames that to `nixos-a` for the card it writes, and a deploy or an update
unpacks the one payload into whichever slot the box is not running.

What replaces the baked-in answer is `scripts/find_slot.sh`, installed as
`pesmarica-find-slot`. The firmware loaded this kernel out of one slot, and the
cmdline it was given is that slot's `cmdline.txt` — which names this system's
own store path. Each slot says which system it holds in `system-link`, written
beside the kernel. The slot whose `system-link` is what we were started with is
the one we are running, and that is right on a trial boot too, where
`config.txt` still names the slot the box came from. It runs twice: in the
initrd, where `pesmarica-store.service` symlinks the right `rootfs.img` before
the store is loop-mounted, and on the box, where the updater, the trial-boot
decision and the deploy all ask it. `../tool/test_find_slot.sh` covers it,
including two slots holding the same system — then the payloads are identical,
either answer boots the same bytes, and `config.txt` breaks the tie.

`system-link` is therefore load-bearing: a slot without one mounts nothing, so
the switch, the updater and the deploy all refuse a payload that is missing it.
The other half of that machinery -- `pesmarica-store.service`, which turns the
answer into the symlink the store is loop-mounted from -- runs in the initrd,
where a missing binary is invisible until a card is in a box. See the first of
the sharp edges below before adding anything to it.

`scripts/update_check.sh` is the deploy without the laptop:
`pesmarica-update-check.service`, on an hourly timer, asks GitHub for the
latest release and fills the free slot from it. It runs only when `autoUpdate`
in `settings.json` is on, only when the box is a client on a network with a
default route, and it never switches or reboots -- the web interface offers
`Namesti`, which starts `pesmarica-update-install.service`, and that is the
only thing that moves `os_prefix`. `../tool/test_update_check.sh` covers it
against a fake GitHub.

The reboot goes through sysrq rather than a clean shutdown: the store is a loop
device on a file on the boot partition, and the kernel does not come back from
being asked to tear that down — twice, the box sat at "failed unmounting" until
the plug was pulled. Root is a tmpfs and the store is read-only; a sync first
is everything a clean shutdown would have done.

A new system boots on trial first. `system_switch.sh --try <slot>` writes
`tryboot.txt` -- `config.txt` with a different `os_prefix` -- and the firmware
loads that instead of `config.txt` for exactly one boot, clearing the flag
before it starts. So a crash, a hang or a power cut lands the next boot back on
the slot that was already working, with no bootloader of ours in the chain and
nothing written per boot.

`pesmarica-tryboot.service` is what makes it permanent: on the next boot it
compares the slot the box is actually running against the one `config.txt`
names, and when they disagree it waits for the app to answer on `/api/remote`
before writing `config.txt`. A system that comes up broken -- black screen, no
radio, an app that will not start -- is simply never promoted. The same unit
does the retry, up to three goes, with the count kept on the card by the
*known-good* system: a trial is one shot, so without retries a brownout
mid-boot would revert a perfectly good update. The flag rides on the reboot
syscall's argument, which sysrq cannot carry, hence `pesmarica-tryboot-reboot`.
`scripts/tryboot.sh` is the decision and `../tool/test_tryboot.sh` pins both
directions, including that the attempt count goes up *before* the restart --
the other order is a loop with no end.

`deploy_system.sh` finds the reboot helper by asking the box's own unit --
`systemctl show pesmarica-tryboot.service -p Environment` -- rather than
looking for it on `PATH`. It looked on `PATH` first, and the switch helpers
were referenced by store path from the units and nowhere else, so every box
answered "no", every deploy reported `predates trial boots`, and every switch
was permanent with the rollback it had just armed sitting unused. Reading the
unit works on a box that has not been updated yet, which is the only way to fix
boxes already in the field. The helpers are in `environment.systemPackages` now
as well: one that can only be reached by store path is one nobody can recover
by hand at a console.

The previous system stays whole in its slot throughout. If everything above
fails, the way back is still a card reader and one line of `config.txt`:

```
os_prefix=nixos-a/default/      # or b: whichever it was running before
```

## Writes to the card

The SD card is the part that dies, so in steady state nothing reaches it at all.
The display used to stamp a view counter and a timestamp into the front matter
after a page had been up for a few seconds, which meant a service wrote to the
card every few minutes to record something nobody read; it does not any more.
What is left is the songbook, written when a human edits a page,
`hostapd.conf` when someone changes the network, and -- if auto-update is
turned on -- a release written into the slot the box is not running from, which
is a large write and the reason that setting is off by default. It is also the
safest large write there is: the running slot is not touched, and a download
cut halfway leaves a slot the switch refuses.

The card is two FAT32 partitions and nothing else. `FIRMWARE` holds the Pi
firmware, `config.txt`, `tryboot.txt` while a system is on trial, and
`nixos-<slot>/default/` with the kernel, the initrd, `cmdline.txt`,
`system-link`, the device trees and `rootfs.img` -- the whole system as one
zstd squashfs. There is no U-Boot: the firmware loads the kernel and initrd
itself, and the initrd mounts the partition, loop-mounts `rootfs.img` as
`/nix/store`, and gives the system a tmpfs for root. It is the shape of the
NixOS netboot image with the squashfs on the card instead of inside the
initrd, because the closure does not fit in a Zero 2 W's RAM. Updating the
system is filling the other slot and moving `os_prefix` -- with a card reader,
or over ssh with `deploy_system.sh` above.

`PESMARICA` is the songbook -- FAT32, 512 MiB in the image, with the pages and
`hostapd.conf` already written into it by `mtools` at build time -- and
`pesmarica-data` grows it into the rest of the card on the first boot with
`fatresize`. There is no "done" marker: the unit reads the card, and grows the
partition if it stops short of the disk and the filesystem if it stops short
of the partition, which is what a power cut in the middle of that first boot
leaves behind. `/var/lib/pesmarica` is that partition. It is also the one
place anything persists: the ssh host key lives in `.ssh/` there. FAT carries
no permissions, so they come from the mount instead (`umask=0077`), and it
carries no journal, so a power cut mid-write can cost more than one file.

Everything else is in RAM: root itself, so the journal, `/tmp`, `/var` and
systemd's state start fresh each boot, and the system never writes to the card
at all. The store is read-only squashfs, and `nix` is not on the box.

Activation used to be the largest remaining writer: NixOS rewrites the whole of
`/etc` on every boot. It no longer does. `system.etc.overlay` mounts `/etc`
from an erofs image in the store through a systemd stage-1 mount unit, with no
writable layer at all, which is the same copy-on-write shape composefs gives
you. `systemd.sysusers` then creates the accounts from that closure rather than
editing `/etc/passwd` in place. A read-only `/etc` has one catch: systemd needs
an `/etc/machine-id`, and with nowhere to create one it carries on without --
silently breaking D-Bus and networkd -- so the image ships an empty one for it
to fill at boot.

## When it goes wrong

The journal is in RAM, so a box that goes dark leaves nothing to read
afterwards. The boot is deliberately not quiet -- the screen is the only
instrument the box has, and a photograph of it has twice been the fastest way
to a cause. For more than that, add `pesmarica.log` to `cmdline.txt` on the
boot partition with a card reader: `pesmarica-boot-log.service` then writes
this boot's journal to `boot.log` on the songbook partition, keeping the
previous one as `boot.log.1`.

Two limits worth knowing before you rely on it. It is a transcript, not a
journal directory -- the partition is FAT and carries neither the permissions
nor the ACLs journald wants. And FAT has no journal of its own, so pulling the
power drops whatever the kernel had not flushed: one boot logged six seconds of
a run that lasted minutes, and the answer we wanted was past the cut. Shut the
box down with `sync` before the plug comes out, or read the screen.

A card is also evidence in its own right, and reading one is often faster than
another boot. `config.txt` says which slot the firmware will load;
`nixos-<slot>/default/` should hold `kernel.img`, `initrd`, `cmdline.txt`,
`system-link` and `rootfs.img`; `system-link` must match the `init=` in
`cmdline.txt`, and `scripts/find_slot.sh` can be run against the mounted
partition to check. Unpacking `initrd` and looking for what its own scripts
call is what found the v13 failure -- see the first sharp edge below.

## Known sharp edges

- **The initrd carries store paths, not closures.** A service under
  `boot.initrd.systemd.services` gets its script copied in, and nothing reads
  that script: a binary the script calls is only in the initrd if it is *also*
  named in `boot.initrd.systemd.storePaths`. Nothing fails at build time, so
  the first sign is a box on a shelf -- the service exits 127, the mount that
  `Requires=` it fails, `initrd-fs.target` fails, and the screen shows a few
  unit lines and then nothing. v13 shipped exactly that: of the initrd's 106
  store entries the only missing one was `pesmarica-find-slot`, which
  `pesmarica-store.service` calls. Upstream names every binary its own initrd
  scripts use for this reason. `../tool/check_initrd_deps.sh` unpacks a built
  initrd, reads every `unit-script-*` in it and checks each store path it names
  is present; CI runs it right after the build. It is the one check in this
  repo that cannot run against a stub, because it needs an initrd and that
  needs an aarch64 builder.

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
