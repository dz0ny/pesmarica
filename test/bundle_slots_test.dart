import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/update/bundle_installer.dart';
import 'package:pesmarica/src/update/bundle_slots.dart';

void main() {
  late Directory root;
  late BundleSlots slots;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pesmarica-slots');
    slots = BundleSlots(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// Puts the three files flutter-pi needs into a slot, without marking it
  /// complete -- what an interrupted deploy leaves behind.
  void fill(String slot, {String? extra}) {
    final dir = Directory(p.join(root.path, 'bundles', slot))
      ..createSync(recursive: true);
    for (final name in BundleSlots.required) {
      File(p.join(dir.path, name)).writeAsStringSync(extra ?? name);
    }
  }

  group('slots', () {
    test('a card nobody has deployed to reads as slot a, with nothing in it',
        () {
      expect(slots.active, 'a');
      expect(slots.inactive, 'b');
      expect(slots.isComplete('a'), isFalse);
      expect(slots.onTrial, isFalse);
    });

    test('staging never touches the slot that is running', () async {
      fill('a');
      await slots.finish('a', version: '1');
      await slots.commit('a');

      final staged = await slots.stage();
      expect(p.basename(staged.path), 'b');
      expect(slots.active, 'a', reason: 'still running the old one');
      expect(slots.isComplete('a'), isTrue);
    });

    test('a bundle is not complete until the marker is written', () async {
      fill('a');
      expect(slots.isComplete('a'), isFalse, reason: 'no .complete');
      await slots.finish('a');
      expect(slots.isComplete('a'), isTrue);
    });

    test('a slot missing one of the three files is not a bundle', () async {
      fill('a');
      File(p.join(root.path, 'bundles', 'a', 'app.so')).deleteSync();
      expect(() => slots.finish('a'), throwsArgumentError);
      expect(slots.isComplete('a'), isFalse);
    });

    test('an incomplete slot can never be committed to', () async {
      fill('b');
      expect(() => slots.commit('b'), throwsStateError);
      expect(slots.active, 'a');
    });

    test('committing points the launcher at the new slot and starts a trial',
        () async {
      fill('b');
      await slots.finish('b', version: 'v2');
      await slots.commit('b');

      expect(slots.active, 'b');
      expect(slots.inactive, 'a');
      expect(slots.onTrial, isTrue);
      expect(slots.versionOf('b'), 'v2');
    });

    test('the trial ends when the installed bundle reports a frame', () async {
      fill('a');
      await slots.finish('a');
      await slots.commit('a');
      expect(slots.onTrial, isTrue);

      await slots.markCurrentGood();
      expect(slots.onTrial, isFalse);

      // Idempotent: every boot calls it, only the first one has work to do.
      await slots.markCurrentGood();
      expect(slots.onTrial, isFalse);
    });

    test('deploys alternate between the two slots', () async {
      fill('a');
      await slots.finish('a');
      await slots.commit('a');
      await slots.markCurrentGood();

      expect(p.basename((await slots.stage()).path), 'b');
      fill('b');
      await slots.finish('b');
      await slots.commit('b');
      await slots.markCurrentGood();

      expect(slots.active, 'b');
      expect(p.basename((await slots.stage()).path), 'a');
    });

    test('a garbled pointer runs slot a rather than nothing', () async {
      Directory(p.join(root.path, 'bundles')).createSync(recursive: true);
      File(p.join(root.path, 'bundles', 'active')).writeAsStringSync('nonsense');
      expect(slots.active, 'a');
    });

    test('staging wipes what was in the slot before', () async {
      fill('b');
      final stale = File(p.join(root.path, 'bundles', 'b', 'stale.so'))
        ..writeAsStringSync('from two versions ago');
      await slots.stage();
      expect(stale.existsSync(), isFalse);
    });
  });

  group('installer', () {
    /// A bundle as a tarball, the way a build hands one over.
    Future<File> archive({String prefix = ''}) async {
      final staging = Directory(p.join(root.path, 'src'))
        ..createSync(recursive: true);
      final inner = prefix.isEmpty
          ? staging
          : (Directory(p.join(staging.path, prefix))..createSync());
      for (final name in BundleSlots.required) {
        File(p.join(inner.path, name)).writeAsStringSync('$name payload');
      }
      final file = File(p.join(root.path, 'bundle.tar'));
      final result = await Process.run('tar', <String>[
        '-cf',
        file.path,
        '-C',
        staging.path,
        ...Directory(staging.path).listSync().map((e) => p.basename(e.path)),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return file;
    }

    test('installs an uploaded bundle into the free slot and flips to it',
        () async {
      final tar = await archive();
      final slot = await BundleInstaller(slots).install(
        tar.openRead(),
        version: 'v9',
      );

      // Slot b: the pointer on an undeployed card already names a, and the rule
      // is that the slot it names is never written to.
      expect(slot, 'b');
      expect(slots.active, 'b');
      expect(slots.onTrial, isTrue, reason: 'it has not drawn a frame yet');
      expect(slots.versionOf('b'), 'v9');
      expect(
        File(p.join(root.path, 'bundles', 'b', 'app.so')).readAsStringSync(),
        'app.so payload',
      );
    });

    test('unwraps an archive of the bundle directory itself', () async {
      final tar = await archive(prefix: 'pi3');
      final slot = await BundleInstaller(slots).install(tar.openRead());
      expect(slots.isComplete(slot), isTrue);
      expect(
        File(p.join(root.path, 'bundles', slot, 'app.so')).existsSync(),
        isTrue,
      );
    });

    test('leaves the running bundle alone when the upload is not a bundle',
        () async {
      fill('a');
      await slots.finish('a', version: 'good');
      await slots.commit('a');
      await slots.markCurrentGood();

      File(p.join(root.path, 'stray.txt')).writeAsStringSync('hello');
      final notABundle = File(p.join(root.path, 'notes.tar'));
      await Process.run('tar', <String>[
        '-cf',
        notABundle.path,
        '-C',
        root.path,
        'stray.txt',
      ]);

      await expectLater(
        BundleInstaller(slots).install(notABundle.openRead()),
        throwsA(isA<BundleRejected>()),
      );
      expect(slots.active, 'a');
      expect(slots.versionOf('a'), 'good');
      expect(slots.onTrial, isFalse);
    });

    test('refuses something that is not an archive at all', () async {
      final junk = File(p.join(root.path, 'junk.tar'))
        ..writeAsStringSync('this is not a tarball' * 100);
      await expectLater(
        BundleInstaller(slots).install(junk.openRead()),
        throwsA(isA<BundleRejected>()),
      );
      expect(slots.active, 'a');
      expect(slots.isComplete('a'), isFalse);
    });

    test('refuses an empty upload', () async {
      await expectLater(
        BundleInstaller(slots).install(const Stream<List<int>>.empty()),
        throwsA(isA<BundleRejected>()),
      );
    });

    test('never writes outside the slot, whatever the archive claims', () async {
      // The box executes what it unpacks, so an archive reaching up out of the
      // slot is the one thing that must not work. GNU tar strips `..` while
      // *writing* the archive and bsdtar keeps it, so this asserts the outcome
      // rather than the refusal: either it is rejected, or nothing escaped.
      final inner = Directory(p.join(root.path, 'src', 'inner'))
        ..createSync(recursive: true);
      for (final name in BundleSlots.required) {
        File(p.join(inner.path, name)).writeAsStringSync(name);
      }
      File(p.join(root.path, 'src', 'evil.txt')).writeAsStringSync('pwned');

      final tar = File(p.join(root.path, 'escape.tar'));
      await Process.run('tar', <String>[
        '-cf',
        tar.path,
        '-C',
        inner.path,
        ...BundleSlots.required,
        '../evil.txt',
      ]);

      try {
        await BundleInstaller(slots).install(tar.openRead());
      } on BundleRejected {
        // The intended path.
      }
      expect(
        File(p.join(root.path, 'bundles', 'evil.txt')).existsSync(),
        isFalse,
      );
      expect(File(p.join(root.path, 'evil.txt')).existsSync(), isFalse);
    });

    test('cleans up the uploaded archive either way', () async {
      final tar = await archive();
      await BundleInstaller(slots).install(tar.openRead());
      expect(
        File(p.join(root.path, 'bundles', 'upload.tar.tmp')).existsSync(),
        isFalse,
      );
    });
  });
}
