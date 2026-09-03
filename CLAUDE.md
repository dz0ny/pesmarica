# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

Digital signage for a songbook (`pesmarica` = songbook in Slovenian). Flutter
app, deployed on a Raspberry Pi under
[flutter-pi](https://github.com/ardera/flutter-pi). One markdown file per page;
an operator drives the screen with a keypad, a presenter remote, or a phone.

Read `README.md` first — it documents the user-facing behaviour (front matter
keys, key bindings, the web interface, the Pi deploy). This file covers what you
need to *change* the code.

## Commands

```bash
flutter analyze
flutter test
PESMARICA_CONTENT=$PWD/content flutter run -d macos   # or -d linux
```

`flutter test` on a cold cache takes minutes. Run it in the background and poll
the log rather than waiting on a foreground call that will time out.

To exercise the real app end to end, build once and run the binary directly —
it is easier to drive and to kill than `flutter run`:

```bash
flutter build macos --debug
PESMARICA_CONTENT=$PWD/content \
  ./build/macos/Build/Products/Debug/pesmarica.app/Contents/MacOS/pesmarica &
curl -s localhost:80/api/state | python3 -m json.tool
```

Kill it with `pkill -f "Products/Debug/pesmarica"` when done. Paging around no
longer dirties `content/*.md`, so there is nothing to reset unless you edited a
page through the web interface.

## Layout

```
lib/
  main.dart                  content root resolution, app shell
  src/model/song_page.dart   one page; front matter <-> fields
  src/model/settings.dart    settings.json, palette + font ids
  src/data/front_matter.dart YAML header parse/compose
  src/data/songbook.dart     the folder: load, watch, write, import
  src/data/presenter.dart    what is on screen; keypad buffer; toggles
  src/input/key_bindings.dart key event -> presenter action
  src/ui/                    presenter screen, page rendering, overlays
  src/web/admin_server.dart  shelf routes, cookie auth, the open/gated split
  src/web/static_assets.dart serves the web files out of the Flutter bundle
  src/web/credentials.dart   salt, hash, constant-time compare
assets/web/                  the two pages: remote (/) and manage (/manage)
nix/                         the appliance image (flake, module, Makefile)
```

`Songbook` and `Presenter` are plain `ChangeNotifier`s wired up by hand in
`main.dart`. There is no state-management package and no DI container; don't add
one for its own sake.

## Things that will bite you

**The editor never shows front matter.** `GET /api/pages/<n>` hands the web
interface `body` (no header) and `front` (the fields, plus `extra` for keys we
do not interpret); a JSON `PUT` composes it again through `SongPage.copyWith`
and `toSource`, which is the same code the display parses with. A raw-markdown
`PUT` still works for scripts -- the content type is what picks the path. Never
compose that header in JavaScript: `title` and `showTitle` are both nullable
*with meaning*, which is why `copyWith` has `clearTitle`/`clearShowTitle`
rather than treating null as "unchanged".

**The page number is the file name, and the file name is the order.** There is
no index to reorder, so `Songbook.renumberPage` renames the file -- and rebuilds
the slug from the current title while it is there. It refuses an occupied
number rather than overwriting; `renumber_test.dart` pins that.

**The content folder is the only database.** Zoom and titles live
in each page's front matter; global settings live in `settings.json` beside the
pages. There is no other store. A songbook can be rsynced to another screen and
look identical — keep it that way.

**Writes go through `Songbook._write`.** It writes a `.tmp` file and renames it
into place, because the box loses mains power and `writeAsString` truncates
before it writes. Never call `File.writeAsString` on content directly.

**The file watcher would otherwise loop.** `_write` stamps the path in
`_selfWrites`; `_onFileEvent` ignores events for paths written in the last two
seconds. Any new write path must go through `_write` or it will trigger a
reload storm.

**Real file I/O deadlocks inside `testWidgets`.** `flutter_test` runs the body
in a fake async zone, so `await songbook.saveSettings(...)` never completes and
the test hangs with no output. Wrap it: `await tester.runAsync(() => ...)`. The
same applies to anything touching the engine, such as `boundary.toImage()`.

**Showing a page writes nothing.** The box writes to an SD card that a parish
hall will brown out every winter, so nothing on the display path may write — a
write belongs to a human editing a page.

**The bundled sans and serif families are variable fonts.** `FontWeight` alone
picks a named instance that a single-file variable font does not have, so bold
silently does nothing. Always go through `fontStyle()` in `page_style.dart`,
which sets `fontVariations` alongside `fontWeight`.

**The preview renderer must follow the display.** `assets/web/markdown.js`
renders markdown itself — a library would need a build step and a network the box does
not have. It mirrors what `MarkdownBody` does, including `softLineBreak: true`
in `page_view.dart`: change how the screen lays a page out and the preview has
to change with it, or it quietly starts lying.

**`Settings.toJson` only emits fields it knows.** A key that is not a real field
survives exactly until the next settings write, then it is gone. Anything new
that belongs in `settings.json` needs a field, a `copyWith` arm and a line in
both `toJson` and `fromJson` — `rotation` has a test pinning precisely this.

**The card is two FAT32 partitions, and the system is a file on the first.**
`nix/modules/image.nix` builds it: `FIRMWARE` holds the Pi firmware,
`config.txt` and `nixos-<slot>/default/` with the kernel, initrd, `cmdline.txt`,
the device trees and `rootfs.img` — a zstd squashfs of the whole closure that
the initrd loop-mounts as `/nix/store`, with root a tmpfs. No U-Boot, no ext4,
no generations.

**A system's slot is baked into it at build time** (`pesmarica.slot`): its
fstab names its own `rootfs.img` by that path, and `os_prefix` in `config.txt`
names the slot the firmware boots. A system staged under any other name boots
its own kernel against the previous squashfs — quietly, and it will even come
up. `tool/deploy_system.sh` asks the box which slot it runs
(`/etc/pesmarica-slot`), fills the other, and moves `os_prefix`; nothing the
running system has open is touched. Never rename a slot directory: the store is
a loop device on a file inside it, and the kernel does not come back from
tearing that down — which is also why the deploy reboots through sysrq rather
than a clean shutdown. There is no automatic rollback, since the firmware picks
the kernel before anything of ours runs; the previous system stays whole in its
slot, and the way back is one line of `config.txt` with a card reader.

**`PESMARICA` is the only place anything persists** — the songbook, and the ssh
host and authorized keys in `.ssh/`. The card can be pulled and the pages
edited on any laptop; that is the point, and FAT32 is what makes it possible to
ship both partitions populated: `mtools` writes them offline and `fatresize`
grows the songbook on first boot, with no marker, from what the card itself
says. exFAT can do neither. FAT carries no permissions (they come from the
mount, `umask=0077`) so nothing may `chmod` there, and no journal, so a power
cut mid-write can cost more than the file being written. The image build runs
unprivileged — no loop devices, no mounting — so a file reaches a partition
through `mcopy` and nothing else.

**The squashfs device is named by its initrd path.** `fileSystems."/nix/.ro-store"`
points at `/sysroot/boot/firmware/...` because that is where the boot
partition sits while the initrd runs, and systemd orders the loop mount after
it from the path alone. The same line is in the final `/etc/fstab`, already
mounted; do not "fix" it to `/boot/firmware/...` or the initrd stops finding
it.

**The web UI lives in `assets/web/`, not in Dart.** It is served through
`rootBundle`, so any change there needs a restart to show up, and a new file
must be added to both `StaticAssets.allowed` (a name -> bundle path map, so it
can serve the typeface out of `assets/fonts/` too) and the `assets:` list in
`pubspec.yaml` or it will 404. `static_assets_test.dart` checks that every
`/static/...` URL in the pages *and in the modules* has an entry.

**The password guards editing, not the room.** `/` is the remote and is open to
anyone on the access point; `/manage` and everything that writes is not. The
rule lives in one place, `AdminServer._isOpen`, and `remote_access_test.dart`
pins it. The three navigation calls are open because they write nothing to the
card -- anything new that does write belongs on the gated side.

**The remote polls, so the poll has to stay small.** `/api/remote` answers with
the current page and `Songbook.revision`, and nothing else; the page list is a
separate `/api/songbook` that clients fetch again only when that number moves.
`Songbook.notifyListeners` is overridden to bump it, so any change anywhere is
covered. Do not put the page list back into the polled response: a hymnal is
forty kilobytes, and every phone in the room holds that poll open.

**The pages are Preact + htm, vendored, with no build step.** `preact.js` is the
`htm/preact/standalone` bundle copied in whole -- replace the file to upgrade,
never edit it. The modules are plain ES modules loaded by URL, so they must
import each other as `/static/x.js`, not by relative path.

**Every colour is a token in `:root`.** There are two skins, dark and light,
selected by `data-skin` on `<html>` -- set by an inline script in each page
before the stylesheet paints. A literal hex anywhere else is a bug: it will look
right in one skin and wrong in the other.

**The boot partition is the preconfiguration surface, and it is parsed twice.**
`wifi.conf` and `display.conf` on the FAT partition are the only settings that
exist before the box has ever been switched on. They are read by
`pesmarica-boot-config.service` in shell at boot, and by `BootConfig` in Dart so
the web interface can change them -- the same format from two ends, so a change
to one needs the other. `tool/test_boot_config.sh` covers the shell side and
`test/boot_config_test.dart` the Dart side; the cases are deliberately the same
ones. What makes it safe to point the box at a network from a phone is
`pesmarica-wifi-fallback.service`: no address in 45 seconds and the access point
comes back. Anything new that can take the radio away has to keep that way back.

**Rotation is a flutter-pi startup flag, and it lives on the boot partition.**
The app cannot turn its own picture: the launcher reads `display.conf` and
passes `--rotation`, so the web interface writes the setting and restarts the
unit. `settings.json` only mirrors it so the interface has something to show,
and `main.dart` adopts the card's value when the two disagree — write both or
neither (`_putSettings` does), or the box turns back on the next boot.
`config.txt`'s own `display_rotate` is not a third place to look: the KMS
driver ignores it. Validate at both ends; a panel showing a corner of the
songbook looks like a dead box, and the way back is ssh.

**Read-only `/etc` breaks anything that expects to write there.**
`system.etc.overlay.mutable = false` is why `services.openssh.hostKeys` points
at the songbook partition and why `register-nix-paths` is disabled outright (along with
`nix` itself, which the box never runs) -- both upstream units write into
`/etc` and fail, and the sshd one costs you ssh, which is the recovery path. A
new unit that wants to write to `/etc` will fail the same way, silently, until
someone reads the boot log. The same read-only `/etc` is why the image ships an
empty `/etc/machine-id`: without one systemd logs "System cannot boot" and then
boots anyway, with no id -- dbus-broker dies, everything after it waits 90
seconds, and networkd cannot build DHCP identifiers, so wlan0 never gets its
address and the access point hands out no leases.

**`/boot/firmware` must stay mounted.** Upstream makes it an automount that
lets go after a minute idle. Units that hold it through `RequiresMountsFor`
-- the app among them -- get *stopped* when it goes, and a stop is not a
failure, so `Restart=always` never fires: the box boots to a console one
minute in. The module pins it as a plain mount; keep it that way.

**Nothing else may sit on tty1.** logind starts `autovt@tty1` for the active
console, separately from the `getty@tty1` the image already disables. The app
unit hangs up the tty on start, the getty hangs it back, and the app restarts
every two seconds with nothing in the journal. Both instances are disabled;
keep them so.

**GPU drivers only exist under `/run/opengl-driver`.** flutter-pi links
`libgbm` and `libEGL`, which since mesa 25 are front ends that find `dri_gbm.so`
and the EGL vendor file through that path alone. `hardware.graphics.enable` is
what creates it; without it flutter-pi reports "Could not create GBM device" on
a working `/dev/dri/card0`. The mesa behind it is overridden down to
`v3d` and `vc4` with no Vulkan drivers, because stock mesa's `llvmpipe` pulls
in 591 MB of LLVM -- a third of the closure -- for a software rasteriser this
box can never use. That override is why mesa builds from source in CI instead
of coming from the cache, and adding a driver back means paying that build
again. Dropping drivers costs two workarounds: `gallium-va` has to
be disabled by hand, because nixpkgs' meson hook sets `auto_features=enabled`
and the VA-API tracker then demands a driver that is gone; and mesa's
`spirv2dxil` output has to be created empty, because it declares that output
unconditionally while only the WSL driver fills it.

**`environment.defaultPackages` is empty, so a deploy may only use what the
closure already carries.** The deploy used to push with rsync, which emptying
that list had quietly removed — and a box with no rsync could not receive the
update that would have installed it. It pushes with `tar`, which systemd pulls
in regardless. Anything new that shells out on the box has the same
constraint: check a running one before believing it is there.

**Root's home is RAM, so an ssh key put there lasts one boot.** Authorized
keys live at `/var/lib/pesmarica/.ssh/authorized_keys`, beside the host key and
for the same reason -- and it matters more than it looks, because
`deploy_system.sh` reboots the box itself, so a key in `/root/.ssh` would not
survive the deploy that installed it. To authorize a new machine: append to
that file over ssh within a boot, or put it there with a card reader.

**Getting into a box that is on no network.** Take `wifi.conf` off the boot
partition so it comes up as the access point, join `Pesmarica`, then ssh to its
IPv6 link-local address (`ping6 ff02::1%<wifi if>` finds it) as `root` with the
image's initial password; a fresh image has no keys. Each login takes a minute
and a half while sshd waits on a reverse lookup the box cannot do.

**The access point is the only way into the box, and the app no longer touches
it.** `hostapd.conf` lives on the data partition beside the songbook, which is
FAT32 precisely so it can be edited with the card in a laptop -- and it now
ships in the image, so the network the box hands out can be renamed before it
is ever powered on. A config hostapd
rejects is a brick, recoverable only by the `ap-preflight` fallback in the image
or a serial console, so nothing in the app may write that file — the web
interface used to and does not any more. Do not add a copy of the SSID to
`settings.json` either. `wifi.conf` on the boot partition is a different file
with the opposite rule: it says which network to *join*, the app does write it,
and hostapd never reads it -- a name typed into a phone can leave the box
looking for a network that is not there, which the fallback undoes, but it can
never leave hostapd unable to start.

**Never write a password anywhere.** `Songbook._adoptPassword` hashes a
plaintext `password:` out of `settings.json` on load and rewrites the file
without it. Anything new that touches settings must not reintroduce the
plaintext — `Settings.toJson` deliberately never emits it.

**`AutoFit` converges over frames, not in one pass.** Markdown reflows as the
font size changes, so it measures, shrinks and re-measures, holding the child at
opacity 0 until settled. It restarts when `signature` changes — if you add
something that affects layout, add it to that signature or pages will render at
a stale size.

## Conventions

- Slovenian for everything the operator or audience sees; English for code,
  comments and commits. Watch for Cyrillic look-alikes slipping into Slovenian
  strings (`Naložено` vs `Naloženo`) — the codebase should contain no
  characters outside ASCII plus `čćšžđ` and deliberate typography.
- The display uses exactly two colours plus one muted tone, from
  `PagePalette`. Do not introduce accent colours or Material theming into the
  presentation path.
- Nothing is fetched at runtime. Fonts are bundled assets and the admin UI is
  one dependency-free HTML string, because the box is often offline and a build
  step for the admin UI is one more thing to be broken on a Sunday morning.
- Comments explain why, not what. Match the density already in the files.

## The appliance

`nix/` is a NixOS flake and the single definition of the system: the units, the
access point, the partitions, the paths. If you find yourself wanting to install
a unit from the repo, change the image instead. When the image itself is what
changed, `tool/deploy_system.sh` pushes a slot (`RELEASE=vN`, or `make system
SLOT=b`) onto a running box rather than reflashing a card. It writes the free
slot and one line of `config.txt`, nothing else, so a change to the Pi firmware
still needs a reflash; the script says so when it sees one.

It builds on [nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi),
chosen over raspberry-pi-nix because its cache actually holds the kernel: check
a store path against `nixos-raspberrypi.cachix.org` before believing any such
claim, since raspberry-pi-nix advertises one whose paths all 404.

**The flake sits inside a git repository, so it only sees tracked files.**
`nix/bundle` and `nix/content` are staged by `make bundle` and gitignored, which
makes them invisible: `nix build .#` fails with a message about systemd units
rather than the missing directory. Build with `path:` — the Makefile gets away
with `.` only because it mounts `nix/` into the container without `.git`.

The image cannot be built or booted from a test run here; it needs an aarch64
Linux builder and a real Zero 2 W. Treat changes under `nix/` as unverified
until someone flashes a card, and say so. CI builds it on Linux runners, which
is the fastest way to find out whether a change even compiles. The one exception
is `pesmarica-boot-config`, which `tool/test_boot_config.sh` lifts out of the
module and runs against fake boot partitions.

**The app has no update path of its own.** It is in the closure, so replacing
the system replaces it, and `tool/deploy_system.sh` is the only updater. A
second one existed and was removed: a faster Dart loop is not worth two
updaters that can disagree about which version is running.

## Testing

`test/front_matter_test.dart` and `test/presenter_test.dart` are plain `test()`
over a temp songbook — fast, and where most logic belongs.
`test/render_test.dart` and `test/title_test.dart` are widget tests over a real
`PresenterScreen`. `tool/test_system_switch.sh` covers system updates: it runs
`tool/system_switch.sh` against fake boot partitions, and every refusal it pins
is a card reader trip that did not happen.
`test/network_api_test.dart` pins what the web interface may write to the boot
partition -- above all that a passphrase wpa_supplicant would refuse is refused
while there is still somebody connected to be told about it.
`test/remote_access_test.dart` starts a real server on a temp songbook and
pins which routes need the password -- note that it has to null out
`HttpOverrides.global`, because the test binding stubs `HttpClient` into
returning 400 for everything.

Prefer asserting on values the app actually computes (e.g. the
`MarkdownStyleSheet` font size) over walking the render tree; finder-based
assertions on markdown output are brittle, and a page title legitimately appears
twice on screen (heading and chrome bar).
