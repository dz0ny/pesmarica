import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What `pesmarica-update-check` on the box left behind, read from
/// `/run/pesmarica/update.json`.
///
/// The app does not check for updates and does not download them. That is a
/// timer in the image (`nix/scripts/update_check.sh`), because the download is
/// half a gigabyte onto an SD card and must survive the app being restarted,
/// and because the app is inside the very system being replaced. All that is
/// left here is reading one small file and, when the operator asks, starting
/// one unit -- the same shape as the network settings, which the app also only
/// writes and hands to systemd.
///
/// Off the box the file does not exist, [read] comes back null, and the
/// management page shows nothing about updates at all.
class UpdateStatus {
  const UpdateStatus({
    required this.state,
    this.running,
    this.available,
    this.slot,
    this.error,
    this.checked,
  });

  /// What the last run of the checker concluded:
  ///
  /// * `off` -- nobody has turned auto-update on
  /// * `offline` -- the box is its own access point, or has no route out
  /// * `current` -- the running version is the newest release
  /// * `downloading` -- a release is being written into the free slot
  /// * `ready` -- it is written, whole, and waiting to be installed
  /// * `failed` -- see [error]
  ///
  /// Kept as the string the shell wrote rather than an enum: the two sides are
  /// a shell script and a web page, and a state this version has never heard of
  /// should reach the page rather than be swallowed here.
  final String state;

  /// The version in the slot the box booted from, or null when that slot
  /// carries no marker -- an older image, or a slot written by hand.
  final String? running;

  /// The newest release GitHub knows about.
  final String? available;

  /// Which slot the staged system is in: `a` or `b`.
  final String? slot;

  /// Why the last attempt failed, in Slovenian, for the operator to read.
  final String? error;

  /// When the check ran, ISO 8601 in UTC.
  final String? checked;

  bool get isReady => state == 'ready';

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state,
    if (running != null) 'running': running,
    if (available != null) 'available': available,
    if (slot != null) 'slot': slot,
    if (error != null) 'error': error,
    if (checked != null) 'checked': checked,
  };

  /// The file as the shell writes it, or null for anything else -- a partial
  /// write, a file that is not JSON, an object with no state in it. The page
  /// draws nothing rather than guessing.
  static UpdateStatus? parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final state = _text(decoded['state']);
    if (state == null) return null;
    return UpdateStatus(
      state: state,
      running: _text(decoded['running']),
      available: _text(decoded['available']),
      slot: _text(decoded['slot']),
      error: _text(decoded['error']),
      checked: _text(decoded['checked']),
    );
  }

  static String? _text(Object? value) {
    final text = value is String ? value.trim() : null;
    return (text == null || text.isEmpty) ? null : text;
  }
}

/// Where that file lives. The unit passes `PESMARICA_RUN`; a laptop has no such
/// directory, and everything below then reads as "no updater here".
class UpdateStatusFile {
  UpdateStatusFile(this.file);

  factory UpdateStatusFile.fromEnvironment() {
    final configured = Platform.environment['PESMARICA_RUN'];
    final dir = (configured == null || configured.trim().isEmpty)
        ? '/run/pesmarica'
        : configured.trim();
    return UpdateStatusFile(File(p.join(p.normalize(p.absolute(dir)), 'update.json')));
  }

  final File file;

  UpdateStatus? read() {
    try {
      if (!file.existsSync()) return null;
      return UpdateStatus.parse(file.readAsStringSync());
    } on Object catch (_) {
      // A half-written file is the normal way to lose this race, and the next
      // poll is four seconds away.
      return null;
    }
  }
}
