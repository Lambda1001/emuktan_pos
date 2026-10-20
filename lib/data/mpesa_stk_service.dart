import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'sync_service.dart';

/// Where an M-Pesa prompt has got to.
enum StkState {
  /// Sent; the customer has not answered yet.
  pending,

  /// Paid. [StkStatus.receipt] is the real M-Pesa code.
  success,

  /// KCB or M-Pesa refused it (wrong number, insufficient funds, ...).
  failed,

  /// The customer dismissed the prompt.
  cancelled,

  /// No answer within the wait. A late payment is still recorded by the server.
  timeout,

  /// Money may have moved but the result did not add up (amount, code).
  /// Never treated as paid: check the M-Pesa statement.
  review,
}

class StkStatus {
  const StkStatus({
    required this.requestId,
    required this.state,
    this.receipt,
    this.message,
    this.phone,
  });
  final String requestId;
  final StkState state;

  /// Set only when [state] is [StkState.success].
  final String? receipt;
  final String? message, phone;

  bool get isFinal => state != StkState.pending && state != StkState.timeout;
}

/// A problem worded for the screen.
class StkException implements Exception {
  StkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Asks the dashboard server to send an M-Pesa prompt to a customer's phone and
/// reports the answer. The server holds the KCB credentials and receives KCB's
/// callback; this PC only asks and polls, so no payment secret lives here.
/// Cash and typing the code by hand keep working with no connection at all.
class MpesaStkService {
  MpesaStkService(this._sync, {SyncTransport? transport, Random? random})
    : _transport = transport ?? HttpSyncTransport(),
      _random = random ?? Random.secure();

  final SyncService _sync;
  final SyncTransport _transport;
  final Random _random;

  Future<bool> available() => _sync.mpesaPromptsAvailable();

  /// A fresh id for one attempt. Re-sending with the same id never sends a
  /// second prompt, so it is safe to retry after a dropped connection.
  String newRequestId() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    String h(int from, int to) => b
        .sublist(from, to)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
  }

  /// M-Pesa prompts take whole shillings only.
  static bool canPrompt(int amountCents) =>
      amountCents >= 100 && amountCents % 100 == 0;

  Future<StkStatus> start({
    required String requestId,
    required int amountCents,
    required String phone,
    String? reference,
  }) async {
    final cfg = await _config();
    final r = await _call(
      () => _transport.post(cfg.base.resolve('/api/mpesa/stk'), cfg.key, {
        'request_id': requestId,
        'amount_cents': amountCents,
        'phone': phone.trim(),
        'reference': ?reference,
      }),
    );
    return _parse(r, requestId);
  }

  Future<StkStatus> check(String requestId) async {
    final cfg = await _config();
    final r = await _call(
      () => _transport.get(
        cfg.base.resolve('/api/mpesa/stk/$requestId'),
        cfg.key,
      ),
    );
    return _parse(r, requestId);
  }

  Future<({Uri base, String key})> _config() async {
    final c = await _sync.config();
    if (c == null) {
      throw StkException('The dashboard is not set up in Settings.');
    }
    return (base: SyncService.parseBaseUrl(c.url), key: c.key);
  }

  Future<SyncReply> _call(Future<SyncReply> Function() send) async {
    try {
      return await send();
    } on SocketException {
      throw StkException('No connection to the dashboard.');
    } on TimeoutException {
      throw StkException('The dashboard did not answer in time.');
    } on HandshakeException {
      throw StkException('The secure connection failed.');
    }
  }

  StkStatus _parse(SyncReply r, String requestId) {
    final j = r.json;
    if (r.status == 200 || r.status == 202) {
      final state = switch (j?['status']) {
        'pending' => StkState.pending,
        'success' => StkState.success,
        'cancelled' => StkState.cancelled,
        'timeout' => StkState.timeout,
        'review' => StkState.review,
        'failed' => StkState.failed,
        _ => throw StkException('The dashboard sent an answer we do not know.'),
      };
      final receipt = j?['receipt'];
      // A success without a usable code is not a success.
      if (state == StkState.success &&
          (receipt is! String || receipt.isEmpty)) {
        throw StkException('The dashboard confirmed payment without a code.');
      }
      return StkStatus(
        requestId: requestId,
        state: state,
        receipt: state == StkState.success ? receipt as String : null,
        message: j?['message'] as String?,
        phone: j?['phone'] as String?,
      );
    }
    throw StkException(switch (r.status) {
      401 => 'The dashboard did not accept the key.',
      501 => 'M-Pesa prompts are not switched on at the dashboard.',
      404 => 'The dashboard does not know this payment request.',
      409 ||
      422 ||
      429 => (j?['error'] as String?) ?? 'The request was refused.',
      _ => 'The dashboard had a problem (${r.status}).',
    });
  }
}
