import 'package:flutter_test/flutter_test.dart';
import 'package:pesmarica/src/model/settings.dart';

void main() {
  test('keeps the four right angles', () {
    for (final degrees in <int>[0, 90, 180, 270]) {
      final settings = Settings.decode('{"rotation": $degrees}');
      expect(settings.rotation, degrees);
    }
  });

  test('falls back to no rotation on a value that would tilt the picture', () {
    // A panel showing a corner of the songbook looks like a dead box, and the
    // only way back would be ssh.
    for (final bad in <String>['45', '-90', '"sideways"', 'null', '360']) {
      expect(Settings.decode('{"rotation": $bad}').rotation, 0);
    }
  });

  test('rotation survives a rewrite', () {
    // Settings.toJson drops anything it does not know, so a field that is not
    // carried explicitly is lost the next time the file is written.
    final saved = Settings.decode('{"rotation": 270}').encode();
    expect(Settings.decode(saved).rotation, 270);
  });
}
