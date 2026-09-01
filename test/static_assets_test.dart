import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesmarica/src/web/static_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every file the interface serves is actually bundled', () async {
    for (final name in StaticAssets.allowed) {
      final data = await rootBundle.load('assets/web/$name');
      expect(data.lengthInBytes, greaterThan(0), reason: '$name is empty');
    }
  });

  test('the pages only reference files that are served', () async {
    final pattern = RegExp(r'/static/([A-Za-z0-9._-]+)');
    for (final page in <String>['index.html', 'login.html']) {
      final html = await rootBundle.loadString('assets/web/$page');
      final referenced = pattern
          .allMatches(html)
          .map((m) => m.group(1)!)
          .toSet();
      expect(referenced, isNotEmpty, reason: '$page loads no assets at all');
      expect(
        referenced.difference(StaticAssets.allowed),
        isEmpty,
        reason: '$page points at something the server will 404',
      );
    }
  });

  test('content types are right, so the browser executes what it should', () {
    expect(StaticAssets.contentTypeFor('app.js'), startsWith('text/javascript'));
    expect(StaticAssets.contentTypeFor('app.css'), startsWith('text/css'));
    expect(StaticAssets.contentTypeFor('index.html'), startsWith('text/html'));
    expect(StaticAssets.contentTypeFor('favicon.svg'), 'image/svg+xml');
    expect(
      StaticAssets.contentTypeFor('anything.else'),
      'application/octet-stream',
    );
  });

  test('the allowlist is the whole story — nothing else can be reached', () {
    // The router pattern already rejects slashes; this pins the second guard.
    expect(StaticAssets.allowed, isNot(contains('..')));
    for (final name in StaticAssets.allowed) {
      expect(name, isNot(contains('/')));
    }
  });
}
