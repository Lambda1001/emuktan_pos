import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Minimal Windows DPAPI wrapper. Data protected here can only be decrypted by
/// the same Windows user account on the same machine.
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectC = Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _ProtectD = int Function(Pointer<_DataBlob>, Pointer<Utf16>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _UnprotectC = Int32 Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _UnprotectD = int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _LocalFreeC = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeD = Pointer<Void> Function(Pointer<Void>);

class DpapiException implements Exception {
  DpapiException(this.message);
  final String message;
  @override
  String toString() => 'DpapiException: $message';
}

class Dpapi {
  Dpapi._();

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect =
      _crypt32.lookupFunction<_ProtectC, _ProtectD>('CryptProtectData');
  static final _unprotect =
      _crypt32.lookupFunction<_UnprotectC, _UnprotectD>('CryptUnprotectData');
  static final _localFree =
      _kernel32.lookupFunction<_LocalFreeC, _LocalFreeD>('LocalFree');

  // CRYPTPROTECT_UI_FORBIDDEN: never show a prompt.
  static const _uiForbidden = 0x1;

  static Uint8List protect(Uint8List data) =>
      _run(data, (i, o) => _protect(i, nullptr, nullptr, nullptr, nullptr, _uiForbidden, o));

  static Uint8List unprotect(Uint8List data) =>
      _run(data, (i, o) => _unprotect(i, nullptr, nullptr, nullptr, nullptr, _uiForbidden, o));

  static Uint8List _run(Uint8List data,
      int Function(Pointer<_DataBlob>, Pointer<_DataBlob>) call) {
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    final buf = calloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      inBlob.ref
        ..cbData = data.length
        ..pbData = buf;
      if (call(inBlob, outBlob) == 0) {
        throw DpapiException('Windows DPAPI call failed');
      }
      final result = Uint8List.fromList(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      _localFree(outBlob.ref.pbData.cast());
      return result;
    } finally {
      calloc.free(buf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}
