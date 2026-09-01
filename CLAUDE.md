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
curl -s localhost:8080/api/state | python3 -m json.tool
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
  src/web/admin_server.dart  shelf routes, cookie auth
  src/web/static_assets.dart serves assets/web/ from the Flutter bundle
  src/web/credentials.dart   salt, hash, constant-time compare
assets/web/                  the admin UI: html, css, js, favicon
```

`Songbook` and `Presenter` are plain `ChangeNotifier`s wired up by hand in
`main.dart`. There is no state-management package and no DI container; don't add
one for its own sake.

## Things that will bite you

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

**Showing a page writes nothing.** Navigation used to arm a five second timer
that stamped `views`/`lastShown` into the front matter; both the timer and the
fields are gone, because the box writes to an SD card that a parish hall will
brown out every winter. Nothing new should write on the display path — a write
belongs to a human editing a page.

**The bundled sans and serif families are variable fonts.** `FontWeight` alone
picks a named instance that a single-file variable font does not have, so bold
silently does nothing. Always go through `fontStyle()` in `page_style.dart`,
which sets `fontVariations` alongside `fontWeight`.

**The web UI lives in `assets/web/`, not in Dart.** It is served through
`rootBundle`, so a change to `app.css`/`app.js`/`index.html` needs a restart to
show up, and a new file must be added to both `StaticAssets.allowed` and the
`assets:` list in `pubspec.yaml` or it will 404.

**The access point is the only way into the box, and the app no longer touches
it.** `hostapd.conf` lives on the data partition beside the songbook, which is
exFAT precisely so it can be edited with the card in a laptop. A config hostapd
rejects is a brick, recoverable only by the `ap-preflight` fallback in the image
or a serial console, so nothing in the app may write that file — the web
interface used to and does not any more. Do not add a copy of the SSID to
`settings.json` either.

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

`os/` is a Buildroot external tree and the single definition of the system: the
unit, the partitions, the network, the paths. `tool/deploy_pi.sh` only pushes a
build onto a box that already runs the image — if you find yourself wanting to
install a unit from the repo, change the image instead.

The image cannot be built or booted from a test run here; it needs Docker and
a real Zero 2 W. Treat changes under `os/` as unverified until someone flashes
a card, and say so.

## Testing

`test/front_matter_test.dart` and `test/presenter_test.dart` are plain `test()`
over a temp songbook — fast, and where most logic belongs.
`test/render_test.dart` and `test/title_test.dart` are widget tests over a real
`PresenterScreen`.

Prefer asserting on values the app actually computes (e.g. the
`MarkdownStyleSheet` font size) over walking the render tree; finder-based
assertions on markdown output are brittle, and a page title legitimately appears
twice on screen (heading and chrome bar).
