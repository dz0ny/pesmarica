import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

/// Serves the web interface's files out of the Flutter asset bundle.
///
/// They are assets rather than files on disk because the signage host has no
/// document root to speak of: on the Pi the app is a flutter-pi bundle in
/// `/opt`, and pointing a static file server at it would couple the HTTP layer
/// to the deploy layout. Reading through [rootBundle] works the same in a
/// desktop debug run, a widget test and a release bundle.
class StaticAssets {
  StaticAssets();

  final Map<String, _Asset> _cache = <String, _Asset>{};

  /// The files the interface may hand out, mapped to where they sit in the
  /// bundle. An allowlist rather than path sanitising: the set is small, known
  /// at build time, and this way a traversal bug cannot exist.
  ///
  /// The typeface is the one exception to "everything under assets/web": the
  /// remote sets its page numbers in the same face the wall does, and there is
  /// no reason to keep a second copy of the file to say so.
  static const Map<String, String> allowed = <String, String>{
    'index.html': 'assets/web/index.html',
    'manage.html': 'assets/web/manage.html',
    'login.html': 'assets/web/login.html',
    'app.css': 'assets/web/app.css',
    'common.js': 'assets/web/common.js',
    'remote.js': 'assets/web/remote.js',
    'icons.js': 'assets/web/icons.js',
    'manage.js': 'assets/web/manage.js',
    'markdown.js': 'assets/web/markdown.js',
    'media.js': 'assets/web/media.js',
    'preact.js': 'assets/web/preact.js',
    'login.js': 'assets/web/login.js',
    'favicon.svg': 'assets/web/favicon.svg',
    'atkinson.ttf': 'assets/fonts/AtkinsonHyperlegible-Regular.ttf',
  };

  Future<Response> serve(Request request, String name) async {
    if (!allowed.containsKey(name)) return Response.notFound('Ni najdeno.\n');
    final asset = await _load(name);

    // Assets only change when the app is redeployed, so let the browser keep
    // them and revalidate cheaply.
    if (request.headers['if-none-match'] == asset.etag) {
      return Response.notModified(headers: _headers(asset));
    }
    return Response.ok(asset.bytes, headers: _headers(asset));
  }

  Map<String, String> _headers(_Asset asset) => <String, String>{
    'content-type': asset.contentType,
    'etag': asset.etag,
    'cache-control': 'no-cache',
  };

  Future<_Asset> _load(String name) async {
    final cached = _cache[name];
    if (cached != null) return cached;

    final data = await rootBundle.load(allowed[name]!);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final asset = _Asset(
      bytes: bytes,
      contentType: contentTypeFor(name),
      etag: '"${md5.convert(bytes)}"',
    );
    _cache[name] = asset;
    return asset;
  }

  /// The bytes of one asset, for handlers that render it themselves.
  Future<String> readString(String name) async =>
      utf8.decode((await _load(name)).bytes);

  static String contentTypeFor(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.html':
        return 'text/html; charset=utf-8';
      case '.css':
        return 'text/css; charset=utf-8';
      case '.js':
        return 'text/javascript; charset=utf-8';
      case '.svg':
        return 'image/svg+xml';
      case '.json':
        return 'application/json; charset=utf-8';
      case '.ttf':
        return 'font/ttf';
      default:
        return 'application/octet-stream';
    }
  }
}

class _Asset {
  const _Asset({
    required this.bytes,
    required this.contentType,
    required this.etag,
  });

  final Uint8List bytes;
  final String contentType;
  final String etag;
}
