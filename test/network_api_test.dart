import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/boot_config.dart';
import 'package:pesmarica/src/data/presenter.dart';
import 'package:pesmarica/src/data/songbook.dart';
import 'package:pesmarica/src/web/admin_server.dart';

/// Changing which network the box is on, from the box.
///
/// The failure this guards against is a locked-out box: what the web interface
/// writes is what `pesmarica-boot-config.service` reads at boot, and anything
/// wpa_supplicant would refuse has to be refused here, while there is still
/// someone connected to be told about it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late Directory bootRoot;
  late Songbook songbook;
  late BootConfig boot;
  late AdminServer server;
  late String base;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pesmarica-net');
    bootRoot = Directory.systemTemp.createTempSync('pesmarica-net-boot');
    File(p.join(root.path, 'settings.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{'password': 'cebelica', 'httpPort': 0}),
    );
    songbook = Songbook(root);
    await songbook.start();
    boot = BootConfig(bootRoot);
    server = AdminServer(songbook, Presenter(songbook), boot: boot);
    await server.start();
    base = server.url!;
  });

  tearDown(() async {
    await server.stop();
    songbook.dispose();
    root.deleteSync(recursive: true);
    bootRoot.deleteSync(recursive: true);
  });

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, {
    Object? body,
  }) async {
    final client = HttpClient();
    final request = await client.openUrl(method, Uri.parse('$base$path'));
    request.headers.set('x-pesmarica-auth', songbook.settings.passwordHash!);
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    client.close();
    return (
      response.statusCode,
      jsonDecode(text) as Map<String, Object?>,
    );
  }

  test('joining a network writes the file the boot reads', () async {
    final (status, body) = await call('PUT', '/api/network', body: {
      'ssid': 'Zupnija',
      'psk': 'nekogeslo',
      'country': 'SI',
    });
    expect(status, 200);
    expect((body['wifi']! as Map<String, Object?>)['ssid'], 'Zupnija');

    final wifi = boot.readWifi();
    expect(wifi.ssid, 'Zupnija');
    expect(wifi.passphrase, 'nekogeslo');
    expect(wifi.country, 'SI');
  });

  test('the passphrase never comes back out', () async {
    await call('PUT', '/api/network', body: {'ssid': 'Z', 'psk': 'nekogeslo'});
    final (_, body) = await call('GET', '/api/network');
    expect(jsonEncode(body), isNot(contains('nekogeslo')));
    expect((body['wifi']! as Map<String, Object?>)['hasPassphrase'], isTrue);
  });

  test('a change that carries no passphrase keeps the stored one', () async {
    await call('PUT', '/api/network', body: {'ssid': 'Z', 'psk': 'nekogeslo'});
    await call('PUT', '/api/network', body: {'ssid': 'Z', 'country': 'SI'});
    expect(boot.readWifi().passphrase, 'nekogeslo',
        reason: 'the page cannot re-send what it was never given');
  });

  test('what wpa_supplicant would refuse is refused here', () async {
    final (short, _) = await call('PUT', '/api/network', body: {
      'ssid': 'Zupnija',
      'psk': 'kratko',
    });
    expect(short, 400);

    final (long, _) = await call('PUT', '/api/network', body: {
      'ssid': 'x' * 33,
      'psk': 'nekogeslo',
    });
    expect(long, 400);

    expect(boot.readWifi().joins, isFalse,
        reason: 'a rejected change must not half-land on the card');
  });

  test('an empty ssid puts the box back on its own network', () async {
    await call('PUT', '/api/network', body: {'ssid': 'Z', 'psk': 'nekogeslo'});
    final (status, body) = await call('PUT', '/api/network', body: {'ssid': ''});
    expect(status, 200);
    expect((body['wifi']! as Map<String, Object?>)['hasPassphrase'], isFalse);
    expect(boot.readWifi().joins, isFalse);
  });

  test('an open network needs no passphrase', () async {
    final (status, _) = await call('PUT', '/api/network', body: {
      'ssid': 'Gost',
      'psk': '',
    });
    expect(status, 200);
    expect(boot.readWifi().ssid, 'Gost');
    expect(boot.readWifi().passphrase, isEmpty);
  });

  test('a box with no boot partition says so rather than pretending', () async {
    final gone = Directory(p.join(bootRoot.path, 'nowhere'));
    final other = AdminServer(
      songbook,
      Presenter(songbook),
      boot: BootConfig(gone),
    );
    await other.start();
    final client = HttpClient();
    final request = await client.putUrl(Uri.parse('${other.url}/api/network'));
    request.headers.set('x-pesmarica-auth', songbook.settings.passwordHash!);
    request.write(jsonEncode(<String, Object?>{'ssid': 'Z'}));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    expect(response.statusCode, 409);
    await other.stop();
  });

  test('the rotation the launcher reads follows the one the operator sets',
      () async {
    final client = HttpClient();
    final request = await client.putUrl(Uri.parse('$base/api/settings'));
    request.headers.set('x-pesmarica-auth', songbook.settings.passwordHash!);
    request.write(jsonEncode(<String, Object?>{'rotation': 90}));
    final response = await request.close();
    await response.drain<void>();
    client.close();

    expect(boot.readRotation(), 90,
        reason: 'display.conf is what the launcher starts flutter-pi with');
    expect(songbook.settings.rotation, 90);
  });
}
