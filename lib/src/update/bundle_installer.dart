import 'dart:io';

import 'package:path/path.dart' as p;

import 'bundle_slots.dart';

/// Refusal to install an uploaded bundle. [message] is shown to the operator,
/// so it is Slovenian like the rest of the web interface.
class BundleRejected implements Exception {
  const BundleRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Unpacks an uploaded `.tar` (optionally gzipped) into the slot that is not
/// running, and points the launcher at it.
///
/// The archive is listed before it is extracted. Nothing here trusts the file:
/// it arrived over the air from whoever is on the access point, and the box
/// then *executes* it, which makes this the one endpoint where a sloppy check
/// is the difference between an update mechanism and a way in.
class BundleInstaller {
  BundleInstaller(this.slots, {this.tar = 'tar'});

  final BundleSlots slots;

  /// Overridable so a test can point at a stub instead of the real thing.
  final String tar;

  /// A bundle is around 30 MB. The cap is not a security boundary -- the point
  /// is to fail before a runaway upload has filled the card the songbook is on.
  static const int maxBytes = 128 * 1024 * 1024;

  /// Installs [body] and returns the slot it went into.
  ///
  /// The caller restarts the unit afterwards; until it does, the box keeps
  /// running the old bundle, which is exactly what makes this safe to call.
  Future<String> install(Stream<List<int>> body, {String? version}) async {
    await slots.dir.create(recursive: true);
    final archive = File(p.join(slots.dir.path, 'upload.tar.tmp'));
    try {
      await _receive(body, archive);
      final strip = _inspect(archive);

      final target = await slots.stage();
      final slot = p.basename(target.path);
      await _extract(archive, target, strip: strip);

      try {
        await slots.finish(slot, version: version);
      } on ArgumentError {
        throw const BundleRejected(
          'Arhiv ni programski paket: manjkajo datoteke aplikacije.',
        );
      }
      await slots.commit(slot);
      return slot;
    } finally {
      if (archive.existsSync()) {
        try {
          await archive.delete();
        } on Object catch (_) {
          // A leftover temp file costs disk, not correctness; the next upload
          // overwrites it.
        }
      }
    }
  }

  Future<void> _receive(Stream<List<int>> body, File archive) async {
    final sink = archive.openWrite();
    var size = 0;
    try {
      await for (final chunk in body) {
        size += chunk.length;
        if (size > maxBytes) {
          throw const BundleRejected('Datoteka je prevelika.');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (size == 0) throw const BundleRejected('Prazna datoteka.');
  }

  /// Reads the table of contents and decides how many leading path components
  /// to drop. Throws unless the archive is a bundle and nothing in it points
  /// outside the directory it will be unpacked into.
  int _inspect(File archive) {
    final listing = Process.runSync(tar, <String>['-tf', archive.path]);
    if (listing.exitCode != 0) {
      throw const BundleRejected('Datoteke ni bilo mogoče prebrati kot arhiv.');
    }

    final members = '${listing.stdout}'
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (members.isEmpty) throw const BundleRejected('Arhiv je prazen.');

    for (final member in members) {
      // tar strips a leading slash on extraction and skips `..` members, but
      // "the tool would probably refuse" is not a check. These are cheap.
      if (member.startsWith('/') || member.contains('\\')) {
        throw const BundleRejected('Arhiv vsebuje nedovoljene poti.');
      }
      if (p.posix.split(member).contains('..')) {
        throw const BundleRejected('Arhiv vsebuje nedovoljene poti.');
      }
    }

    // Tarring the bundle directory itself rather than its contents is the
    // obvious mistake to make, and it is unambiguous to undo: one shared top
    // level, with the app inside it.
    if (_holdsBundle(members, strip: 0)) return 0;
    if (_holdsBundle(members, strip: 1)) {
      final tops = members.map((m) => p.posix.split(m).first).toSet();
      if (tops.length == 1) return 1;
    }
    throw const BundleRejected(
      'Arhiv ni programski paket: manjka app.so.',
    );
  }

  static bool _holdsBundle(List<String> members, {required int strip}) {
    final names = members
        .map((m) => p.posix.split(m).skip(strip).join('/'))
        .toSet();
    return BundleSlots.required.every(names.contains);
  }

  Future<void> _extract(File archive, Directory target, {int strip = 0}) async {
    final result = await Process.run(tar, <String>[
      '-xf',
      archive.path,
      '-C',
      target.path,
      // The songbook partition is exFAT and has no owners to restore anyway;
      // asking for them only produces warnings and a non-zero exit.
      '--no-same-owner',
      if (strip > 0) '--strip-components=$strip',
    ]);
    if (result.exitCode != 0) {
      throw BundleRejected('Arhiva ni bilo mogoče razpakirati: ${result.stderr}');
    }
  }
}
