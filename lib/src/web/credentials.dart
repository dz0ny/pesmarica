import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The web interface's single password.
///
/// There is no user name and no session store. The password is salted and
/// hashed once, the hash is what the browser holds in a cookie, and checking a
/// request is a constant-time comparison against that hash — so a restart, or
/// a Pi that has been unplugged for a month, does not log anybody out.
///
/// The cost of that simplicity: anyone holding the cookie is in until the
/// password changes. On the closed AV network this runs on, that is the right
/// trade; over the open internet it would not be, and neither would serving
/// any of this over plain HTTP.
class Credentials {
  const Credentials({required this.hash, required this.salt});

  /// Hex sha256 of salt + password. Doubles as the cookie value.
  final String hash;

  final String salt;

  static const String cookieName = 'pesmarica';

  static String hashPassword(String password, String salt) =>
      sha256.convert(utf8.encode('$salt:$password')).toString();

  static String newSalt([Random? random]) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => source.nextInt(256));
    return base64Url.encode(bytes);
  }

  static Credentials forPassword(String password, {String? salt}) {
    final effective = salt ?? newSalt();
    return Credentials(
      hash: hashPassword(password, effective),
      salt: effective,
    );
  }

  bool accepts(String password) => matches(hashPassword(password, salt));

  /// Compares a presented cookie against the stored hash without leaking how
  /// much of it matched through timing.
  bool matches(String? presented) {
    if (presented == null || presented.length != hash.length) return false;
    var difference = 0;
    for (var i = 0; i < hash.length; i++) {
      difference |= hash.codeUnitAt(i) ^ presented.codeUnitAt(i);
    }
    return difference == 0;
  }
}
