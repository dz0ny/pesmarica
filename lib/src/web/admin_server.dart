import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../data/presenter.dart';
import '../data/songbook.dart';
import '../model/settings.dart';
import 'credentials.dart';
import 'static_assets.dart';

/// A small HTTP service for editing the songbook and driving the display from
/// a phone or laptop on the same network.
///
/// It writes plain markdown into the content folder; the display picks the
/// change up through the file watcher, so there is no second source of truth.
class AdminServer {
  AdminServer(this.songbook, this.presenter);

  final Songbook songbook;
  final Presenter presenter;

  final StaticAssets _assets = StaticAssets();

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
  /// The login page and its own assets stay open, or there would be no way to
  /// reach the form; everything else needs the cookie. API calls get a bare
  /// 401 so the browser can redirect itself, while a navigation gets a real
  /// redirect so that typing the address of a protected page just works.
  Handler _auth(Handler inner) => (Request request) async {
    final credentials = _credentials;
    if (credentials == null) return inner(request);

    final path = '/${request.url.path}';
    if (path == '/login' ||
        path == '/api/login' ||
        path == '/static/login.js' ||
        path == '/static/app.css' ||
        path == '/static/favicon.svg') {
      return inner(request);
    }

    if (credentials.matches(_presentedSecret(request))) return inner(request);

    if (path.startsWith('/api/')) {
      return Response.unauthorized('Potrebna je prijava.\n');
    }
    return Response.found('/login?next=${Uri.encodeComponent(path)}');
  };

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
    ..get('/login', (Request r) => _page('login.html'))
    ..get('/favicon.ico', (Request r) => _assets.serve(r, 'favicon.svg'))
    ..get('/static/<name|[A-Za-z0-9._-]+>', _assets.serve)
    ..post('/api/login', _login)
    ..post('/api/logout', _logout)
    ..get('/api/state', (Request r) => _json(_state()))
    ..get('/api/pages/<number|[0-9]+>', _getPage)
    ..put('/api/pages/<number|[0-9]+>', _putPage)
    ..delete('/api/pages/<number|[0-9]+>', _deletePage)
    ..post('/api/pages', _createPage)
    ..post('/api/import', _importPage)
    ..post('/api/show/<number|[0-9]+>', _show)
    ..post('/api/next', (Request r) {
      presenter.next();
      return _json(_state());
    })
    ..post('/api/prev', (Request r) {
      presenter.previous();
      return _json(_state());
    })
    ..put('/api/settings', _putSettings)
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

  Map<String, Object?> _state() => <String, Object?>{
    'current': presenter.current?.number,
    'protected': songbook.settings.isProtected,
    'settings': songbook.settings.toJson(),
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

  Response _getPage(Request request, String number) {
    final index = songbook.indexOfNumber(int.parse(number));
    if (index < 0) return Response.notFound('Ni strani $number.\n');
    final page = songbook.pages[index];
    return _json(<String, Object?>{
      'number': page.number,
      'title': page.title,
      'file': page.fileName,
      'source': File(page.path).readAsStringSync(),
    });
  }

  Future<Response> _putPage(Request request, String number) async {
    final body = await request.readAsString();
    try {
      await songbook.writeSource(int.parse(number), body);
    } on ArgumentError catch (e) {
      return Response.notFound('${e.message}\n');
    }
    return _json(_state());
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

  Response _show(Request request, String number) {
    final ok = presenter.goToNumber(int.parse(number));
    return _json(<String, Object?>{'ok': ok, ..._state()});
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
      Future<void>.delayed(const Duration(milliseconds: 300), _restartDisplay);
    }
    return _json(_state());
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
