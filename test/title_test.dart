import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/presenter.dart';
import 'package:pesmarica/src/data/songbook.dart';
import 'package:pesmarica/src/model/song_page.dart';
import 'package:pesmarica/src/ui/presenter_screen.dart';

void main() {
  late Directory root;
  late Songbook songbook;
  late Presenter presenter;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pesmarica-title');
    // 1: title only in the body.
    File(p.join(root.path, '001-body.md')).writeAsStringSync('# Iz telesa\n\nKitica\n');
    // 2: title only in the front matter.
    File(p.join(root.path, '002-matter.md'))
        .writeAsStringSync('---\ntitle: Iz glave\n---\n\nKitica\n');
    // 3: body heading, explicitly hidden.
    File(p.join(root.path, '003-hidden.md'))
        .writeAsStringSync('---\nshowTitle: false\n---\n\n# Skrit naslov\n\nKitica\n');
    songbook = Songbook(root);
    await songbook.start();
    presenter = Presenter(songbook);
  });

  tearDown(() {
    presenter.dispose();
    songbook.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: PresenterScreen(presenter: presenter, adminUrl: null)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  test('showTitle is null unless the page pins it', () {
    expect(songbook.pages[0].showTitle, isNull);
    expect(songbook.pages[2].showTitle, isFalse);
  });

  test('a pinned showTitle survives a rewrite', () {
    final page = songbook.pages[2];
    final again = SongPage.parse(page.path, page.toSource(scale: 1.3), number: 3);
    expect(again.showTitle, isFalse);
    expect(again.scale, 1.3);
    expect(songbook.pages[0].toSource(scale: 1.3), isNot(contains('showTitle')));
  });

  testWidgets('a front matter title is drawn as the heading it replaces', (tester) async {
    presenter.goToNumber(2);
    await show(tester);
    // Once as the page heading, once in the chrome bar.
    expect(find.text('Iz glave'), findsNWidgets(2));
  });

  testWidgets('hiding the title drops the leading heading too', (tester) async {
    presenter.goToNumber(3);
    await show(tester);
    expect(find.text('Skrit naslov'), findsNothing);
    expect(find.textContaining('Kitica'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'the number still guides the room');
  });

  testWidgets('the global default hides titles on pages that do not pin one', (tester) async {
    await tester.runAsync(
      () => songbook.saveSettings(songbook.settings.copyWith(showTitle: false)),
    );
    presenter.goToNumber(1);
    await show(tester);
    expect(find.text('Iz telesa'), findsNothing);

    await tester.runAsync(
      () => songbook.saveSettings(songbook.settings.copyWith(showTitle: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Iz telesa'), findsWidgets);
  });
}
