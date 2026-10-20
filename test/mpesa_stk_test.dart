import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/mpesa_stk_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/sync_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/features/sell/pay_dialog.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pretend dashboard server: records what the app asked and plays back
/// scripted answers to the status polls.
class ScriptedServer implements SyncTransport {
  final posts = <({Uri url, String key, Map<String, dynamic> body})>[];
  final gets = <Uri>[];
  bool promptsOn = true;
  int startStatus = 202;
  Map<String, dynamic>? startReply;
  Object? throwOnStart;

  /// One answer per poll, the last repeating.
  List<SyncReply> pollAnswers = [];
  int polls = 0;

  static SyncReply answer(
    String status, {
    String? receipt,
    String? message,
    int http = 200,
  }) => SyncReply(http, {
    'request_id': 'x',
    'status': status,
    'phone': '254712***678',
    'receipt': receipt,
    'message': message,
  });

  @override
  Future<SyncReply> get(Uri url, String key) async {
    gets.add(url);
    if (url.path == '/api/ping') {
      return SyncReply(200, {
        'ok': true,
        'clinic': 'Emuktan',
        'features': {'mpesa_stk': promptsOn},
      });
    }
    final i = polls < pollAnswers.length ? polls : pollAnswers.length - 1;
    polls++;
    return pollAnswers[i];
  }

  @override
  Future<SyncReply> post(Uri url, String key, Object body) async {
    final map = (body as Map).cast<String, dynamic>();
    if (url.path == '/api/sync') {
      return SyncReply(200, {
        'accepted': 0,
        'features': {'mpesa_stk': promptsOn},
      });
    }
    if (throwOnStart != null) throw throwOnStart!;
    posts.add((url: url, key: key, body: map));
    return SyncReply(
      startStatus,
      startReply ??
          {
            'request_id': map['request_id'],
            'status': 'pending',
            'phone': '254712***678',
          },
    );
  }

  @override
  Future<SyncReply> postFile(Uri url, String key, File file) =>
      throw UnimplementedError();
}

const _url = 'https://dash.example.co.ke';
const _key = 'good-key-good-key-1';

void main() {
  late AppDatabase db;
  late ScriptedServer server;
  late SyncService sync;
  late MpesaStkService svc;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    server = ScriptedServer();
    sync = SyncService(db, transport: server);
    svc = MpesaStkService(sync, transport: server);
  });
  tearDown(() => db.close());

  group('the service', () {
    test('is unavailable until the dashboard says prompts are on', () async {
      expect(await svc.available(), isFalse); // nothing configured
      await sync.configure(url: _url, key: _key);
      expect(await svc.available(), isFalse); // configured, nothing heard yet

      await sync.testConnection(url: _url, key: _key);
      expect(await svc.available(), isTrue);

      server.promptsOn = false;
      await sync.syncNow(); // every sync refreshes the answer
      expect(await svc.available(), isFalse);

      server.promptsOn = true;
      await sync.syncNow();
      expect(await svc.available(), isTrue);

      await sync.clear();
      expect(await svc.available(), isFalse);
    });

    test('request ids are v4 uuids and differ', () {
      final a = svc.newRequestId(), b = svc.newRequestId();
      final v4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(a, matches(v4));
      expect(b, matches(v4));
      expect(a, isNot(b));
    });

    test('only whole shillings can be prompted', () {
      expect(MpesaStkService.canPrompt(150000), isTrue);
      expect(MpesaStkService.canPrompt(100), isTrue);
      expect(MpesaStkService.canPrompt(150050), isFalse);
      expect(MpesaStkService.canPrompt(99), isFalse);
      expect(MpesaStkService.canPrompt(0), isFalse);
    });

    test('start sends the amount in cents, the phone and the key', () async {
      await sync.configure(url: _url, key: _key);
      final s = await svc.start(
        requestId: 'id-1',
        amountCents: 150000,
        phone: ' 0712 345 678 ',
        reference: 'R-1',
      );
      expect(s.state, StkState.pending);
      expect(s.phone, '254712***678');
      final p = server.posts.single;
      expect(p.url.toString(), '$_url/api/mpesa/stk');
      expect(p.key, _key);
      expect(p.body, {
        'request_id': 'id-1',
        'amount_cents': 150000,
        'phone': '0712 345 678',
        'reference': 'R-1',
      });
    });

    test('check maps every answer, and success carries the code', () async {
      await sync.configure(url: _url, key: _key);
      final cases = {
        'pending': StkState.pending,
        'success': StkState.success,
        'failed': StkState.failed,
        'cancelled': StkState.cancelled,
        'timeout': StkState.timeout,
        'review': StkState.review,
      };
      for (final e in cases.entries) {
        server.pollAnswers = [
          ScriptedServer.answer(
            e.key,
            receipt: e.key == 'success' ? 'QGH7K2LMNP' : null,
          ),
        ];
        server.polls = 0;
        final s = await svc.check('id-1');
        expect(s.state, e.value, reason: e.key);
        expect(s.receipt, e.key == 'success' ? 'QGH7K2LMNP' : isNull);
      }
      expect(server.gets.last.path, '/api/mpesa/stk/id-1');
      expect(StkState.pending, isNot(equals(StkState.success)));
      expect(
        const StkStatus(requestId: 'a', state: StkState.timeout).isFinal,
        isFalse,
      );
      expect(
        const StkStatus(requestId: 'a', state: StkState.review).isFinal,
        isTrue,
      );
    });

    test('a success with no code is never trusted', () async {
      await sync.configure(url: _url, key: _key);
      for (final bad in [null, '']) {
        server.pollAnswers = [ScriptedServer.answer('success', receipt: bad)];
        server.polls = 0;
        await expectLater(() => svc.check('id'), throwsA(isA<StkException>()));
      }
    });

    test('an answer it does not know is an error, not a payment', () async {
      await sync.configure(url: _url, key: _key);
      server.pollAnswers = [ScriptedServer.answer('refunded')];
      await expectLater(() => svc.check('id'), throwsA(isA<StkException>()));
    });

    test('refusals are worded for the screen', () async {
      await sync.configure(url: _url, key: _key);
      Future<String> why(int http, [Map<String, dynamic>? body]) async {
        server.startStatus = http;
        server.startReply = body;
        try {
          await svc.start(requestId: 'i', amountCents: 100, phone: '0712');
        } on StkException catch (e) {
          return e.message;
        }
        return 'no error';
      }

      expect(await why(401), contains('did not accept the key'));
      expect(await why(501), contains('not switched on'));
      expect(
        await why(422, {'error': 'That is not a Safaricom phone number.'}),
        'That is not a Safaricom phone number.',
      );
      expect(await why(429, {'error': 'Too many prompts'}), 'Too many prompts');
      expect(await why(500), contains('problem (500)'));
    });

    test('network trouble becomes plain words', () async {
      await sync.configure(url: _url, key: _key);
      server.throwOnStart = const SocketException('down');
      await expectLater(
        () => svc.start(requestId: 'i', amountCents: 100, phone: '0712'),
        throwsA(
          isA<StkException>().having(
            (e) => e.message,
            'message',
            contains('No connection'),
          ),
        ),
      );
      server.throwOnStart = TimeoutException('slow');
      await expectLater(
        () => svc.start(requestId: 'i', amountCents: 100, phone: '0712'),
        throwsA(isA<StkException>()),
      );
    });

    test('without dashboard settings it says so', () async {
      await expectLater(
        () => svc.start(requestId: 'i', amountCents: 100, phone: '0712'),
        throwsA(
          isA<StkException>().having(
            (e) => e.message,
            'message',
            contains('not set up'),
          ),
        ),
      );
    });
  });

  group('the payment panel', () {
    late AuthService auth;
    late StockService stock;
    late SalesService sales;

    setUp(() async {
      auth = AuthService(db, hasher: const PinHasher(iterations: 10));
      stock = StockService(db);
      sales = SalesService(db, stock);
      final owner = await auth.createUser(
        displayName: 'Wanjiru Kamau',
        role: Role.owner,
        pin: '4821',
      );
      await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      final med = await stock.createMedicine(
        const MedicineInput(
          name: 'Paracetamol 500mg',
          barcode: '6001',
          unitsPerStrip: 10,
          pricePerStripCents: 9000,
          pricePerUnitCents: 1000,
        ),
        userId: owner.id,
      );
      await stock.receiveStock(
        medicineId: med,
        batchNumber: 'B1',
        expiry: DateTime(2099, 12, 31),
        qtyBaseUnits: 100,
        costPerUnitCents: 500,
        userId: owner.id,
      );
    });

    Future<void> openMpesa(WidgetTester tester, {bool promptsOn = true}) async {
      server.promptsOn = promptsOn;
      await sync.configure(url: _url, key: _key);
      await sync.testConnection(url: _url, key: _key);
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authServiceProvider.overrideWithValue(auth),
            stockServiceProvider.overrideWithValue(stock),
            salesServiceProvider.overrideWithValue(sales),
            syncServiceProvider.overrideWithValue(sync),
            mpesaStkServiceProvider.overrideWithValue(svc),
          ],
          child: EmuktanApp(
            open: () async => AppContext(
              db: db,
              dataDir: Directory.systemTemp,
              newRecoveryKey: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1357');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paracetamol 500mg').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay KES 10'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(PayDialog),
          matching: find.text('M-Pesa'),
        ),
      );
      await tester.pumpAndSettle();
    }

    final complete = find.widgetWithText(FilledButton, 'Complete sale');
    final back = find.widgetWithText(OutlinedButton, 'Back to sale');
    final phone = find.widgetWithText(TextField, 'Customer phone');
    final send = find.widgetWithText(FilledButton, 'Send prompt');
    final code = find.widgetWithText(TextField, 'M-Pesa transaction code');

    testWidgets('no prompt box when the dashboard does not offer it', (
      tester,
    ) async {
      await openMpesa(tester, promptsOn: false);
      expect(phone, findsNothing);
      expect(code, findsOneWidget);
    });

    testWidgets(
      'prompt, wait, paid: the real code fills in and the sale completes',
      (tester) async {
        server.pollAnswers = [
          ScriptedServer.answer('pending'),
          ScriptedServer.answer('pending'),
          ScriptedServer.answer('success', receipt: 'SHK1ABC234'),
        ];
        await openMpesa(tester);
        expect(
          tester.widget<FilledButton>(send).onPressed,
          isNull,
        ); // no phone yet

        await tester.enterText(phone, '0712 345 678');
        await tester.pump();
        await tester.tap(send);
        await tester.pump();
        await tester.pump();

        // The request carries this sale's amount (KES 10 = 1000 cents).
        expect(server.posts.single.body['amount_cents'], 1000);
        expect(server.posts.single.body['phone'], '0712 345 678');
        expect(find.textContaining('Waiting for the customer'), findsOneWidget);
        // While a prompt is out the sale cannot be completed or abandoned.
        expect(tester.widget<FilledButton>(complete).onPressed, isNull);
        expect(tester.widget<OutlinedButton>(back).onPressed, isNull);

        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 3));
        expect(find.textContaining('M-Pesa code SHK1ABC234'), findsOneWidget);
        expect(tester.widget<TextField>(code).readOnly, isTrue);
        expect(tester.widget<TextField>(code).controller!.text, 'SHK1ABC234');
        expect(tester.widget<FilledButton>(complete).onPressed, isNotNull);

        await tester.tap(complete);
        await tester.pumpAndSettle();
        expect(find.textContaining('code SHK1ABC234'), findsOneWidget);
      },
    );

    testWidgets('a cancelled prompt says so and the typed code still works', (
      tester,
    ) async {
      server.pollAnswers = [ScriptedServer.answer('cancelled')];
      await openMpesa(tester);
      await tester.enterText(phone, '0712345678');
      await tester.pump();
      await tester.tap(send);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(find.text('The customer cancelled the prompt.'), findsOneWidget);
      expect(tester.widget<FilledButton>(complete).onPressed, isNull);
      await tester.enterText(code, 'qgh7k2lmnp');
      await tester.pump();
      expect(tester.widget<FilledButton>(complete).onPressed, isNotNull);
    });

    testWidgets('a result that needs checking is never shown as paid', (
      tester,
    ) async {
      server.pollAnswers = [
        ScriptedServer.answer('review', message: 'The amount paid differs.'),
      ];
      await openMpesa(tester);
      await tester.enterText(phone, '0712345678');
      await tester.pump();
      await tester.tap(send);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(find.textContaining('Do not treat this as paid'), findsOneWidget);
      expect(find.textContaining('M-Pesa code'), findsNothing);
      expect(tester.widget<FilledButton>(complete).onPressed, isNull);
      expect(tester.widget<TextField>(code).readOnly, isFalse);
    });

    testWidgets('a refused start leaves manual entry open', (tester) async {
      server.startStatus = 422;
      server.startReply = {'error': 'That is not a Safaricom phone number.'};
      await openMpesa(tester);
      await tester.enterText(phone, '0612345678');
      await tester.pump();
      await tester.tap(send);
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('That is not a Safaricom phone number.'),
        findsOneWidget,
      );
      expect(find.textContaining('type the M-Pesa code below'), findsOneWidget);
      await tester.enterText(code, 'qgh7k2lmnp');
      await tester.pump();
      expect(tester.widget<FilledButton>(complete).onPressed, isNotNull);
    });

    testWidgets('after a lost connection the retry reuses the request id', (
      tester,
    ) async {
      await openMpesa(tester);
      await tester.enterText(phone, '0712345678');
      await tester.pump();

      server.throwOnStart = const SocketException('down');
      await tester.tap(send);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('No connection'), findsOneWidget);

      server.throwOnStart = null;
      await tester.tap(send);
      await tester.pump();
      await tester.pump();
      expect(server.posts, hasLength(1));
      // A second attempt after the first failed to arrive used the same id: the
      // server would treat a duplicate as the same prompt, never a second one.
      server.pollAnswers = [ScriptedServer.answer('pending')];
      await tester.pump(const Duration(seconds: 3));
      expect(
        server.gets.last.path,
        '/api/mpesa/stk/${server.posts.single.body['request_id']}',
      );
    });

    testWidgets('stopping the wait frees the screen', (tester) async {
      server.pollAnswers = [ScriptedServer.answer('pending')];
      await openMpesa(tester);
      await tester.enterText(phone, '0712345678');
      await tester.pump();
      await tester.tap(send);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Stop waiting'));
      await tester.pump();
      expect(tester.widget<OutlinedButton>(back).onPressed, isNotNull);
      expect(send, findsOneWidget);
      // No more polling once stopped.
      final polled = server.polls;
      await tester.pump(const Duration(seconds: 10));
      expect(server.polls, polled);
    });
  });
}
