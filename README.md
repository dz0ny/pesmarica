<h1 align="center">Pesmarica</h1>

<p align="center">
  Put the words on the wall, and let anyone in the room drive them.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Raspberry%20Pi%20Zero%202%20W-C51A4A?logo=raspberrypi" />
  <img alt="Built with" src="https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter" />
  <img alt="Appliance" src="https://img.shields.io/badge/appliance-NixOS-5277C3?logo=nixos" />
  <img alt="Offline" src="https://img.shields.io/badge/network-offline%20by%20design-2F9E86" />
</p>

Pesmarica is digital signage for a songbook. Every page is one markdown file in
one folder; the operator drives the screen with a keypad, a presenter remote, or
a phone on the same network. It runs on a Raspberry Pi under
[flutter-pi](https://github.com/ardera/flutter-pi), boots straight into the
songbook, and brings its own wifi with it.

**The songbook is the database.** Titles, magnification, and how often a page
has been shown are written back into the page itself, so a songbook is a folder
you can copy to another screen, edit over SSH, or keep in Git — and it will look
and behave the same.

## Why Pesmarica exists

Rooms that need words on a wall — a parish hall, a school gym, a community
centre — rarely have reliable wifi, an IT person, or anyone who wants to learn
presentation software before a service starts. Pesmarica assumes the worst
version of that room: no uplink, no internet, mains power that goes away without
warning, and whoever happens to be free to run the screen that morning.

So the box is the network rather than a guest on one, the content is plain
markdown rather than a database, and the controls are the ones people already
know from PowerPoint — type a number, press Enter.

## Highlights

- One markdown file per page, in one folder, with no other source of truth
- The songbook partition mounts on Windows and macOS, so a card *is* the editor
- Type a page number and press Enter, exactly like a slide deck
- Works with a keypad, a presenter remote, a touch screen, or a phone
- Its own wifi access point, configurable from the web interface
- A management page with a formatting toolbar and a preview of the real layout
- Automatic type fitting, so one songbook reads correctly on 1080p and 4K
- Four bundled fonts covering č/š/ž/ć/đ, nothing fetched at runtime
- Optional password, hashed on first load and never stored in the clear
- Survives losing mains power mid-write
- An appliance image that defines the whole system in one place

## Feature Overview

| Area | What you get |
|---|---|
| Content | One markdown file per page; front matter the app reads and writes back |
| Display | Automatic type fitting, per-page magnification, two-colour rendering |
| Orientation | 90/180/270° rotation for panels mounted sideways |
| Controls | Keypad, presenter remote, arrow keys, touch halves, or the web page |
| Web interface | Formatting toolbar, live preview, create and delete pages, drive the screen |
| Import | Drop `.md` files onto the page list, or images into the editor |
| Network | Always an access point; every name resolves to the box |
| Songbook storage | Its own exFAT partition — pull the card and edit on any laptop |
| Recovery | A rejected access point config is replaced with the shipped default |
| Security | One password, salted and hashed; cookie or `X-Pesmarica-Auth` header |
| Appliance | NixOS image with the unit files, network, and paths defined once |
| Updates | Two app slots, an atomic flip, and an automatic revert if the new one will not start |
| Durability | Atomic writes; nothing is written to the card unless somebody edits a page |

## How It Works

1. Flash the image and power the box on.
2. It comes up as a wifi access point and shows the first page.
3. Join that network from a phone or a laptop.
4. Edit pages in the web interface, or over SSH, or by rsyncing a folder.
5. The display picks up every change through a file watcher.

There is no server to reach, no account to make, and nothing is fetched at
runtime. Unplugging the box is a supported way to turn it off.

## Built For

- Anyone who needs words on a screen in a room without usable wifi
- Operators who want PowerPoint's muscle memory and nothing else to learn
- People who would rather edit a folder of markdown than use a content editor
- Whoever inherits the box in three years and needs to understand it quickly

## Requirements

- A Raspberry Pi Zero 2 W and an SD card, for the appliance
- Any HDMI screen
- A keypad, presenter remote, or phone to drive it
- For development: Flutter, and macOS or Linux
- For building the image yourself: Docker via
  [colima](https://github.com/abiosoft/colima), and Flutter pinned to 3.44.x in
  `mise.toml` — `flutterpi_tool` compiles against `flutter_tools` internals and
  does not build against anything newer. CI builds the same image on Linux
  runners if you would rather not.

## Install

The `image` workflow builds the card image and attaches it to the run as an
`.img.xz` artifact, so the usual way to get one is to download it from
[Actions](https://github.com/dz0ny/pesmarica/actions) and write it to a card:

```bash
diskutil unmountDisk /dev/rdisk4
```

```bash
xz -dc pesmarica-*.img.xz | sudo dd of=/dev/rdisk4 bs=4m status=progress
```

Note the `r` in `rdisk4`: the raw device is several times faster. `make flash`
does the same three steps -- unmount, write, eject -- for an image you built
locally.

To build it yourself instead:

```bash
cd nix && make image
```

```bash
make flash DISK=/dev/rdisk4
```

The Pi kernel and firmware come prebuilt from
[nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi)'s cache, so a
local build compiles only flutter-pi. See [nix/README.md](nix/README.md) for
the prerequisites and what the image contains. Between reflashes, push a new build onto a running box:

```bash
HOST=root@pesmarica.local ./tool/deploy_pi.sh
```

That syncs the songbook to `/var/lib/pesmarica` (without `--delete`, so pages
created through the web interface survive) and the app into whichever update
slot is not running, then restarts onto it. It installs nothing: changing the
system means rebuilding the image.

### Updates are A/B

The box keeps two copies of the app, `bundles/a` and `bundles/b` beside the
songbook, and a one-byte pointer at the one it runs -- the scheme a browser uses
to update itself. A deploy fills the copy that is *not* running and flips the
pointer last, so an update interrupted by a power cut leaves the box on the
version it was already running.

A freshly installed version is then **on trial**: if it fails to draw a frame
three starts running, the box points itself back at the previous copy on its
own. If both copies are unusable it falls back to the bundle inside the image
itself, which lives in the read-only Nix store and is the one copy a bad update
cannot reach. The web interface shows the running version, and says so while it
is still on trial.

Updating without a laptop works too: **Posodobi** in the web interface takes a
`.tar` (or `.tar.gz`) of a built bundle and installs it the same way. That
button only works once a password is set -- everything else in the interface
edits pages, but this one replaces the program the box runs, and an appliance
whose interface is open to everyone on the access point should not hand that
out. Set a password in `settings.json` first (see below).

To run it on a desktop instead:

```bash
PESMARICA_CONTENT=$PWD/content flutter run -d macos   # or -d linux
```

`PESMARICA_CONTENT` picks the songbook folder; without it Pesmarica uses
`./content` next to the working directory.

## First Run

1. Power the box on; the first page appears by itself.
2. Connect a phone or laptop to the `Pesmarica` network (passphrase `pesmarica`).
3. Most devices open the songbook by themselves; otherwise go to
   `http://192.168.4.1` or `http://pesmarica.local`.
4. Put your own pages in, through the web interface or with the card in a laptop.

Out of the box the network is `Pesmarica` / `pesmarica` on channel 6 —
**change both before it leaves your desk**. That is done with the card in a
laptop, by editing `hostapd.conf` in the songbook partition; it is deliberately
not something the web interface can do, because a name or passphrase hostapd
refuses to start on would leave nobody a way back in.

If a bad configuration does get written anyway, the box still does not become a
brick: `ap-preflight` checks the file before hostapd starts and restores the
shipped default if the name or passphrase could not work.

## The songbook is a folder

On the appliance that folder is a separate exFAT partition labelled
`PESMARICA`, created on first boot from whatever space is left on the card.
Take the card out, put it in a laptop, and the songbook is right there — which
is how pages actually get written the evening before, rather than over ssh. The
access point's `hostapd.conf` sits beside them for the same reason.

The trade is that exFAT has no journal: losing mains power mid-write can damage
the directory rather than a single file. Pesmarica writes every page through a
temporary file and a rename to keep that window as small as it can, but a card
that has been yanked mid-save often enough is a card to replace.

```text
content/
  001-dobrodosli.md
  002-cebelica.md
  010-slika.md
  images/primer.png
  settings.json
```

The number in the file name is the number the operator types. Files without a
number still show up, filed after the last numbered page.

### Front matter

Everything the app remembers about a page is written back into that page, so a
songbook is self-contained — copy it to another screen and it looks the same.
Showing a page is not remembered at all: the display writes nothing as it pages
through a service, so the card is only ever written when somebody edits.

```markdown
---
title: Čebelica na travniku   # optional; otherwise the first heading, then the file name
scale: 1.1                    # magnification set with + / − on the display
align: center                 # start (default) or center
showTitle: false              # hide the title on this page
---

Čez travnik, čez polje
čebelica leti,
```

Keys Pesmarica does not know are preserved when it rewrites a file, so you can
keep your own metadata alongside.

`scale` is a multiplier on top of an automatic fit: type is sized from the panel
height and then shrunk further if the page would not fit, so the same songbook
reads correctly on a 1080p TV and on a 4K panel.

`showTitle` means the same thing wherever the title comes from — turning it off
also drops a leading `# Heading` that repeats the title. Leave it out and the
page follows `showTitle` in `settings.json`.

## Driving the display

| Key | |
| --- | --- |
| `↓` `→` `Space` `PgDn` | next page |
| `↑` `←` `PgUp` | previous page |
| `0`–`9` then `Enter` | jump to a page number, PowerPoint style |
| `Backspace` | delete the last digit, or go back a page |
| `Esc` | cancel the pending number |
| `Home` `End` | first / last page |
| `+` `−` | magnification, saved into the page |
| `R` | reset magnification |
| `B` | black-on-white ⇄ white-on-black |
| `F` | next font |
| `T` | show / hide titles |
| `C` | show / hide the bottom strip |
| `?` | key reference |

Digits and `+`/`−` are matched on the character produced, not the physical key,
so a Slovenian layout, a numeric keypad and a cheap presenter remote all behave
the same. Tapping the right or left half of a touch screen also pages.

## The box is the network

The appliance is always a wifi access point and never a client. It does not join
your wifi — there usually isn't any in the rooms this ends up in, and a screen
that waits for an uplink is a screen that stays blank when the uplink is not
there.

So: power it on, connect a phone or laptop to its network, and the songbook's
web interface is there. Every name resolves to the box, so most devices pop the
sign-in sheet open on it by themselves.

## Web interface

The app serves a management page on port 8080 (`http://192.168.4.1:8080`, or
`:8080` on whatever address you reach it at). It lists the pages, edits them as
raw markdown, creates and deletes them, drives the display remotely, and sets
the polarity, font and global magnification.

### Rotation

Signage panels are often mounted sideways, so **Zasuk** turns the picture 90,
180 or 270° clockwise. The rotation is not something the app can apply to
itself: it is a flutter-pi startup flag, so saving it restarts the display. The
screen goes black for a moment and comes back turned; the web interface is not
interrupted. Off the box -- a desktop run -- the setting is stored and ignored.

### Writing tools

A toolbar over the editor covers what a songbook page needs without knowing any
markdown: **B**/*I* (also ⌘B / ⌘I), headings, a blockquote for the refrain, a
bullet list, a verse break, and a file picker for images. Each button toggles,
so pressing it again takes the markup off.

**Predogled** (⌘P) renders the page as the screen will lay it out. It is a
small renderer written into `app.js` rather than a markdown library, because
the box is offline and this page has to work when nothing can be fetched --
it covers headings, emphasis, blockquotes, lists, code and images, and nothing
more.

Drag and drop:

- **`.md` files onto the page list** — imported as new pages. A number in the
  file name is kept when it is free, otherwise the page is filed at the end.
- **images onto the editor** — uploaded into `images/` and inserted at the
  cursor as `![](images/…)`.

Edits land in the content folder as plain markdown and the display picks them up
through a file watcher, so there is no second source of truth. The same works
the other way: edit a file over SSH and the screen follows.

### Password

There is no login until you set one. Put a password in `settings.json`:

```json
{ "password": "cebelica" }
```

On the next start Pesmarica salts and hashes it, rewrites the file without the
plaintext, and starts asking for it. There is no user name — one password for
the screen, entered once per device and remembered for ten years in an
`HttpOnly` cookie, so a reboot or a month unplugged does not log anyone out.
Changing the password invalidates every device at once; `Odjava` in the header
signs out just the one in front of you.

Scripts can send the same secret as an `X-Pesmarica-Auth` header instead of a
cookie; the value is the `passwordHash` from `settings.json`.

This is a password over plain HTTP on a local network. It keeps the parish
laptop and a curious phone out of the songbook; it is not protection against
somebody on the wire, and neither this nor `httpEnabled: false` makes the box
safe to expose to the internet.

### settings.json

```json
{
  "theme": "dark",        // dark = white on black, light = black on white
  "font": "inter",        // inter | noto-sans | noto-serif | atkinson
  "baseScale": 1.0,       // global multiplier on top of each page's scale
  "showChrome": true,     // the number/title strip along the bottom
  "showTitle": true,      // default for pages that do not set showTitle
  "rotation": 0,          // 0 | 90 | 180 | 270, clockwise; restarts the display
  "httpPort": 8080,
  "httpEnabled": true,

  "password": "cebelica"    // hashed into passwordHash/passwordSalt on load,
                            // then removed from the file
}
```

## Fonts

Four families are bundled, all covering č/š/ž/ć/đ and typographic quotes, so
nothing is fetched at runtime and nothing falls back to tofu on a bare Pi image:

| | |
| --- | --- |
| Inter | default; tight, neutral, good at distance |
| Noto Sans | wider language coverage |
| Noto Serif | for a printed-hymnal feel |
| Atkinson Hyperlegible | designed for low vision, the most forgiving from the back row |

All are SIL Open Font License; the licences ship in `assets/fonts/`.

## Development

```bash
flutter test
```

The web interface is served from `assets/web/` through the Flutter asset bundle,
so editing `app.css`, `app.js` or `index.html` needs a restart (a hot restart is
enough) to be picked up — there is no separate build step for it.

See [CLAUDE.md](CLAUDE.md) for the layout of `lib/` and the handful of things
that will bite you when changing the code.
