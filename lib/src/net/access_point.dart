import 'dart:io';

import 'package:flutter/foundation.dart';

/// The wifi network the box itself broadcasts.
///
/// Pesmarica is always the access point and never a client: people connect to
/// it to reach the web interface. So the only network settings that exist are
/// the ones on this side of the radio.
@immutable
class AccessPoint {
  const AccessPoint({
    required this.ssid,
    required this.passphrase,
    required this.channel,
    required this.countryCode,
    required this.hidden,
  });

  /// The network name people see. 1–32 bytes, per 802.11.
  final String ssid;

  /// WPA2 passphrase, or null for an open network.
  ///
  /// Stored in the clear because hostapd needs it in the clear — unlike the web
  /// interface password, this one cannot be hashed. It lives on the data
  /// partition, readable only by root.
  final String? passphrase;

  /// 2.4 GHz only; the Zero 2 W radio has no 5 GHz band.
  final int channel;

  final String countryCode;
  final bool hidden;

  static const int minPassphrase = 8;
  static const int maxPassphrase = 63;

  bool get isOpen => passphrase == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'ssid': ssid,
    // Never send the passphrase to the browser; say whether there is one.
    'protected': !isOpen,
    'channel': channel,
    'countryCode': countryCode,
    'hidden': hidden,
  };

  AccessPoint copyWith({
    String? ssid,
    String? passphrase,
    bool makeOpen = false,
    int? channel,
    String? countryCode,
    bool? hidden,
  }) => AccessPoint(
    ssid: ssid ?? this.ssid,
    passphrase: makeOpen ? null : (passphrase ?? this.passphrase),
    channel: channel ?? this.channel,
    countryCode: countryCode ?? this.countryCode,
    hidden: hidden ?? this.hidden,
  );

  /// The reason this configuration cannot work, or null if it can.
  ///
  /// Checked before anything is written: hostapd refuses to start on a bad
  /// config, and on a box whose only route in is its own access point, that is
  /// a brick.
  String? get problem {
    final bytes = ssid.trim().isEmpty ? 0 : _utf8Length(ssid);
    if (bytes == 0) return 'Ime omrežja ne sme biti prazno.';
    if (bytes > 32) return 'Ime omrežja je predolgo (največ 32 znakov).';

    final secret = passphrase;
    if (secret != null) {
      final length = _utf8Length(secret);
      if (length < minPassphrase || length > maxPassphrase) {
        return 'Geslo omrežja mora imeti med $minPassphrase in '
            '$maxPassphrase znakov.';
      }
    }
    if (channel < 1 || channel > 13) {
      return 'Kanal mora biti med 1 in 13.';
    }
    if (countryCode.length != 2) {
      return 'Oznaka države mora imeti dve črki.';
    }
    return null;
  }

  static int _utf8Length(String value) => value.runes.fold(0, (sum, rune) {
    if (rune <= 0x7F) return sum + 1;
    if (rune <= 0x7FF) return sum + 2;
    if (rune <= 0xFFFF) return sum + 3;
    return sum + 4;
  });
}

/// Reads and rewrites `hostapd.conf`.
///
/// The file is the source of truth, not a rendering of some other state: there
/// is no copy of the SSID in `settings.json` to drift out of sync, and a
/// hand-edit over the serial console is as valid as a change made in the
/// browser. Unrecognised directives are preserved, so the radio tuning in the
/// shipped default survives a passphrase change made from a phone.
class AccessPointFile {
  AccessPointFile(this.path);

  /// The appliance image seeds this on the data partition; a desktop run has
  /// no access point at all and leaves it unset.
  factory AccessPointFile.fromEnvironment() {
    const compiled = String.fromEnvironment('PESMARICA_HOSTAPD_CONF');
    final configured = compiled.isNotEmpty
        ? compiled
        : Platform.environment['PESMARICA_HOSTAPD_CONF'];
    return AccessPointFile(
      configured == null || configured.trim().isEmpty
          ? '/var/lib/pesmarica/hostapd.conf'
          : configured.trim(),
    );
  }

  final String path;

  File get file => File(path);

  /// Whether this installation has an access point to configure. False on a
  /// desktop, where the web interface hides the network panel entirely.
  bool get exists => file.existsSync();

  AccessPoint? read() {
    if (!exists) return null;
    final values = _directives(file.readAsStringSync());
    final wpa = values['wpa'];
    return AccessPoint(
      ssid: values['ssid'] ?? 'Pesmarica',
      passphrase: wpa == null ? null : values['wpa_passphrase'],
      channel: int.tryParse(values['channel'] ?? '') ?? 6,
      countryCode: values['country_code'] ?? 'SI',
      hidden: values['ignore_broadcast_ssid'] == '1',
    );
  }

  /// Writes the new configuration, keeping every line the app does not own.
  ///
  /// Refuses an unusable configuration rather than writing it: see
  /// [AccessPoint.problem].
  Future<void> write(AccessPoint access) async {
    final problem = access.problem;
    if (problem != null) throw ArgumentError(problem);

    final rendered = render(
      file.existsSync() ? file.readAsStringSync() : '',
      access,
    );

    // Same reasoning as the songbook: rename into place so a power cut cannot
    // leave a half-written config, which here would mean no access point.
    final temp = File('$path.tmp');
    await temp.writeAsString(rendered, flush: true);
    await temp.rename(path);
  }

  /// The keys this app owns; everything else in the file is passed through.
  static const List<String> _owned = <String>[
    'ssid',
    'channel',
    'country_code',
    'ignore_broadcast_ssid',
    'wpa',
    'wpa_passphrase',
    'wpa_key_mgmt',
    'rsn_pairwise',
    'auth_algs',
  ];

  @visibleForTesting
  static String render(String existing, AccessPoint access) {
    final kept = <String>[];
    for (final line in existing.replaceAll('\r\n', '\n').split('\n')) {
      final key = _keyOf(line);
      if (key != null && _owned.contains(key)) continue;
      kept.add(line);
    }
    // Removing a directive leaves its blank line behind; collapse runs so the
    // file does not grow gaps every time the passphrase changes.
    final tidied = <String>[];
    for (final line in kept) {
      final blank = line.trim().isEmpty;
      if (blank && (tidied.isEmpty || tidied.last.trim().isEmpty)) continue;
      tidied.add(line);
    }
    while (tidied.isNotEmpty && tidied.last.trim().isEmpty) {
      tidied.removeLast();
    }

    final block = <String>[
      'ssid=${access.ssid}',
      'channel=${access.channel}',
      'country_code=${access.countryCode}',
      'ignore_broadcast_ssid=${access.hidden ? 1 : 0}',
      'auth_algs=1',
      if (!access.isOpen) ...<String>[
        'wpa=2',
        'wpa_key_mgmt=WPA-PSK',
        'rsn_pairwise=CCMP',
        'wpa_passphrase=${access.passphrase}',
      ],
    ];

    return '${<String>[...tidied, '', ...block].join('\n')}\n';
  }

  static Map<String, String> _directives(String source) {
    final values = <String, String>{};
    for (final line in source.replaceAll('\r\n', '\n').split('\n')) {
      final key = _keyOf(line);
      if (key == null) continue;
      values[key] = line.substring(line.indexOf('=') + 1).trim();
    }
    return values;
  }

  static String? _keyOf(String line) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#')) return null;
    final at = trimmed.indexOf('=');
    if (at <= 0) return null;
    return trimmed.substring(0, at).trim();
  }

  /// Restarts hostapd so the new network comes up.
  ///
  /// Every connected device drops when this runs — including whoever asked for
  /// it — so callers answer the request first and only then call this.
  Future<bool> restart() async {
    if (!Platform.isLinux) return false;
    try {
      final result = await Process.run('systemctl', <String>['restart', 'hostapd']);
      if (result.exitCode != 0) {
        debugPrint('pesmarica: hostapd restart failed: ${result.stderr}');
      }
      return result.exitCode == 0;
    } on ProcessException catch (e) {
      debugPrint('pesmarica: could not restart hostapd: $e');
      return false;
    }
  }
}
