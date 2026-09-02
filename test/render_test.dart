import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/presenter.dart';
import 'package:pesmarica/src/data/songbook.dart';
import 'package:pesmarica/src/model/settings.dart';
import 'package:pesmarica/src/ui/page_style.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:pesmarica/src/ui/overlays.dart';
import 'package:pesmarica/src/ui/page_view.dart';
import 'package:pesmarica/src/ui/presenter_screen.dart';

void main() {
  late Directory root;
  late Songbook songbook;
  late Presenter presenter;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pesmarica-render');
    File(p.join(root.path, '001-prva.md')).writeAsStringSync(
      '# Čebelica šumi\n\nŽivžav in šum,\nčrede čez travnik.\n',
    );
    File(p.join(root.path, '002-dolga.md')).writeAsStringSync(
      '# Dolga stran\n\n${List<String>.filled(60, 'Kitica z zelo dolgo vrstico besedila.').join('\n\n')}\n',
    );
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
      MaterialApp(
        home: PresenterScreen(presenter: presenter, adminUrl: 'http://x:8080'),
      ),
    );
    // AutoFit converges over a handful of frames.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('renders Slovenian text and the chrome bar', (tester) async {
    await show(tester);
    // The title shows twice: as the page heading and in the chrome bar.
    expect(find.text('Čebelica šumi'), findsWidgets);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no text inherits the framework error underline', (tester) async {
    await show(tester);
    presenter.next();
    await tester.pump(const Duration(milliseconds: 400));
    // Outside a Material every Text gets the yellow double underline; the
    // chrome bar is where it showed.
    final style = DefaultTextStyle.of(tester.element(find.text('2 / 2'))).style;
    expect(style.decoration, isNot(TextDecoration.underline));
  });

  double positionOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.textContaining(' / '),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('the position count goes away and comes back', (tester) async {
    await show(tester);
    expect(positionOpacity(tester), 1.0);

    await tester.pump(ChromeBar.positionLinger);
    await tester.pump(const Duration(milliseconds: 500));
    expect(positionOpacity(tester), 0.0);

    presenter.next();
    await tester.pump();
    expect(positionOpacity(tester), 1.0);
    await tester.pump(ChromeBar.positionLinger);
    await tester.pump(const Duration(milliseconds: 500));
  });

  double bodyFontSize(WidgetTester tester) {
    expect(find.byType(SongPageView), findsOneWidget);
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    return body.styleSheet!.p!.fontSize!;
  }

  testWidgets('a long page is shrunk to fit rather than clipped', (
    tester,
  ) async {
    await show(tester);
    final short = bodyFontSize(tester);

    presenter.next();
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final long = bodyFontSize(tester);

    expect(long, lessThan(short));
    expect(tester.takeException(), isNull);
  });

  testWidgets('flipping polarity swaps the two colours', (tester) async {
    await show(tester);
    expect(presenter.settings.theme, PageTheme.dark);
    expect(
      PagePalette.of(presenter.settings.theme).background,
      PagePalette.dark.background,
    );

    // toggleTheme writes settings.json; real file I/O has to run outside the
    // fake async zone or the await never completes.
    await tester.runAsync(presenter.toggleTheme);
    await tester.pump();
    expect(
      PagePalette.of(presenter.settings.theme).background,
      PagePalette.light.background,
    );
  });

  testWidgets('the empty songbook explains itself instead of going black', (
    tester,
  ) async {
    for (final file in root.listSync().whereType<File>()) {
      if (file.path.endsWith('.md')) file.deleteSync();
    }
    await tester.runAsync(songbook.reload);
    await show(tester);
    expect(find.textContaining('Pesmarica je prazna'), findsOneWidget);
  });
}
