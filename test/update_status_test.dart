import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/update/update_status.dart';

/// The one file the app reads about updates.
///
/// It is written by a shell script in the image, in tmpfs, while the app is
/// polling -- so every way that can go wrong ends in "draw nothing", never in a
/// half-read status that offers to reboot the box.
void main() {
  test('reads what the updater writes', () {
    final status = UpdateStatus.parse(
      '{"state":"ready","running":"v7","available":"v8","slot":"b",'
      '"checked":"2026-09-03T08:00:00Z"}',
    )!;
    expect(status.state, 'ready');
    expect(status.isReady, isTrue);
    expect(status.running, 'v7');
    expect(status.available, 'v8');
    expect(status.slot, 'b');
  });

  test('a state this version has never heard of still reaches the page', () {
    // The updater is in the image and the app is in the closure beside it, but
    // a box can run an older app than the script that writes this file.
    final status = UpdateStatus.parse('{"state":"nekaj-novega"}')!;
    expect(status.state, 'nekaj-novega');
    expect(status.isReady, isFalse);
  });

  test('only ready is ready', () {
    for (final state in <String>['off', 'offline', 'current', 'downloading', 'failed']) {
      expect(UpdateStatus.parse('{"state":"$state"}')!.isReady, isFalse);
    }
  });

  test('half a file, or no file at all, is nothing rather than a guess', () {
    // The status file is rewritten while the management page polls, so a read
    // landing mid-write is the normal case, not an exceptional one.
    expect(UpdateStatus.parse('{"state":"read'), isNull);
    expect(UpdateStatus.parse(''), isNull);
    expect(UpdateStatus.parse('[]'), isNull);
    expect(UpdateStatus.parse('{"available":"v8"}'), isNull);
    expect(UpdateStatus.parse('{"state":"  "}'), isNull);
  });

  test('a box with no updater says nothing at all', () {
    final root = Directory.systemTemp.createTempSync('pesmarica-update');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = UpdateStatusFile(File(p.join(root.path, 'update.json')));
    expect(file.read(), isNull);

    file.file.writeAsStringSync('{"state":"current","running":"v8"}');
    expect(file.read()!.state, 'current');
  });

  test('what goes back out to the page is what came in', () {
    final json = UpdateStatus.parse(
      '{"state":"failed","running":"v7","error":"prenos ni uspel"}',
    )!.toJson();
    expect(json, <String, Object?>{
      'state': 'failed',
      'running': 'v7',
      'error': 'prenos ni uspel',
    });
  });
}
