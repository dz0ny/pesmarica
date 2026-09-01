import 'package:flutter_test/flutter_test.dart';
import 'package:pesmarica/src/data/front_matter.dart';
import 'package:pesmarica/src/model/song_page.dart';

void main() {
  group('FrontMatter', () {
    test('separates header from body', () {
      final matter = FrontMatter.parse('---\ntitle: Čebela\nscale: 1.2\n---\n\n# Čebela\n');
      expect(matter.values['title'], 'Čebela');
      expect(matter.values['scale'], 1.2);
      expect(matter.body, '\n# Čebela\n');
    });

    test('treats a document without a header as all body', () {
      final matter = FrontMatter.parse('# Samo besedilo\n');
      expect(matter.values, isEmpty);
      expect(matter.body, '# Samo besedilo\n');
    });

    test('survives a malformed header instead of throwing', () {
      final matter = FrontMatter.parse('---\n: : :\n\tbad\n---\nbesedilo\n');
      expect(matter.values, isEmpty);
      expect(matter.body, 'besedilo\n');
    });

    test('drops null values and quotes risky scalars', () {
      final text = FrontMatter.compose(
        <String, Object?>{'title': '# ne naslov', 'scale': null, 'views': 3},
        'telo\n',
      );
      expect(text, contains('title: "# ne naslov"'));
      expect(text, isNot(contains('scale')));
      expect(text, contains('views: 3'));
    });

    test('composing nothing leaves the body untouched', () {
      expect(FrontMatter.compose(<String, Object?>{}, 'telo'), 'telo');
    });
  });

  group('SongPage', () {
    test('reads number from the file name prefix', () {
      expect(SongPage.numberFromFileName('012-nekaj.md'), 12);
      expect(SongPage.numberFromFileName('brez-stevilke.md'), isNull);
    });

    test('falls back from front matter title to heading to slug', () {
      final declared = SongPage.parse('/x/001-a.md', '---\ntitle: Naslov\n---\n# Drugo\n', number: 1);
      expect(declared.title, 'Naslov');

      final heading = SongPage.parse('/x/002-a.md', '## Iz naslova\n', number: 2);
      expect(heading.title, 'Iz naslova');

      final slug = SongPage.parse('/x/003-lepa-pesem.md', 'brez naslova\n', number: 3);
      expect(slug.title, 'lepa pesem');
    });

    test('round-trips zoom and unknown keys', () {
      const source = '---\ntitle: Test\nauthor: Nekdo\nscale: 1.4\nviews: 7\n---\n\n# Test\n';
      final page = SongPage.parse('/x/001-test.md', source, number: 1);
      expect(page.scale, 1.4);
      expect(page.extra['author'], 'Nekdo');

      final rewritten = page.toSource(scale: 1.8);
      final again = SongPage.parse('/x/001-test.md', rewritten, number: 1);
      expect(again.scale, 1.8);
      expect(again.extra['author'], 'Nekdo');
      // Dropped rather than carried: nothing reads it any more.
      expect(again.extra['views'], isNull);
      expect(rewritten, isNot(contains('views:')));
      expect(again.body.trim(), '# Test');
    });

    test('omits a title it never had, keeping the heading authoritative', () {
      final page = SongPage.parse('/x/004-a.md', '# Samo heading\n', number: 4);
      expect(page.toSource(scale: 1.2), isNot(contains('title:')));
    });

    test('scale 1.0 is written as no scale key at all', () {
      final page = SongPage.parse('/x/005-a.md', '---\nscale: 2\n---\nx\n', number: 5);
      expect(page.toSource(scale: 1.0), isNot(contains('scale')));
    });

    test('clamps absurd magnification', () {
      expect(SongPage.clampScale(99), SongPage.maxScale);
      expect(SongPage.clampScale(0.01), SongPage.minScale);
      expect(SongPage.clampScale(double.nan), 1.0);
    });
  });
}
