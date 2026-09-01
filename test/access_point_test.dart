import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/net/access_point.dart';

const String shipped = '''
# Default access point.
interface=wlan0
driver=nl80211
country_code=SI
ieee80211d=1

ssid=Pesmarica
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1

auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=pesmarica

ap_isolate=1
''';

AccessPoint valid({
  String ssid = 'Pesmarica',
  String? passphrase = 'geslo1234',
  int channel = 6,
  String country = 'SI',
  bool hidden = false,
}) => AccessPoint(
  ssid: ssid,
  passphrase: passphrase,
  channel: channel,
  countryCode: country,
  hidden: hidden,
);

void main() {
  group('validation refuses anything that would not come up', () {
    test('accepts a sane configuration', () {
      expect(valid().problem, isNull);
      expect(valid(passphrase: null).problem, isNull, reason: 'open is allowed');
    });

    test('rejects an empty or oversized name', () {
      expect(valid(ssid: '').problem, isNotNull);
      expect(valid(ssid: '   ').problem, isNotNull);
      expect(valid(ssid: 'a' * 32).problem, isNull);
      expect(valid(ssid: 'a' * 33).problem, isNotNull);
    });

    test('counts the name in bytes, not characters', () {
      // 'č' is two bytes in UTF-8, so 17 of them overflow a 32-byte field.
      expect(valid(ssid: 'č' * 16).problem, isNull);
      expect(valid(ssid: 'č' * 17).problem, isNotNull);
    });

    test('rejects a passphrase WPA cannot use', () {
      expect(valid(passphrase: 'sedem77').problem, isNotNull);
      expect(valid(passphrase: 'osem1234').problem, isNull);
      expect(valid(passphrase: 'x' * 63).problem, isNull);
      expect(valid(passphrase: 'x' * 64).problem, isNotNull);
    });

    test('rejects a channel outside the 2.4 GHz band', () {
      expect(valid(channel: 0).problem, isNotNull);
      expect(valid(channel: 14).problem, isNotNull);
      expect(valid(channel: 36).problem, isNotNull);
      expect(valid(channel: 1).problem, isNull);
    });

    test('messages are in Slovenian, because the operator reads them', () {
      expect(valid(ssid: '').problem, contains('omrežja'));
    });
  });

  group('rendering', () {
    test('keeps the radio tuning it does not own', () {
      final out = AccessPointFile.render(shipped, valid(ssid: 'Cerkev'));
      for (final kept in <String>[
        'driver=nl80211',
        'hw_mode=g',
        'ieee80211n=1',
        'ap_isolate=1',
        '# Default access point.',
      ]) {
        expect(out, contains(kept), reason: '$kept was dropped');
      }
    });

    test('replaces the keys it does own exactly once', () {
      final out = AccessPointFile.render(shipped, valid(ssid: 'Cerkev'));
      // Count whole directives: `ignore_broadcast_ssid=` contains `ssid=`.
      int directives(String key) =>
          out.split('\n').where((l) => l.startsWith('$key=')).length;

      expect(directives('ssid'), 1);
      expect(directives('ignore_broadcast_ssid'), 1);
      expect(directives('wpa_passphrase'), 1);
      expect(directives('wpa'), 1);
      expect(out, contains('ssid=Cerkev'));
      expect(out, isNot(contains('ssid=Pesmarica')));
      expect(out, contains('wpa_passphrase=geslo1234'));
    });

    test('an open network leaves no WPA settings behind', () {
      final out = AccessPointFile.render(shipped, valid(passphrase: null));
      expect(out.split('\n').where((l) => l.startsWith('wpa')), isEmpty);
      expect(out, isNot(contains('wpa=')));
      expect(out, isNot(contains('wpa_passphrase')));
      expect(out, isNot(contains('wpa_key_mgmt')));
      expect(out, contains('ssid=Pesmarica'));
    });

    test('round-trips through the file', () async {
      final dir = Directory.systemTemp.createTempSync('pesmarica-ap');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'hostapd.conf');
      File(path).writeAsStringSync(shipped);

      final file = AccessPointFile(path);
      expect(file.exists, isTrue);
      expect(file.read()!.ssid, 'Pesmarica');
      expect(file.read()!.passphrase, 'pesmarica');
      expect(file.read()!.isOpen, isFalse);

      await file.write(valid(ssid: 'Župnija', passphrase: 'novogeslo', hidden: true));
      final again = file.read()!;
      expect(again.ssid, 'Župnija');
      expect(again.passphrase, 'novogeslo');
      expect(again.hidden, isTrue);
      expect(File(path).readAsStringSync(), contains('driver=nl80211'));
    });

    test('refuses to write a config that would take the network down', () async {
      final dir = Directory.systemTemp.createTempSync('pesmarica-ap');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'hostapd.conf');
      File(path).writeAsStringSync(shipped);

      final file = AccessPointFile(path);
      await expectLater(
        file.write(valid(passphrase: 'kratko')),
        throwsArgumentError,
      );
      expect(
        File(path).readAsStringSync(),
        shipped,
        reason: 'the working config must be left exactly as it was',
      );
    });

    test('is absent, not broken, where there is no access point', () {
      final file = AccessPointFile('/nonexistent/hostapd.conf');
      expect(file.exists, isFalse);
      expect(file.read(), isNull);
    });
  });

  test('the passphrase is never handed to the browser', () {
    final json = valid(passphrase: 'skrivnost').toJson();
    expect(json['protected'], isTrue);
    expect(json.values.join(' '), isNot(contains('skrivnost')));
    expect(json.containsKey('passphrase'), isFalse);
  });
}
