import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 for staff PINs. Only the salted hash is stored.
/// The whole database is also encrypted, so this is a second layer: a PIN
/// should not be recoverable even by someone who holds the open database.
class PinHasher {
  const PinHasher({this.iterations = 60000});

  final int iterations;

  String newSalt([Random? random]) {
    final r = random ?? Random.secure();
    return base64Encode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  String hash(String pin, String salt) {
    final h = Hmac(sha256, utf8.encode(pin));
    // Single 32-byte block (dkLen == hLen), so PBKDF2 needs only block 1.
    final saltBytes = <int>[...base64Decode(salt), 0, 0, 0, 1];
    var u = Uint8List.fromList(h.convert(saltBytes).bytes);
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(h.convert(u).bytes);
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    return base64Encode(t);
  }

  bool verify(String pin, String salt, String expectedHash) {
    final actual = hash(pin, salt);
    // Constant-time comparison.
    if (actual.length != expectedHash.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual.codeUnitAt(i) ^ expectedHash.codeUnitAt(i);
    }
    return diff == 0;
  }
}
