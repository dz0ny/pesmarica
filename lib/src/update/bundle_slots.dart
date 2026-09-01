import 'dart:io';

import 'package:path/path.dart' as p;

/// Two app bundles side by side, one of them live -- the scheme a browser uses
/// to update itself without ever leaving a half-written copy behind.
///
/// A deploy never touches the bundle that is running. It fills the *other* slot,
/// marks it complete, and flips a one-byte pointer; the flip is the only moment
/// anything changes, and it is a rename. Lose the mains halfway through an
/// upload and the box comes back on the bundle it was already running.
///
/// The layout under the songbook directory is deliberately four plain files, so
/// that the launch script in `nix/modules/pesmarica.nix` can read the same state
/// in shell without a parser:
///
/// ```
/// bundles/active     "a" or "b" -- the slot the launcher runs
/// bundles/trial      how many times the active slot has been started
///                    without ever reporting success; absent once it has
/// bundles/a/         a bundle: app.so, icudtl.dat, libflutter_engine.so
/// bundles/a/.complete   written last, so a torn upload is not mistaken for one
/// bundles/a/.version    what to call it in the web interface
/// ```
///
/// Nothing here is authoritative about *booting*: the launcher picks the slot
/// and counts the attempts, because it is the only thing that still runs when
/// the bundle is too broken to start. This class owns the other half -- staging
/// a new bundle, flipping the pointer, and clearing the trial once the app it
/// installed has actually come up.
class BundleSlots {
  BundleSlots(this.root);

  /// The songbook directory; the slots sit beside the pages.
  final Directory root;

  static const List<String> names = <String>['a', 'b'];

  /// How many failed starts the launcher allows before it reverts. Kept here
  /// because the number belongs with the format it is written in, even though
  /// the launcher is what counts them.
  static const int trialAttempts = 3;

  Directory get dir => Directory(p.join(root.path, 'bundles'));

  File get _activeFile => File(p.join(dir.path, 'active'));
  File get _trialFile => File(p.join(dir.path, 'trial'));

  /// The slot the launcher will run. Defaults to `a`, which is also what a card
  /// that has never been deployed to reads as.
  String get active {
    try {
      final value = _activeFile.readAsStringSync().trim();
      if (names.contains(value)) return value;
    } on Object catch (_) {
      // An unreadable pointer is the same as no pointer: run slot a.
    }
    return names.first;
  }

  /// The slot a deploy may overwrite, because nothing is running out of it.
  String get inactive => active == names.first ? names.last : names.first;

  Directory slotDir(String slot) => Directory(p.join(dir.path, slot));

  File _completeFile(String slot) =>
      File(p.join(slotDir(slot).path, '.complete'));
  File _versionFile(String slot) =>
      File(p.join(slotDir(slot).path, '.version'));

  /// The three files flutter-pi will not start without. A slot missing any of
  /// them is not a bundle, whatever else is in the directory.
  static const List<String> required = <String>[
    'app.so',
    'icudtl.dat',
    'libflutter_engine.so',
  ];

  /// Whether [slot] holds a bundle that finished being written.
  ///
  /// The same rule the launcher applies -- keep the two in step.
  bool isComplete(String slot) {
    if (!_completeFile(slot).existsSync()) return false;
    return required.every(
      (name) => File(p.join(slotDir(slot).path, name)).existsSync(),
    );
  }

  /// What the web interface calls the bundle in [slot].
  String? versionOf(String slot) {
    try {
      final value = _versionFile(slot).readAsStringSync().trim();
      return value.isEmpty ? null : value;
    } on Object catch (_) {
      return null;
    }
  }

  /// Whether the active slot is still proving itself. True between a deploy and
  /// the first successful start of the bundle it installed.
  bool get onTrial => _trialFile.existsSync();

  /// Wipes the inactive slot and hands back the directory to fill.
  ///
  /// Wiping rather than syncing into place: a bundle is a closure of files that
  /// have to match each other, and leftovers from two versions ago are exactly
  /// the kind of thing that works until it doesn't.
  Future<Directory> stage() async {
    final slot = inactive;
    final target = slotDir(slot);
    if (target.existsSync()) await target.delete(recursive: true);
    await target.create(recursive: true);
    return target;
  }

  /// Marks [slot] as a complete bundle. Call once everything is written: the
  /// `.complete` file is what tells the launcher the upload was not cut short.
  Future<void> finish(String slot, {String? version}) async {
    for (final name in required) {
      if (!File(p.join(slotDir(slot).path, name)).existsSync()) {
        throw ArgumentError('bundle slot $slot has no $name');
      }
    }
    if (version != null && version.trim().isNotEmpty) {
      await _versionFile(slot).writeAsString('${version.trim()}\n', flush: true);
    }
    await _completeFile(slot).writeAsString('ok\n', flush: true);
  }

  /// Points the launcher at [slot] and puts it on trial.
  ///
  /// The pointer is written through a temporary file and renamed, for the same
  /// reason the songbook's pages are: a truncated pointer read during the next
  /// boot would send the box to a slot nobody chose.
  Future<void> commit(String slot) async {
    if (!names.contains(slot)) throw ArgumentError('no bundle slot $slot');
    if (!isComplete(slot)) throw StateError('bundle slot $slot is incomplete');

    // Arm the trial before the flip. The other order has a window in which the
    // new bundle is live with no attempts left to spend on it.
    await _trialFile.writeAsString('0\n', flush: true);

    final temp = File('${_activeFile.path}.tmp');
    await temp.writeAsString('$slot\n', flush: true);
    await temp.rename(_activeFile.path);
  }

  /// Records that the bundle now running came up, so the launcher stops
  /// counting attempts against it and will not revert on the next reboot.
  ///
  /// "Came up" means the app got far enough to serve the songbook. A bundle
  /// that crashes before this never clears the trial, which is the whole
  /// mechanism: the launcher reverts on its own after
  /// [trialAttempts] starts that never got here.
  Future<void> markCurrentGood() async {
    if (!onTrial) return;
    try {
      await _trialFile.delete();
    } on Object catch (_) {
      // Nothing to do about it here, and nothing worth failing startup over:
      // the worst case is a needless revert to a bundle that also works.
    }
  }

  /// What the web interface shows about the two slots.
  Map<String, Object?> describe() => <String, Object?>{
    'active': active,
    'onTrial': onTrial,
    'slots': <Map<String, Object?>>[
      for (final slot in names)
        <String, Object?>{
          'slot': slot,
          'ready': isComplete(slot),
          'version': versionOf(slot),
        },
    ],
  };
}
