import 'dart:io';
import 'dart:typed_data';

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

  testWidgets("the remote's zoom reaches the type on the wall", (tester) async {
    await show(tester);
    final plain = bodyFontSize(tester);

    // The zoom is part of the AutoFit signature through the scale it feeds, so
    // the fit restarts rather than leaving the page at the old size.
    presenter.nudgeZoom(2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(bodyFontSize(tester), closeTo(plain * 1.2, 0.01));

    // And it belongs to the page, not to the screen.
    presenter.next();
    presenter.previous();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(bodyFontSize(tester), closeTo(plain, 0.01));

    // The zoom flashes a note on screen; let its timer run out before the
    // tree goes away.
    await tester.pump(const Duration(seconds: 2));
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

  testWidgets('an image page fills the panel and cycles on its own', (tester) async {
    // Its own songbook: an image page has no title bar of its own to count,
    // and the fixture above is what the other tests measure against.
    final slides = Directory.systemTemp.createTempSync('pesmarica-slides');
    addTearDown(() => slides.deleteSync(recursive: true));
    // A real 1x1 PNG: Image.file decodes what it is handed, and a stub throws.
    final png = Uint8List.fromList(<int>[
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
      0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 192, 240, 31, 0, //
      5, 4, 2, 0, 155, 254, 84, 92, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ]);
    File(p.join(slides.path, 'prva.png')).writeAsBytesSync(png);
    File(p.join(slides.path, 'druga.png')).writeAsBytesSync(png);
    File(p.join(slides.path, '001-slike.md')).writeAsStringSync(
      '---\ntitle: Oznanila\nslideshow: 1\n---\n\n![](prva.png)\n\n![](druga.png)\n',
    );

    final book = Songbook(slides);
    // Real file I/O never completes inside the test's fake async zone.
    await tester.runAsync(book.start);
    addTearDown(book.dispose);
    final screen = Presenter(book);
    addTearDown(screen.dispose);

    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: PresenterScreen(presenter: screen, adminUrl: null)),
    );
    await tester.pump(const Duration(milliseconds: 250));

    // The incoming picture is the last one the switcher stacks.
    String shown() => (tester
                .widgetList<Image>(find.byType(Image))
                .last
                .image
            as FileImage)
        .file
        .path;

    // Contained across the whole width: no page padding on an image page.
    expect(tester.getSize(find.byType(Image).last).width, 1920);
    expect(p.basename(shown()), 'prva.png');

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(p.basename(shown()), 'druga.png');

    // And back around, rather than stopping on the last one.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(p.basename(shown()), 'prva.png');
    expect(tester.takeException(), isNull);
  });
}
