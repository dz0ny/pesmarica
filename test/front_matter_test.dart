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

    test('a page of nothing but images is an image page', () {
      final page = SongPage.parse(
        '/x/010-slike.md',
        '---\ntitle: Oznanila\n---\n\n![](a.jpg)\n\n![druga](b.png "z naslovom")\n',
        number: 10,
      );
      expect(page.isImagePage, isTrue);
      expect(page.images, <String>['a.jpg', 'b.png']);
    });

    test('a video is written as an image and known by its extension', () {
      final page = SongPage.parse(
        '/x/012-video.md',
        '---\ntitle: Klip\n---\n\n![](klip.MP4)\n',
        number: 12,
      );
      expect(page.isImagePage, isTrue);
      expect(page.hasVideo, isTrue);
      expect(SongPage.isVideo('klip.MP4'), isTrue);
    });

    test('a container the box cannot decode is not a video', () {
      // .webm plays on any laptop and would run the four cores flat here, so
      // it stays an image source and fails visibly rather than silently.
      expect(SongPage.isVideo('klip.webm'), isFalse);
      expect(SongPage.isVideo('slika.jpg'), isFalse);
      final page = SongPage.parse('/x/013-a.md', '![](a.jpg)\n', number: 13);
      expect(page.hasVideo, isFalse);
    });

    test('an image next to words is prose with a picture in it', () {
      final page = SongPage.parse(
        '/x/011-mesano.md',
        'Pojemo\n\n![](a.jpg)\n',
        number: 11,
      );
      expect(page.isImagePage, isFalse);
      expect(page.images, isEmpty);
    });

    test('slideshow is seconds, and true is the default', () {
      SongPage read(String header) =>
          SongPage.parse('/x/012-a.md', '---\n$header\n---\n\n![](a.jpg)\n', number: 12);

      expect(read('slideshow: 8').slideshow, const Duration(seconds: 8));
      expect(read('slideshow: true').slideshow, SongPage.defaultSlideshow);
      expect(read('slideshow: false').slideshow, isNull);
      expect(read('slideshow: nekaj').slideshow, isNull);
      expect(read('slideshow: 0').slideshow, isNull);
      expect(read('slideshow: 9999').slideshow?.inSeconds, SongPage.maxSlideshowSeconds);
      expect(SongPage.parse('/x/013-a.md', '![](a.jpg)\n', number: 13).slideshow, isNull);
    });

    test('slideshow survives a rewrite instead of leaking into extra', () {
      final page = SongPage.parse(
        '/x/014-a.md',
        '---\nslideshow: 7\n---\n\n![](a.jpg)\n',
        number: 14,
      );
      expect(page.extra['slideshow'], isNull);

      final again = SongPage.parse('/x/014-a.md', page.toSource(scale: 1.2), number: 14);
      expect(again.slideshow, const Duration(seconds: 7));

      expect(page.copyWith(clearSlideshow: true).toSource(), isNot(contains('slideshow')));
    });

    test('clamps absurd magnification', () {
      expect(SongPage.clampScale(99), SongPage.maxScale);
      expect(SongPage.clampScale(0.01), SongPage.minScale);
      expect(SongPage.clampScale(double.nan), 1.0);
    });
  });

  group('the editor edits front matter as fields, not as YAML', () {
    SongPage open(String source) =>
        SongPage.parse('/songs/007-poskus.md', source, number: 7);

    test('clearing the title falls back to the heading in the body', () {
      final page = open('---\ntitle: Pinjeno\n---\n\n# Iz besedila\n');
      final cleared = page.copyWith(clearTitle: true);

      expect(cleared.title, 'Iz besedila');
      expect(cleared.toSource(), isNot(contains('title:')));
    });

    test('a new title is pinned, and the heading stops deciding', () {
      final page = open('# Iz besedila\n');
      final named = page.copyWith(declaredTitle: 'Po naše');

      expect(named.title, 'Po naše');
      expect(named.toSource(), contains('title: Po naše'));
    });

    test('showTitle has three states, and the third is not "false"', () {
      final page = open('---\nshowTitle: false\n---\n\n# Naslov\n');
      expect(page.showTitle, isFalse);

      final followsTheSongbook = page.copyWith(clearShowTitle: true);
      expect(followsTheSongbook.showTitle, isNull);
      expect(followsTheSongbook.toSource(), isNot(contains('showTitle')));
    });

    test('keys Pesmarica does not know survive the form', () {
      final page = open('---\nkomu: zboru\nscale: 1.0\n---\n\n# Naslov\n');
      final edited = page.copyWith(
        scale: 1.35,
        align: PageAlign.center,
        body: '\n# Drugo\n',
      );

      final source = edited.toSource();
      expect(source, contains('komu: zboru'));
      expect(source, contains('scale: 1.35'));
      expect(source, contains('align: center'));
      expect(source, contains('# Drugo'));
    });

    test('the body the editor is handed carries no header at all', () {
      final page = open('---\ntitle: Pinjeno\nscale: 2\n---\n\nPrva vrstica\n');
      expect(page.body, isNot(contains('---')));
      expect(page.body.trim(), 'Prva vrstica');
    });
  });
}
