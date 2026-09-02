import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesmarica/src/web/static_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every file the interface serves is actually bundled', () async {
    for (final entry in StaticAssets.allowed.entries) {
      final data = await rootBundle.load(entry.value);
      expect(data.lengthInBytes, greaterThan(0), reason: '${entry.key} is empty');
    }
  });

  test('the pages only reference files that are served', () async {
    // The modules import each other by URL as well, so a missing entry in the
    // allowlist breaks the page just as thoroughly as a missing <script>.
    final pattern = RegExp(r'/static/([A-Za-z0-9._-]+)');
    const sources = <String>[
      'index.html',
      'manage.html',
      'login.html',
      'remote.js',
      'manage.js',
      'common.js',
      'app.css',
    ];
    for (final source in sources) {
      final text = await rootBundle.loadString('assets/web/$source');
      final referenced = pattern
          .allMatches(text)
          .map((m) => m.group(1)!)
          .toSet();
      if (source.endsWith('.html')) {
        expect(referenced, isNotEmpty, reason: '$source loads no assets at all');
      }
      expect(
        referenced.difference(StaticAssets.allowed.keys.toSet()),
        isEmpty,
        reason: '$source points at something the server will 404',
      );
    }
  });

  test('content types are right, so the browser executes what it should', () {
    expect(StaticAssets.contentTypeFor('remote.js'), startsWith('text/javascript'));
    expect(StaticAssets.contentTypeFor('app.css'), startsWith('text/css'));
    expect(StaticAssets.contentTypeFor('index.html'), startsWith('text/html'));
    expect(StaticAssets.contentTypeFor('favicon.svg'), 'image/svg+xml');
    expect(StaticAssets.contentTypeFor('atkinson.ttf'), 'font/ttf');
    expect(
      StaticAssets.contentTypeFor('anything.else'),
      'application/octet-stream',
    );
  });

  test('the allowlist is the whole story — nothing else can be reached', () {
    // The router pattern already rejects slashes; this pins the second guard.
    expect(StaticAssets.allowed.keys, isNot(contains('..')));
    for (final name in StaticAssets.allowed.keys) {
      expect(name, isNot(contains('/')));
    }
  });
}
