import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pesmarica/src/data/songbook.dart';
import 'package:pesmarica/src/model/settings.dart';
import 'package:pesmarica/src/web/credentials.dart';

void main() {
  group('Credentials', () {
    test('accepts the password and nothing else', () {
      final credentials = Credentials.forPassword('čebelica');
      expect(credentials.accepts('čebelica'), isTrue);
      expect(credentials.accepts('cebelica'), isFalse);
      expect(credentials.accepts(''), isFalse);
    });

    test('never stores the password itself', () {
      final credentials = Credentials.forPassword('geslo123');
      expect(credentials.hash, isNot(contains('geslo')));
      expect(credentials.salt, isNot(contains('geslo')));
      expect(credentials.hash.length, 64);
    });

    test('the same password gets a different hash on every screen', () {
      expect(
        Credentials.forPassword('geslo').hash,
        isNot(Credentials.forPassword('geslo').hash),
        reason: 'a fresh salt each time',
      );
    });

    test('the cookie value is the hash, and only the hash', () {
      final credentials = Credentials.forPassword('geslo');
      expect(credentials.matches(credentials.hash), isTrue);
      expect(credentials.matches(null), isFalse);
      expect(credentials.matches(''), isFalse);
      expect(credentials.matches('${credentials.hash}x'), isFalse);
      expect(credentials.matches('0' * 64), isFalse);
    });
  });

  group('settings.json', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('pesmarica-auth'));
    tearDown(() => root.deleteSync(recursive: true));

    Future<Songbook> open() async {
      final songbook = Songbook(root);
      await songbook.start();
      addTearDown(songbook.dispose);
      return songbook;
    }

    test('is unprotected until a password is set', () async {
      final songbook = await open();
      expect(songbook.settings.isProtected, isFalse);
    });

    test('a typed-in password is hashed and wiped from the file', () async {
      File(p.join(root.path, 'settings.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{'password': 'čeb€lica'}),
      );
      final songbook = await open();

      expect(songbook.settings.isProtected, isTrue);
      expect(songbook.settings.password, isNull);

      final onDisk =
          jsonDecode(File(p.join(root.path, 'settings.json')).readAsStringSync())
              as Map<String, Object?>;
      expect(onDisk.containsKey('password'), isFalse);
      expect(onDisk['passwordHash'], isNotNull);
      expect(onDisk['passwordSalt'], isNotNull);
      expect(File(p.join(root.path, 'settings.json')).readAsStringSync(),
          isNot(contains('čeb€lica')));

      final credentials = Credentials(
        hash: songbook.settings.passwordHash!,
        salt: songbook.settings.passwordSalt!,
      );
      expect(credentials.accepts('čeb€lica'), isTrue);
    });

    test('the login survives a restart, so nobody is logged out by a reboot',
        () async {
      File(p.join(root.path, 'settings.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{'password': 'geslo'}),
      );
      final first = await open();
      final cookie = first.settings.passwordHash;

      final second = Songbook(root);
      await second.start();
      addTearDown(second.dispose);
      expect(second.settings.passwordHash, cookie);
      expect(second.settings.passwordSalt, first.settings.passwordSalt);
    });

    test('other settings round-trip alongside the hash', () async {
      final songbook = await open();
      await songbook.saveSettings(
        songbook.settings.copyWith(theme: PageTheme.light, baseScale: 1.25),
      );
      final reopened = Songbook(root);
      await reopened.start();
      addTearDown(reopened.dispose);
      expect(reopened.settings.theme, PageTheme.light);
      expect(reopened.settings.baseScale, 1.25);
    });
  });
}
