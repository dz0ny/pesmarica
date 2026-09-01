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
  StaticAssets({this.prefix = 'assets/web'});

  final String prefix;

  final Map<String, _Asset> _cache = <String, _Asset>{};

  /// Files the interface is allowed to hand out. An allowlist rather than path
  /// sanitising: the set is small, known at build time, and this way a traversal
  /// bug cannot exist.
  static const Set<String> allowed = <String>{
    'index.html',
    'login.html',
    'app.css',
    'app.js',
    'login.js',
    'favicon.svg',
  };

  Future<Response> serve(Request request, String name) async {
    if (!allowed.contains(name)) return Response.notFound('Ni najdeno.\n');
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

    final data = await rootBundle.load('$prefix/$name');
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
