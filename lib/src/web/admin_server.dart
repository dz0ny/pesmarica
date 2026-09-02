import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../data/boot_config.dart';
import '../data/presenter.dart';
import '../data/songbook.dart';
import '../model/settings.dart';
import '../model/song_page.dart';
import '../update/bundle_installer.dart';
import '../update/bundle_slots.dart';
import 'credentials.dart';
import 'static_assets.dart';

/// A small HTTP service for editing the songbook and driving the display from
/// a phone or laptop on the same network.
///
/// It writes plain markdown into the content folder; the display picks the
/// change up through the file watcher, so there is no second source of truth.
class AdminServer {
  AdminServer(this.songbook, this.presenter, {BootConfig? boot})
    : boot = boot ?? BootConfig.fromEnvironment();

  final Songbook songbook;
  final Presenter presenter;

  /// The two files on the boot partition. What can be typed onto a card before
  /// the box has ever been switched on is also editable from here.
  final BootConfig boot;

  final StaticAssets _assets = StaticAssets();

  late final BundleSlots slots = BundleSlots(songbook.root);

  HttpServer? _server;

  /// `http://<lan-ip>:<port>`, or null while the server is not running.
  String? get url {
    final server = _server;
    if (server == null) return null;
    return 'http://${_displayHost(server.address)}:${server.port}';
  }

  Future<void> start() async {
    final settings = songbook.settings;
    if (!settings.httpEnabled) return;
    await stop();
    try {
      _server = await shelf_io.serve(
        const Pipeline()
            .addMiddleware(logRequests(logger: (m, _) => debugPrint(m)))
            .addMiddleware(_auth)
            .addHandler(_router.call),
        InternetAddress.anyIPv4,
        settings.httpPort,
      );
      debugPrint('pesmarica: web interface on ${await lanUrl()}');
    } on Object catch (e) {
      debugPrint('pesmarica: could not start web interface: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Best-effort LAN address, so the help card can show something the operator
  /// can actually type into a phone.
  Future<String?> lanUrl() async {
    final server = _server;
    if (server == null) return null;
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLinkLocal) {
            return 'http://${address.address}:${server.port}';
          }
        }
      }
    } on Object catch (_) {
      // Fall through to the generic form below.
    }
    return 'http://<ip>:${server.port}';
  }

  static String _displayHost(InternetAddress address) =>
      address.address == '0.0.0.0' ? 'localhost' : address.address;

  // --- Middleware ---------------------------------------------------------

  Credentials? get _credentials {
    final settings = songbook.settings;
    return settings.isProtected
        ? Credentials(hash: settings.passwordHash!, salt: settings.passwordSalt!)
        : null;
  }

  /// One password, no user name, remembered in a cookie until it changes.
  ///
  /// The password guards *editing*, not the room. Whoever is in the hall is
  /// already allowed to see the words on the wall, so the remote -- reading the
  /// page list and moving the display -- is open to anyone on the access point,
  /// and the password is what stands between them and rewriting the songbook.
  /// That is also what makes it worth setting: before, a password locked out
  /// the person you actually wanted driving the screen.
  ///
  /// API calls get a bare 401 so the page can react, while a navigation to the
  /// management page gets a real redirect, so typing the address just works.
  Handler _auth(Handler inner) => (Request request) async {
    final credentials = _credentials;
    if (credentials == null) return inner(request);

    final path = '/${request.url.path}';
    if (_isOpen(request.method, path)) return inner(request);
    if (credentials.matches(_presentedSecret(request))) return inner(request);

    if (path.startsWith('/api/')) {
      return Response.unauthorized('Potrebno je geslo.\n');
    }
    return Response.found('/login?next=${Uri.encodeComponent(path)}');
  };

  static final RegExp _remoteShow = RegExp(r'^/api/show/[0-9]+$');

  /// Whether a request is part of the remote, and so needs no password.
  ///
  /// Reading is open and writing is not, with two deliberate exceptions in each
  /// direction: `/manage` reads nothing but is the door to everything, so it
  /// asks; and the three navigation calls write nothing to the card -- they
  /// only move the display, which is the whole point of the remote.
  static bool _isOpen(String method, String path) {
    if (path == '/manage') return false;
    if (method == 'GET' && !path.startsWith('/api/')) return true;
    if (path == '/api/login' || path == '/api/logout') return true;
    if (method == 'GET' && (path == '/api/remote' || path == '/api/songbook')) {
      return true;
    }
    if (method == 'POST') {
      return path == '/api/next' ||
          path == '/api/prev' ||
          _remoteShow.hasMatch(path);
    }
    return false;
  }

  /// The cookie, or the header equivalent so that curl and cron can work
  /// without pretending to be a browser.
  String? _presentedSecret(Request request) {
    final header = request.headers['x-pesmarica-auth'];
    if (header != null && header.trim().isNotEmpty) return header.trim();
    return _cookie(request, Credentials.cookieName);
  }

  static String? _cookie(Request request, String name) {
    final header = request.headers['cookie'];
    if (header == null) return null;
    for (final part in header.split(';')) {
      final at = part.indexOf('=');
      if (at < 0) continue;
      if (part.substring(0, at).trim() == name) {
        return part.substring(at + 1).trim();
      }
    }
    return null;
  }

  // --- Routes -------------------------------------------------------------

  Router get _router => Router()
    ..get('/', (Request r) => _page('index.html'))
    ..get('/manage', (Request r) => _page('manage.html'))
    ..get('/login', (Request r) => _page('login.html'))
    ..get('/favicon.ico', (Request r) => _assets.serve(r, 'favicon.svg'))
    ..get('/static/<name|[A-Za-z0-9._-]+>', _assets.serve)
    ..post('/api/login', _login)
    ..post('/api/logout', _logout)
    ..get('/api/remote', (Request r) => _json(_remoteState()))
    ..get('/api/songbook', (Request r) => _json(_songbook()))
    ..get('/api/state', (Request r) => _json(_state()))
    ..get('/api/pages/<number|[0-9]+>', _getPage)
    ..put('/api/pages/<number|[0-9]+>', _putPage)
    ..delete('/api/pages/<number|[0-9]+>', _deletePage)
    ..post('/api/pages', _createPage)
    ..post('/api/pages/<number|[0-9]+>/renumber', _renumber)
    ..post('/api/import', _importPage)
    ..post('/api/show/<number|[0-9]+>', _show)
    ..post('/api/next', (Request r) {
      presenter.next();
      return _json(_remoteState());
    })
    ..post('/api/prev', (Request r) {
      presenter.previous();
      return _json(_remoteState());
    })
    ..put('/api/settings', _putSettings)
    ..get('/api/network', (Request r) => _json(_network()))
    ..put('/api/network', _putNetwork)
    ..post('/api/update', _installBundle)
    ..post('/api/images', _uploadImage)
    ..get('/media/<name|[^/]+>', _media)
    // What phones and laptops fetch to decide whether a network is usable.
    // Answering with a redirect is what makes the sign-in sheet pop open on the
    // songbook instead of the device declaring "no internet" and giving up.
    ..get('/generate_204', _portalProbe)
    ..get('/gen_204', _portalProbe)
    ..get('/hotspot-detect.html', _portalProbe)
    ..get('/library/test/success.html', _portalProbe)
    ..get('/ncsi.txt', _portalProbe)
    ..get('/connecttest.txt', _portalProbe)
    ..get('/canonical.html', _portalProbe)
    ..get('/success.txt', _portalProbe)
    ..all('/<ignored|.*>', _fallback);

  Future<Response> _page(String name) async => Response.ok(
    await _assets.readString(name),
    headers: const <String, String>{
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-cache',
    },
  );

  /// Ten years. "Remembered forever" is the requirement; a cookie cannot say
  /// forever, and this outlives the hardware.
  static const Duration _rememberFor = Duration(days: 3650);

  Future<Response> _login(Request request) async {
    final credentials = _credentials;
    final body = await _readJson(request);
    final password = '${body['password'] ?? ''}';

    if (credentials == null) return _json(<String, Object?>{'ok': true});
    if (!credentials.accepts(password)) {
      // Nothing to rate-limit against on a closed network, but do not make a
      // wrong guess free either.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return Response.unauthorized('Napačno geslo.\n');
    }

    return _json(
      <String, Object?>{'ok': true},
      headers: <String, String>{'set-cookie': _cookieHeader(credentials.hash)},
    );
  }

  Response _logout(Request request) => _json(
    <String, Object?>{'ok': true},
    headers: <String, String>{'set-cookie': _cookieHeader('', maxAge: 0)},
  );

  String _cookieHeader(String value, {int? maxAge}) => <String>[
    '${Credentials.cookieName}=$value',
    'Path=/',
    'Max-Age=${maxAge ?? _rememberFor.inSeconds}',
    'HttpOnly',
    'SameSite=Lax',
  ].join('; ');

  Response _json(
    Object? body, {
    int status = 200,
    Map<String, String> headers = const <String, String>{},
  }) => Response(
    status,
    body: jsonEncode(body),
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...headers,
    },
  );

  /// The polled answer: which page is up, and a counter that says whether the
  /// songbook itself has moved since the caller last asked.
  ///
  /// Deliberately tiny. Every phone in the room holds this open on a timer, and
  /// the box serving them is a Zero 2 W: the common case is "nothing changed",
  /// and it should cost about sixty bytes to say so. The list itself lives in
  /// [_songbook], fetched once and again only when [Songbook.revision] moves.
  ///
  /// Kept apart from [_state] because this one is served without a password, so
  /// it carries no settings and no version of the software.
  Map<String, Object?> _remoteState() => <String, Object?>{
    'current': presenter.current?.number,
    'protected': songbook.settings.isProtected,
    'rev': songbook.revision,
  };

  /// The page list, for whoever is browsing rather than driving.
  Map<String, Object?> _songbook() => <String, Object?>{
    'rev': songbook.revision,
    'pages': <Map<String, Object?>>[
      for (final page in songbook.pages)
        <String, Object?>{'number': page.number, 'title': page.title},
    ],
  };

  Map<String, Object?> _state() => <String, Object?>{
    'current': presenter.current?.number,
    'rev': songbook.revision,
    'protected': songbook.settings.isProtected,
    'settings': songbook.settings.toJson(),
    'update': slots.describe(),
    'fonts': <Map<String, String>>[
      for (final font in AppFont.all)
        <String, String>{'id': font.id, 'label': font.label},
    ],
    'pages': <Map<String, Object?>>[
      for (final page in songbook.pages)
        <String, Object?>{
          'number': page.number,
          'title': page.title,
          'file': page.fileName,
          'scale': page.scale,
        },
    ],
  };

  /// The page split the way the editor wants it: the words on their own, and
  /// the front matter as fields rather than as YAML.
  ///
  /// The whole point is that somebody who has never seen a `---` header can
  /// still set a title or magnify a page. `source` stays for scripts, which
  /// have no such trouble.
  Response _getPage(Request request, String number) {
    final index = songbook.indexOfNumber(int.parse(number));
    if (index < 0) return Response.notFound('Ni strani $number.\n');
    final page = songbook.pages[index];
    return _json(<String, Object?>{
      'number': page.number,
      'title': page.title,
      'file': page.fileName,
      'body': page.body,
      'front': <String, Object?>{
        // Null, not the derived title: the field is empty until somebody pins
        // one, and `derived` is what the page is called meanwhile.
        'title': page.declaredTitle,
        'derived': page.title,
        'scale': page.scale,
        'align': page.align.name,
        'showTitle': page.showTitle,
        // Keys Pesmarica does not interpret. Shown, not editable, so nobody
        // wonders where they went -- they are kept on every write.
        'extra': page.extra,
      },
      'source': File(page.path).readAsStringSync(),
    });
  }

  /// Takes either the raw markdown, as a script would send it, or the editor's
  /// `{front, body}` -- in which case the front matter is composed here, by the
  /// same code the display parses it with, and unknown keys survive.
  Future<Response> _putPage(Request request, String number) async {
    final wanted = int.parse(number);
    final raw = await request.readAsString();
    final isJson = (request.headers['content-type'] ?? '').contains(
      'application/json',
    );
    try {
      await songbook.writeSource(
        wanted,
        isJson ? _composePage(wanted, raw) : raw,
      );
    } on ArgumentError catch (e) {
      return Response.notFound('${e.message}\n');
    }
    return _json(_state());
  }

  String _composePage(int number, String json) {
    final index = songbook.indexOfNumber(number);
    if (index < 0) throw ArgumentError('Ni strani $number.');
    final body = jsonDecode(json) as Map<String, Object?>;
    final front = (body['front'] as Map<String, Object?>?) ?? const {};

    final title = (front['title'] as String?)?.trim();
    final showTitle = front['showTitle'];

    return songbook.pages[index]
        .copyWith(
          body: body['body'] as String?,
          declaredTitle: title,
          clearTitle: title == null || title.isEmpty,
          scale: (front['scale'] as num?)?.toDouble(),
          align: front['align'] == 'center'
              ? PageAlign.center
              : PageAlign.start,
          showTitle: showTitle is bool ? showTitle : null,
          clearShowTitle: showTitle == null,
        )
        .toSource();
  }

  Future<Response> _deletePage(Request request, String number) async {
    await songbook.deletePage(int.parse(number));
    return _json(_state());
  }

  Future<Response> _createPage(Request request) async {
    final body = await _readJson(request);
    try {
      final created = await songbook.createPage(
        number: (body['number'] as num?)?.toInt(),
        title: body['title'] as String?,
        source: body['source'] as String?,
      );
      return _json(<String, Object?>{'number': created, ..._state()});
    } on ArgumentError catch (e) {
      return _json(<String, Object?>{'error': e.message}, status: 409);
    }
  }

  /// Moves a page to another number, which is what changing the running order
  /// means here: the number is the position.
  Future<Response> _renumber(Request request, String number) async {
    final body = await _readJson(request);
    final wanted = (body['number'] as num?)?.toInt();
    if (wanted == null) {
      return _json(<String, Object?>{'error': 'Manjka številka.'}, status: 400);
    }
    try {
      await songbook.renumberPage(int.parse(number), wanted);
      return _json(<String, Object?>{'number': wanted, ..._state()});
    } on ArgumentError catch (e) {
      return _json(<String, Object?>{'error': e.message}, status: 409);
    }
  }

  /// Takes a dropped `.md` file. The body is the raw markdown; `?name=` is
  /// the original file name, which is where the page number comes from.
  Future<Response> _importPage(Request request) async {
    final name = request.url.queryParameters['name'];
    if (name == null || name.trim().isEmpty) {
      return _json(<String, Object?>{'error': 'Manjka ?name='}, status: 400);
    }
    final source = await request.readAsString();
    if (source.trim().isEmpty) {
      return _json(<String, Object?>{'error': 'Prazna datoteka'}, status: 400);
    }
    final number = await songbook.importMarkdown(name, source);
    return _json(<String, Object?>{'number': number, ..._state()});
  }

  /// Restarts the appliance unit so flutter-pi picks up a new rotation. There
  /// is nothing to do off the box -- a desktop run has no unit to restart, and
  /// the failure is expected rather than worth reporting to the operator.
  Future<void> _restartDisplay() async {
    try {
      final result = await Process.run('systemctl', <String>[
        'restart',
        'pesmarica',
      ]);
      if (result.exitCode != 0) {
        debugPrint('pesmarica: display restart failed: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('pesmarica: could not restart the display: $e');
    }
  }

  // --- The network --------------------------------------------------------

  /// What `wifi.conf` on the boot partition says, plus whatever the last boot
  /// made of it. Never the passphrase.
  Map<String, Object?> _network() => <String, Object?>{
    'available': boot.available,
    'wifi': boot.readWifi().toJson(),
    'status': _joinStatus(),
  };

  /// The line `pesmarica-wifi-fallback.service` leaves on the card when a
  /// configured network does not come up. It is the only account of why a box
  /// is answering on its own access point instead of the network it was told to
  /// join, so the page shows it rather than making the operator guess.
  String? _joinStatus() {
    try {
      final file = File(p.join(boot.root.path, 'wifi.status'));
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  /// Points the box at a network, or empties the ssid to make it one again.
  ///
  /// The passphrase is only replaced when the body carries one: the page never
  /// receives it, so it cannot send it back, and re-typing it to change the
  /// country would be a trap. The checks are the ones wpa_supplicant would make
  /// -- anything it would refuse leaves the box unreachable, with the card the
  /// only way back.
  Future<Response> _putNetwork(Request request) async {
    if (!boot.available) {
      return _json(<String, Object?>{
        'error': 'Ta naprava nima zagonskega razdelka.',
      }, status: 409);
    }
    final body = await _readJson(request);
    final previous = boot.readWifi();
    final ssid = '${body['ssid'] ?? previous.ssid}'.trim();
    final country = '${body['country'] ?? previous.country}'.trim();
    final passphrase = body.containsKey('psk')
        ? '${body['psk'] ?? ''}'
        : previous.passphrase;

    if (utf8.encode(ssid).length > 32) {
      return _json(<String, Object?>{
        'error': 'Ime omrežja je lahko dolgo največ 32 znakov.',
      }, status: 400);
    }
    if (ssid.isNotEmpty && passphrase.isNotEmpty) {
      final length = utf8.encode(passphrase).length;
      if (length < 8 || length > 63) {
        return _json(<String, Object?>{
          'error': 'Geslo omrežja mora imeti med 8 in 63 znakov.',
        }, status: 400);
      }
    }

    try {
      await boot.writeWifi(
        WifiConfig(ssid: ssid, passphrase: passphrase, country: country),
      );
    } on Object catch (e) {
      debugPrint('pesmarica: could not write wifi.conf: $e');
      return _json(<String, Object?>{
        'error': 'Nastavitve omrežja ni bilo mogoče shraniti.',
      }, status: 500);
    }

    // Answer first: applying this takes the radio down, and on the access point
    // that is the connection this reply is travelling on.
    Future<void>.delayed(const Duration(milliseconds: 300), _applyNetwork);
    return _json(_network());
  }

  /// Hands the change to the unit that owns the radio. It re-reads the same
  /// files the boot does and moves the box between being a network and being on
  /// one -- including the fallback, so a network that does not answer still
  /// brings the access point back without anyone touching the box.
  Future<void> _applyNetwork() async {
    try {
      final result = await Process.run('systemctl', <String>[
        'start',
        '--no-block',
        'pesmarica-network-apply.service',
      ]);
      if (result.exitCode != 0) {
        debugPrint('pesmarica: network apply failed: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('pesmarica: could not apply the network settings: $e');
    }
  }

  Response _show(Request request, String number) {
    final ok = presenter.goToNumber(int.parse(number));
    return _json(<String, Object?>{'ok': ok, ..._remoteState()});
  }

  Future<Response> _putSettings(Request request) async {
    final body = await _readJson(request);
    final previous = songbook.settings;
    final next = Settings.fromJson(<String, Object?>{
      ...previous.toJson(),
      ...body,
    });
    await songbook.saveSettings(next);
    // Changing the port or switching the interface off has to take effect
    // without an app restart, otherwise the operator is locked out of the fix.
    if (next.httpPort != previous.httpPort ||
        next.httpEnabled != previous.httpEnabled) {
      Future<void>.delayed(const Duration(milliseconds: 300), start);
    }
    // Rotation is a flutter-pi startup flag, so the display has to come back up
    // to apply it. Answer first: the restart takes this server down with it.
    if (next.rotation != previous.rotation) {
      // The launcher reads display.conf before settings.json, because that is
      // the copy you can put on a card for a screen nobody can read yet. Keep
      // it in step here or the box would turn back on the next boot.
      if (boot.available) {
        try {
          await boot.writeRotation(next.rotation);
        } on Object catch (e) {
          debugPrint('pesmarica: could not write the rotation to the card: $e');
        }
      }
      Future<void>.delayed(const Duration(milliseconds: 300), _restartDisplay);
    }
    return _json(_state());
  }

  /// Takes a new app bundle as a `.tar` body and installs it into the slot that
  /// is not running, then restarts onto it.
  ///
  /// Only with a password set. Everything else here writes pages; this writes
  /// the program the box runs next, and an appliance whose web interface is
  /// open to anyone on the access point should not also hand out the ability to
  /// replace its software. The refusal names the fix rather than pretending the
  /// endpoint does not exist.
  Future<Response> _installBundle(Request request) async {
    if (!songbook.settings.isProtected) {
      return _json(<String, Object?>{
        'error': 'Posodobitev je mogoča le, ko je nastavljeno geslo.',
      }, status: 403);
    }

    try {
      final slot = await BundleInstaller(slots).install(
        request.read(),
        version: request.url.queryParameters['version'],
      );
      // Answer before the restart: it takes this server down with it, and the
      // browser needs to be told which slot it is now watching come up.
      Future<void>.delayed(const Duration(milliseconds: 300), _restartDisplay);
      return _json(<String, Object?>{'ok': true, 'slot': slot});
    } on BundleRejected catch (e) {
      return _json(<String, Object?>{'error': e.message}, status: 400);
    } on Object catch (e) {
      debugPrint('pesmarica: bundle install failed: $e');
      return _json(<String, Object?>{
        'error': 'Posodobitev ni uspela.',
      }, status: 500);
    }
  }

  Future<Response> _uploadImage(Request request) async {
    final name = request.url.queryParameters['name'];
    if (name == null || name.trim().isEmpty) {
      return _json(<String, Object?>{'error': 'Manjka ?name='}, status: 400);
    }
    final bytes = await request.read().expand((chunk) => chunk).toList();
    if (bytes.isEmpty) {
      return _json(<String, Object?>{'error': 'Prazna datoteka'}, status: 400);
    }
    final file = await songbook.saveImage(name, bytes);
    final relative = 'images/${p.basename(file.path)}';
    return _json(<String, Object?>{
      'path': relative,
      'markdown': '![](${Uri.encodeFull(relative)})',
    });
  }

  Future<Response> _media(Request request, String name) async {
    final file = File(p.join(songbook.mediaDir.path, p.basename(name)));
    if (!file.existsSync()) return Response.notFound('Ni najdeno.\n');
    return Response.ok(
      file.openRead(),
      headers: <String, String>{
        'content-type': _mimeFor(file.path),
        'cache-control': 'no-cache',
      },
    );
  }

  static String _mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.svg':
        return 'image/svg+xml';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }

  Response _portalProbe(Request request) => Response.found(_portalTarget(request));

  /// An unknown path is far more likely to be a device probing the network than
  /// a real 404, because every name on this network resolves here. Send GETs
  /// that would render to the songbook and keep honest 404s for the API.
  Response _fallback(Request request) {
    if (request.method == 'GET' && !request.url.path.startsWith('api/')) {
      return Response.found(_portalTarget(request));
    }
    return Response.notFound('Ni najdeno.\n');
  }

  String _portalTarget(Request request) {
    final host = request.headers['host'];
    return host == null ? '/' : 'http://$host/';
  }

  Future<Map<String, Object?>> _readJson(Request request) async {
    final text = await request.readAsString();
    if (text.trim().isEmpty) return <String, Object?>{};
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }
}
