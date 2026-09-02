import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/presenter.dart';
import 'package:pesmarica/src/data/songbook.dart';
import 'package:pesmarica/src/web/admin_server.dart';

/// The password guards editing, not the room.
///
/// Anyone on the access point may drive the screen -- that is the whole point
/// of the remote, and the person free to run it on a Sunday morning is rarely
/// the person who knows the password. Everything that writes to the card, and
/// the management page that leads to it, still asks.
void main() {
  // The binding is here for rootBundle, so that the pages and their assets can
  // be fetched like anything else. It also stubs HttpClient out, which would
  // turn every request below into a 400 -- so hand the real one back.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late Songbook songbook;
  late AdminServer server;
  late String base;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pesmarica-remote');
    File(p.join(root.path, 'settings.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{'password': 'cebelica', 'httpPort': 0}),
    );
    songbook = Songbook(root);
    await songbook.start();
    await songbook.createPage(number: 1, title: 'Prva');
    await songbook.createPage(number: 2, title: 'Druga');
    server = AdminServer(songbook, Presenter(songbook));
    await server.start();
    base = server.url!;
  });

  tearDown(() async {
    await server.stop();
    songbook.dispose();
    root.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> call(
    String method,
    String path, {
    String? cookie,
    String body = '',
  }) async {
    final client = HttpClient();
    final request = await client.openUrl(method, Uri.parse('$base$path'));
    request.followRedirects = false;
    if (cookie != null) request.headers.set('cookie', cookie);
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response;
  }

  String cookie() => 'pesmarica=${songbook.settings.passwordHash}';

  test('the remote works without the password', () async {
    expect((await call('GET', '/api/remote')).statusCode, 200);
    expect((await call('GET', '/api/songbook')).statusCode, 200);
    expect((await call('POST', '/api/next')).statusCode, 200);
    expect((await call('POST', '/api/prev')).statusCode, 200);
    expect((await call('POST', '/api/show/2')).statusCode, 200);
  });

  test('the remote page and its assets are open', () async {
    expect((await call('GET', '/')).statusCode, 200);
    expect((await call('GET', '/static/remote.js')).statusCode, 200);
    expect((await call('GET', '/login')).statusCode, 200);
  });

  test('editing does not', () async {
    expect((await call('GET', '/api/state')).statusCode, 401);
    expect((await call('GET', '/api/pages/1')).statusCode, 401);
    expect((await call('PUT', '/api/pages/1', body: '# Vdor')).statusCode, 401);
    expect((await call('DELETE', '/api/pages/1')).statusCode, 401);
    expect((await call('POST', '/api/pages')).statusCode, 401);
    expect((await call('PUT', '/api/settings')).statusCode, 401);
    expect((await call('POST', '/api/update')).statusCode, 401);
    expect((await call('POST', '/api/images?name=a.png')).statusCode, 401);
    // The radio is the way into the room. Reading which network the box is on
    // is as gated as changing it: an ssid is a small thing to hand out, but it
    // is on the same side of the door as everything else that is not the
    // remote.
    expect((await call('GET', '/api/network')).statusCode, 401);
    expect((await call('PUT', '/api/network')).statusCode, 401);
  });

  test('the management page sends you to the unlock screen', () async {
    final response = await call('GET', '/manage');
    expect(response.statusCode, 302);
    expect(response.headers.value('location'), startsWith('/login?next='));
  });

  test('the password opens the other half', () async {
    expect((await call('GET', '/api/state', cookie: cookie())).statusCode, 200);
    expect((await call('GET', '/manage', cookie: cookie())).statusCode, 200);
  });

  Future<Map<String, Object?>> fetch(String path) async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('$base$path'));
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    client.close();
    return body as Map<String, Object?>;
  }

  test('the open half hands out no settings and no software version', () async {
    final body = await fetch('/api/remote');
    expect(body.keys, containsAll(<String>['current', 'rev', 'protected']));
    expect(body.containsKey('settings'), isFalse);
    expect(body.containsKey('update'), isFalse);
  });

  test('the poll carries no page list, and the revision says when to ask',
      () async {
    final polled = await fetch('/api/remote');
    expect(polled.containsKey('pages'), isFalse,
        reason: 'a thousand titles have no business in a three-second poll');

    final index = await fetch('/api/songbook');
    expect(index['rev'], polled['rev']);
    expect((index['pages']! as List<Object?>).length, 2);

    // Moving the display is not a change to the songbook, so the list stays
    // valid and nobody re-fetches it.
    await call('POST', '/api/next');
    expect((await fetch('/api/remote'))['rev'], polled['rev']);

    await songbook.createPage(title: 'Tretja');
    expect((await fetch('/api/remote'))['rev'], isNot(polled['rev']));
  });
}
