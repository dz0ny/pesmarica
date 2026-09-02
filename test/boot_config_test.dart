import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/boot_config.dart';

/// The two files on the boot partition, from the app's end.
///
/// The other end is shell -- `pesmarica-boot-config.service` in
/// `nix/modules/pesmarica.nix`, covered by `tool/test_boot_config.sh`. These
/// are the same files, so what one writes the other has to be able to read:
/// keep the cases here in step with the ones there.
void main() {
  late Directory root;
  late BootConfig boot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pesmarica-boot');
    boot = BootConfig(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  File file(String name) => File(p.join(root.path, name));

  test('a card with nothing on it says nothing', () {
    expect(boot.available, isTrue);
    expect(boot.readWifi().joins, isFalse);
    expect(boot.readRotation(), isNull);
  });

  test('a missing partition is not an error, only an absence', () {
    final gone = BootConfig(Directory(p.join(root.path, 'nowhere')));
    expect(gone.available, isFalse);
    expect(gone.readWifi().joins, isFalse);
    expect(gone.readRotation(), isNull);
  });

  test('reads what a laptop writes: a BOM, CRLF, comments', () {
    file('wifi.conf').writeAsStringSync(
      '﻿# omrezje v zupnisci\r\nssid=Zupnija\r\npsk=nekogeslo\r\n\r\n'
      'country=SI\r\n',
    );
    final wifi = boot.readWifi();
    expect(wifi.ssid, 'Zupnija');
    expect(wifi.passphrase, 'nekogeslo');
    expect(wifi.country, 'SI');
    expect(wifi.joins, isTrue);
  });

  test('a passphrase may contain an =', () {
    file('wifi.conf').writeAsStringSync('ssid=Zupnija\npsk=a=b=cdefgh\n');
    expect(boot.readWifi().passphrase, 'a=b=cdefgh');
  });

  test('the browser is told there is a passphrase, never what it is', () {
    file('wifi.conf').writeAsStringSync('ssid=Zupnija\npsk=nekogeslo\n');
    final json = boot.readWifi().toJson();
    expect(json['hasPassphrase'], isTrue);
    expect(json.containsKey('psk'), isFalse);
    expect('$json', isNot(contains('nekogeslo')));
  });

  test('writing keeps the lines it does not own', () async {
    file('wifi.conf').writeAsStringSync(
      '# soseda ima Telekom-1234\nssid=Staro\npsk=starogeslo\nrandom=vrednost\n',
    );
    await boot.writeWifi(
      const WifiConfig(ssid: 'Novo', passphrase: 'novogeslo', country: 'SI'),
    );
    final text = file('wifi.conf').readAsStringSync();
    expect(text, contains('# soseda ima Telekom-1234'));
    expect(text, contains('random=vrednost'));
    expect(text, contains('ssid=Novo'));
    expect(text, isNot(contains('starogeslo')));
    expect(boot.readWifi().country, 'SI');
  });

  test('an empty ssid takes the network out rather than leaving half of it',
      () async {
    file('wifi.conf').writeAsStringSync('ssid=Staro\npsk=starogeslo\n');
    await boot.writeWifi(const WifiConfig());
    expect(boot.readWifi().joins, isFalse);
    expect(file('wifi.conf').readAsStringSync(), isNot(contains('starogeslo')));
  });

  test('rotation is only ever one of the four a panel is mounted at', () async {
    file('display.conf').writeAsStringSync('rotation=90\n');
    expect(boot.readRotation(), 90);

    file('display.conf').writeAsStringSync('rotation=45\n');
    expect(boot.readRotation(), isNull,
        reason: 'a picture off the panel looks like a dead box');

    await boot.writeRotation(270);
    expect(boot.readRotation(), 270);
  });

  test('a rotation write leaves the wifi alone, and the other way round',
      () async {
    await boot.writeWifi(const WifiConfig(ssid: 'Zupnija', passphrase: 'geslo1234'));
    await boot.writeRotation(180);
    expect(boot.readWifi().ssid, 'Zupnija');
    expect(boot.readRotation(), 180);
    expect(file('display.conf').readAsStringSync(), isNot(contains('Zupnija')));
    expect(file('wifi.conf').readAsStringSync(), isNot(contains('rotation')));
  });
}
