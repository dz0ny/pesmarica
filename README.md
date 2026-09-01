# Pesmarica

Digital signage for a songbook. Every page is one markdown file; the operator
drives the screen with a keypad, a presenter remote or a phone on the same
network. Built with Flutter, meant to run on a Raspberry Pi under
[flutter-pi](https://github.com/ardera/flutter-pi).

## The songbook is a folder

```
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

```markdown
---
title: Čebelica na travniku   # optional; otherwise the first heading, then the file name
scale: 1.1                    # magnification set with + / − on the display
align: center                 # start (default) or center
showTitle: false              # hide the title on this page
lastShown: 2026-09-01T12:08:05.178826Z   # written by the display
views: 12                                # written by the display
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
sign-in sheet open on it by themselves; otherwise open `http://192.168.4.1` or
`http://pesmarica.local`.

Out of the box the network is `Pesmarica` / `pesmarica` on channel 6 —
**change both before it leaves your desk**, under `Omrežje` in the web
interface. Saving restarts the radio and drops every connected device,
including the one you changed it from.

If a bad configuration ever does get written, the box does not become a brick:
`ap-preflight` checks the file before hostapd starts and restores the shipped
default if the name or passphrase could not work.

## Web interface

The app serves a management page on port 8080 (`http://192.168.4.1:8080`,
or `:8080` on whatever address you reach it at). It lists
the pages, edits them as raw markdown, creates and deletes them, drives the
display remotely, and sets the polarity, font and global magnification.

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

## Running it

Development, on a desktop:

```bash
PESMARICA_CONTENT=$PWD/content flutter run -d macos   # or -d linux
```

`PESMARICA_CONTENT` picks the songbook folder; without it Pesmarica uses
`./content` next to the working directory.

The web interface is served from `assets/web/` through the Flutter asset
bundle, so editing `app.css`, `app.js` or `index.html` needs a restart (a hot
restart is enough) to be picked up — there is no separate build step for it.

Tests:

```bash
flutter test
```

## Raspberry Pi

The appliance is a NixOS image, built in `nix/`. That image is the single
definition of the system — the unit files, the access point, the network, the
paths all live there and nowhere else:

```bash
cd nix && make image         # -> nix/out/sd-image/*.img.zst
make flash DISK=/dev/rdisk4
```

See [nix/README.md](nix/README.md) for the prerequisites (Docker via colima, and
Flutter pinned to 3.44.x in `mise.toml` — `flutterpi_tool` compiles against
`flutter_tools` internals and does not build against anything newer).

Between reflashes, push a new build onto a running box:

```bash
HOST=root@pesmarica.local ./tool/deploy_pi.sh
```

That syncs the bundle to `/var/lib/pesmarica/bundle-override` and the songbook to
`/var/lib/pesmarica` (without `--delete`, so pages created through the web
interface survive), then restarts the unit. It installs nothing: changing the
system means rebuilding the image.
