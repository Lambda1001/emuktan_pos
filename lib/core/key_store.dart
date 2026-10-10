import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dpapi.dart';

/// Holds the 256-bit database key.
///
/// The key is random, never typed by a person. It is stored on disk wrapped by
/// Windows DPAPI, so the file is useless if copied to another PC or account.
/// Because of that, the owner MUST keep the printed recovery key: without it a
/// reinstall or a dead PC makes both the database and its backups unreadable.
abstract class KeyStore {
  /// Returns the key, creating and persisting a new one on first run.
  /// [created] is true only when a brand-new key was just generated, which is
  /// the moment to show the recovery key to the owner.
  Future<({Uint8List key, bool created})> loadOrCreate();

  /// Re-installs a key recovered from the owner's printed copy.
  Future<void> restore(Uint8List key);
}

class DpapiKeyStore implements KeyStore {
  DpapiKeyStore(this.file);
  final File file;

  @override
  Future<({Uint8List key, bool created})> loadOrCreate() async {
    if (file.existsSync()) {
      final key = Dpapi.unprotect(await file.readAsBytes());
      return (key: key, created: false);
    }
    final rng = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    await restore(key);
    return (key: key, created: true);
  }

  @override
  Future<void> restore(Uint8List key) async {
    await file.parent.create(recursive: true);
    // Write to a temp file then rename, so a crash cannot leave a torn key file.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(Dpapi.protect(key), flush: true);
    await tmp.rename(file.path);
  }
}

/// Human-friendly form of the key for the owner to print and keep safe.
/// 64 hex characters in 8 groups of 8, e.g. "a1b2c3d4-...".
String formatRecoveryKey(Uint8List key) {
  final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [for (var i = 0; i < 64; i += 8) hex.substring(i, i + 8)].join('-');
}

/// Inverse of [formatRecoveryKey]. Tolerates spaces, dashes and case.
Uint8List parseRecoveryKey(String text) {
  final hex = text.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    throw const FormatException('A recovery key is 64 hexadecimal characters.');
  }
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
