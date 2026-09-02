import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/songbook.dart';

/// The number in the file name is the running order, so changing the order and
/// renaming the file are the same operation.
void main() {
  late Directory root;
  late Songbook songbook;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pesmarica-renumber');
    songbook = Songbook(root);
    await songbook.start();
    await songbook.createPage(number: 1, title: 'Prva');
    await songbook.createPage(number: 2, title: 'Druga');
  });

  tearDown(() {
    songbook.dispose();
    root.deleteSync(recursive: true);
  });

  List<int> numbers() => songbook.pages.map((page) => page.number).toList();

  test('a page moves to a free number, and the order follows', () async {
    await songbook.renumberPage(1, 9);
    expect(numbers(), <int>[2, 9]);
    expect(songbook.pages.last.title, 'Prva');
  });

  test('the file is renamed after the title it now carries', () async {
    await songbook.writeSource(2, '# Nov naslov\n\nBesedilo.\n');
    await songbook.renumberPage(2, 7);
    expect(
      p.basename(songbook.pages.last.path),
      '007-nov-naslov.md',
    );
  });

  test('an occupied number is refused rather than overwritten', () async {
    await expectLater(
      songbook.renumberPage(1, 2),
      throwsA(isA<ArgumentError>()),
    );
    expect(numbers(), <int>[1, 2]);
    expect(root.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.md'),
    ).length, 2);
  });

  test('a page that is not there, and a number that cannot be', () async {
    await expectLater(songbook.renumberPage(42, 3), throwsA(isA<ArgumentError>()));
    await expectLater(songbook.renumberPage(1, 0), throwsA(isA<ArgumentError>()));
  });

  test('moving a page onto itself is not an error', () async {
    expect(await songbook.renumberPage(1, 1), 1);
    expect(numbers(), <int>[1, 2]);
  });
}
