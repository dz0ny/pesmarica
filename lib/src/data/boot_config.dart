import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// The `key=value` files on the boot partition: `wifi.conf` and `display.conf`.
///
/// They are how a box is set up before it has ever been switched on -- the FAT
/// partition is the only one a freshly flashed card has, and the one a laptop
/// mounts by itself. The launcher and `pesmarica-boot-config.service` in
/// `nix/modules/pesmarica.nix` read the same two files at boot; this is the
/// same format from the other end, so that what can be typed onto a card can
/// also be changed from the web interface without pulling the card out.
///
/// Off the box there is no such partition. Every read then comes back empty and
/// [available] is false, which is what the web interface asks before offering
/// any of it.
class BootConfig {
  BootConfig(this.root);

  /// The unit passes `PESMARICA_BOOT`; a developer's machine has no boot
  /// partition and gets a path that does not exist, which is handled.
  factory BootConfig.fromEnvironment() {
    final configured = Platform.environment['PESMARICA_BOOT'];
    final path = (configured == null || configured.trim().isEmpty)
        ? '/boot/firmware'
        : configured.trim();
    return BootConfig(Directory(p.normalize(p.absolute(path))));
  }

  final Directory root;

  File get wifiFile => File(p.join(root.path, 'wifi.conf'));
  File get displayFile => File(p.join(root.path, 'display.conf'));

  /// Whether there is a boot partition to write to at all.
  bool get available => root.existsSync();

  // --- Reading ------------------------------------------------------------

  WifiConfig readWifi() {
    final fields = _read(wifiFile);
    return WifiConfig(
      ssid: fields['ssid'] ?? '',
      passphrase: fields['psk'] ?? '',
      country: fields['country'] ?? '',
    );
  }

  /// The rotation the box will start at, or null when the file says nothing --
  /// in which case the launcher falls back to the one in `settings.json`.
  int? readRotation() => _rotation(_read(displayFile)['rotation']);

  // --- Writing ------------------------------------------------------------

  /// Replaces the wifi fields, keeping anything else in the file.
  ///
  /// An empty [WifiConfig.ssid] removes them instead: the box has no network to
  /// join and comes up as an access point, which is the state someone standing
  /// next to it can do something about.
  Future<void> writeWifi(WifiConfig wifi) async {
    if (wifi.ssid.trim().isEmpty) {
      await _write(wifiFile, <String, String?>{
        'ssid': null,
        'psk': null,
        'country': null,
      });
      return;
    }
    await _write(wifiFile, <String, String?>{
      'ssid': wifi.ssid.trim(),
      'psk': wifi.passphrase.isEmpty ? null : wifi.passphrase,
      'country': wifi.country.trim().isEmpty ? null : wifi.country.trim(),
    });
  }

  Future<void> writeRotation(int degrees) =>
      _write(displayFile, <String, String?>{
        'rotation': '${_rotation(degrees) ?? 0}',
      });

  // --- The format ---------------------------------------------------------

  /// Tolerant on the way in, because these files are typed on a laptop: a UTF-8
  /// byte order mark, CRLF line endings, blank lines and `#` comments. A value
  /// is everything after the first `=`, which is what lets a passphrase contain
  /// one.
  static Map<String, String> parse(String source) {
    final fields = <String, String>{};
    for (final line in _lines(source)) {
      final at = line.indexOf('=');
      if (at <= 0) continue;
      final key = line.substring(0, at).trim().toLowerCase();
      if (key.isEmpty || key.startsWith('#')) continue;
      fields[key] = line.substring(at + 1).trim();
    }
    return fields;
  }

  Map<String, String> _read(File file) {
    try {
      if (!file.existsSync()) return const <String, String>{};
      return parse(file.readAsStringSync());
    } on Object catch (e) {
      debugPrint('pesmarica: could not read ${file.path}: $e');
      return const <String, String>{};
    }
  }

  /// Rewrites [changes] and leaves every other line as it was found: these
  /// files are hand-edited, and a comment somebody wrote to remind themselves
  /// of the neighbour's ssid should survive the web interface touching them. A
  /// null value removes the key.
  Future<void> _write(File file, Map<String, String?> changes) async {
    final kept = <String>[];
    final written = <String>{};
    final existing = file.existsSync() ? file.readAsStringSync() : '';

    for (final line in _lines(existing)) {
      final at = line.indexOf('=');
      final key = at > 0 ? line.substring(0, at).trim().toLowerCase() : '';
      if (!changes.containsKey(key)) {
        kept.add(line);
        continue;
      }
      final value = changes[key];
      if (value != null && written.add(key)) kept.add('$key=$value');
    }
    for (final entry in changes.entries) {
      final value = entry.value;
      if (value == null || written.contains(entry.key)) continue;
      kept.add('${entry.key}=$value');
    }

    final body = kept.isEmpty ? '' : '${kept.join('\n')}\n';
    // Same rename dance as every other write in this project: the box loses
    // mains power, and this partition has no journal at all.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(file.path);
  }

  static Iterable<String> _lines(String source) sync* {
    final text = source.startsWith('﻿') ? source.substring(1) : source;
    for (final line in text.split('\n')) {
      yield line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    }
  }

  /// Only the four a panel can be mounted at. Anything else would put the
  /// picture off the screen, and the way back is ssh.
  static int? _rotation(Object? value) {
    final degrees = value is int ? value : int.tryParse('${value ?? ''}'.trim());
    return const <int>[0, 90, 180, 270].contains(degrees) ? degrees : null;
  }
}

/// What `wifi.conf` says: a network to join, or nothing and the box is one.
@immutable
class WifiConfig {
  const WifiConfig({this.ssid = '', this.passphrase = '', this.country = ''});

  final String ssid;
  final String passphrase;
  final String country;

  bool get joins => ssid.trim().isNotEmpty;

  /// What the browser is told. The passphrase never leaves the box -- the same
  /// rule the admin password follows -- so the page is told whether there is
  /// one rather than what it is.
  Map<String, Object?> toJson() => <String, Object?>{
    'ssid': ssid,
    'country': country,
    'hasPassphrase': passphrase.isNotEmpty,
  };
}
