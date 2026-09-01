import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesmarica/src/data/presenter.dart';
import 'package:pesmarica/src/data/songbook.dart';
import 'package:pesmarica/src/input/key_bindings.dart';
import 'package:pesmarica/src/model/settings.dart';
import 'package:pesmarica/src/model/song_page.dart';
import 'package:path/path.dart' as p;

Directory makeBook(List<(String, String)> files) {
  final dir = Directory.systemTemp.createTempSync('pesmarica-test');
  for (final (name, body) in files) {
    File(p.join(dir.path, name)).writeAsStringSync(body);
  }
  return dir;
}

KeyEvent down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
  logicalKey: key,
  physicalKey: PhysicalKeyboardKey.keyA,
  character: character,
  timeStamp: Duration.zero,
);

void main() {
  late Directory root;
  late Songbook songbook;
  late Presenter presenter;

  setUp(() async {
    root = makeBook(<(String, String)>[
      ('001-prva.md', '# Prva\n'),
      ('002-druga.md', '---\nscale: 1.5\n---\n# Druga\n'),
      ('017-sedemnajsta.md', '# Sedemnajsta\n'),
      ('brez-stevilke.md', '# Brez\n'),
    ]);
    songbook = Songbook(root);
    await songbook.start();
    presenter = Presenter(songbook);
  });

  tearDown(() {
    presenter.dispose();
    songbook.dispose();
    root.deleteSync(recursive: true);
  });

  test('orders by file name number and gives unnumbered files a slot', () {
    expect(
      songbook.pages.map((page) => page.number).toList(),
      <int>[1, 2, 17, 18],
    );
    expect(songbook.pages.last.title, 'Brez');
  });

  test('reads per-page magnification from the front matter', () {
    expect(songbook.pages[1].scale, 1.5);
  });

  test('walks forward and backward without running off the ends', () {
    expect(presenter.current!.number, 1);
    presenter.previous();
    expect(presenter.current!.number, 1);
    presenter.next();
    presenter.next();
    expect(presenter.current!.number, 17);
    presenter.last();
    presenter.next();
    expect(presenter.current!.number, 18);
  });

  test('typing digits then Enter jumps like PowerPoint', () {
    final keys = KeyBindings(presenter);
    keys.handle(down(LogicalKeyboardKey.digit1, character: '1'));
    keys.handle(down(LogicalKeyboardKey.digit7, character: '7'));
    expect(presenter.numberBuffer, '17');
    keys.handle(down(LogicalKeyboardKey.enter));
    expect(presenter.numberBuffer, isEmpty);
    expect(presenter.current!.number, 17);
  });

  test('Backspace edits the pending number, or pages back when there is none', () {
    final keys = KeyBindings(presenter);
    presenter.next();
    keys.handle(down(LogicalKeyboardKey.digit9, character: '9'));
    keys.handle(down(LogicalKeyboardKey.backspace));
    expect(presenter.numberBuffer, isEmpty);
    expect(presenter.current!.number, 2, reason: 'first Backspace only cleared the digit');
    keys.handle(down(LogicalKeyboardKey.backspace));
    expect(presenter.current!.number, 1);
  });

  test('Enter with nothing typed advances instead of jumping', () {
    final keys = KeyBindings(presenter);
    keys.handle(down(LogicalKeyboardKey.enter));
    expect(presenter.current!.number, 2);
  });

  test('jumping to a missing number keeps the page and says so', () {
    expect(presenter.goToNumber(999), isFalse);
    expect(presenter.current!.number, 1);
    expect(presenter.flash, contains('999'));
  });

  test('+ and - persist magnification into the markdown file', () async {
    final keys = KeyBindings(presenter);
    keys.handle(down(LogicalKeyboardKey.equal, character: '+'));
    keys.handle(down(LogicalKeyboardKey.equal, character: '+'));
    expect(presenter.current!.scale, closeTo(1.2, 1e-9));

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final onDisk = File(presenter.current!.path).readAsStringSync();
    expect(onDisk, contains('scale: 1.2'));
    expect(onDisk, contains('# Prva'));
  });

  test('B flips polarity and F walks the bundled fonts', () async {
    final keys = KeyBindings(presenter);
    expect(songbook.settings.theme, PageTheme.dark);
    keys.handle(down(LogicalKeyboardKey.keyB, character: 'b'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(songbook.settings.theme, PageTheme.light);

    final before = songbook.settings.fontId;
    keys.handle(down(LogicalKeyboardKey.keyF, character: 'f'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(songbook.settings.fontId, isNot(before));
    expect(AppFont.byId(songbook.settings.fontId).family, isNotEmpty);
  });

  test('settings survive a reload', () async {
    await songbook.saveSettings(
      songbook.settings.copyWith(theme: PageTheme.light, baseScale: 1.25),
    );
    final reopened = Songbook(root);
    await reopened.start();
    expect(reopened.settings.theme, PageTheme.light);
    expect(reopened.settings.baseScale, 1.25);
    reopened.dispose();
  });

  test('creating and deleting pages goes through the file system', () async {
    final number = await songbook.createPage(title: 'Čisto nova');
    expect(number, 19);
    expect(songbook.indexOfNumber(19), greaterThanOrEqualTo(0));
    expect(
      File(p.join(root.path, '019-cisto-nova.md')).existsSync(),
      isTrue,
      reason: 'čšž should be transliterated in file names',
    );

    await songbook.deletePage(19);
    expect(songbook.indexOfNumber(19), -1);
  });

  test('imports a dropped file, keeping a free number from its name', () async {
    final number = await songbook.importMarkdown(
      '020-Nova Čudna.md',
      '# Uvožena\n',
    );
    expect(number, 20);
    expect(
      File(p.join(root.path, '020-nova-cudna.md')).existsSync(),
      isTrue,
    );
    expect(songbook.pages.firstWhere((page) => page.number == 20).title, 'Uvožena');
  });

  test('a dropped file whose number is taken is filed after the last page', () async {
    final number = await songbook.importMarkdown('002-podvojena.md', '# Druga\n');
    expect(number, 19, reason: 'page 2 exists, so it goes after page 18');
    expect(songbook.indexOfNumber(2), 1, reason: 'the original is untouched');
  });

  test('a dropped file with no number in its name is appended', () async {
    expect(await songbook.importMarkdown('kar-neka.md', '# Neka\n'), 19);
  });

  test('a write survives being interrupted, because it is a rename', () async {
    // The temp file must never be picked up as a page, and the real file must
    // never be seen half written.
    await songbook.saveSettings(songbook.settings.copyWith(baseScale: 1.6));
    expect(
      File(p.join(root.path, 'settings.json.tmp')).existsSync(),
      isFalse,
      reason: 'the temp file is renamed away, not left behind',
    );
    expect(File(p.join(root.path, 'settings.json')).readAsStringSync(), isNotEmpty);

    File(p.join(root.path, '005-crash.md.tmp')).writeAsStringSync('# Pol napisano');
    await songbook.reload();
    expect(
      songbook.pages.map((page) => page.fileName),
      isNot(contains('005-crash.md.tmp')),
    );
  });

  test('refuses to create a page number that is already taken', () {
    expect(songbook.createPage(number: 2), throwsArgumentError);
  });

  test('showing pages writes nothing to the card', () async {
    // The card is the part that dies, so a service must not cost it writes.
    final file = File(songbook.pages.first.path);
    final before = file.lastModifiedSync();
    final source = file.readAsStringSync();

    presenter.next();
    presenter.previous();
    presenter.goToNumber(2);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(file.lastModifiedSync(), before);
    expect(file.readAsStringSync(), source);
  });

  test('sheds usage left over from an older songbook when the page is written', () {
    // Pages written before the counters were dropped still carry them; the next
    // rewrite is where they go, rather than in a pass of its own over the card.
    final page = SongPage.parse(
      '/tmp/010-old.md',
      '---\ntitle: Stara\nviews: 12\nlastShown: 2026-09-01T12:08:05.178826Z\n---\n\nBesedilo\n',
      number: 10,
    );
    final rewritten = page.toSource();
    expect(rewritten, isNot(contains('views:')));
    expect(rewritten, isNot(contains('lastShown:')));
    expect(rewritten, contains('title: Stara'));
  });
}
