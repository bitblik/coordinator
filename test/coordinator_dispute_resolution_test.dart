import 'package:bitblik_coordinator/src/services/coordinator_service.dart';
import 'package:bitblik_coordinator/src/services/database_service.dart';
import 'package:bitblik_coordinator/src/services/payment_service.dart';
import 'package:bitblik_coordinator/src/models/create_hold_invoice_result.dart';
import 'package:bitblik_coordinator/src/models/pay_invoice_result.dart';
import 'package:bitblik_coordinator/src/models/offer.dart';
import 'package:bitblik_coordinator/src/models/invoice_status.dart';
import 'package:bitblik_coordinator/src/models/invoice_update.dart';
import 'package:bitblik_coordinator/src/models/invoice_details.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:http/http.dart' as http;
import 'package:clock/clock.dart';
import 'dart:convert'; // For jsonEncode
import 'package:fake_async/fake_async.dart';
import 'dart:async';

// Use existing mocks from the main test file.
// Ensure `dart run build_runner build --delete-conflicting-outputs` is run in the coordinator directory
// if this file or coordinator_service_test.dart changes mock requirements.
@GenerateMocks([DatabaseService, PaymentService, http.Client])
import 'coordinator_service_test.mocks.dart';

// Helper class for matching against a dynamically changing string variable
class _StringEqualsDynamicValueMatcher extends Matcher {
  final String Function() _getValue;
  final String _variableName;

  _StringEqualsDynamicValueMatcher(this._getValue, this._variableName);

  @override
  bool matches(dynamic item, Map matchState) {
    if (item is! String) {
      addStateInfo(
          matchState, {'item': item, 'reason': 'Item is not a String.'});
      return false;
    }
    final expectedValue = _getValue();
    if (expectedValue.isEmpty) {
      addStateInfo(matchState, {
        'item': item,
        'reason': 'Expected value ($_variableName) is empty.'
      });
      return false;
    }
    final bool match = (item == expectedValue);
    if (!match) {
      addStateInfo(matchState, {
        'item': item,
        'reason': 'Item "$item" does not equal expected value "$expectedValue".'
      });
    }
    return match;
  }

  @override
  Description describe(Description description) => description.add(
      'a string that equals the current non-empty value of $_variableName ("${_getValue()}")');

  @override
  Description describeMismatch(dynamic item, Description mismatchDescription,
      Map matchState, bool verbose) {
    final String? reason = matchState['reason'] as String?;
    if (reason != null) {
      return mismatchDescription.add(reason);
    }
    if (item is! String) {
      return mismatchDescription.add('was not a String, but was $item');
    }
    final expectedValue = _getValue();
    if (expectedValue.isEmpty) {
      return mismatchDescription.add(
          'expected value ($_variableName) was empty, so no match was possible');
    }
    return mismatchDescription
        .add('was "$item" but expected "$expectedValue" (for $_variableName)');
  }
}

// Helper class for matching against a dynamically changing Offer ID
class _OfferIdEqualsDynamicValueMatcher extends Matcher {
  final String? Function() _getOfferId;
  final String _variableName;

  _OfferIdEqualsDynamicValueMatcher(this._getOfferId, this._variableName);

  @override
  bool matches(dynamic item, Map matchState) {
    if (item is! String) {
      addStateInfo(matchState,
          {'item': item, 'reason': 'Item is not a String (Offer ID).'});
      return false;
    }
    final expectedOfferId = _getOfferId();
    if (expectedOfferId == null || expectedOfferId.isEmpty) {
      addStateInfo(matchState, {
        'item': item,
        'reason': 'Expected Offer ID ($_variableName) is null or empty.'
      });
      return false;
    }
    final bool match = (item == expectedOfferId);
    if (!match) {
      addStateInfo(matchState, {
        'item': item,
        'reason':
            'Item Offer ID "$item" does not equal expected Offer ID "$expectedOfferId".'
      });
    }
    return match;
  }

  @override
  Description describe(Description description) {
    final currentId = _getOfferId();
    return description.add(
        'a string that equals the current non-empty value of $_variableName ("${currentId ?? 'not set'}")');
  }

  @override
  Description describeMismatch(dynamic item, Description mismatchDescription,
      Map matchState, bool verbose) {
    final String? reason = matchState['reason'] as String?;
    if (reason != null) {
      return mismatchDescription.add(reason);
    }
    if (item is! String) {
      return mismatchDescription.add('was not a String, but was $item');
    }
    final expectedOfferId = _getOfferId();
    if (expectedOfferId == null || expectedOfferId.isEmpty) {
      return mismatchDescription.add(
          'expected Offer ID ($_variableName) was null or empty, so no match was possible');
    }
    return mismatchDescription.add(
        'was "$item" but expected "$expectedOfferId" (for $_variableName)');
  }
}

void main() {
  const String disputeOfferId = 'dispute-offer-id';
  const String disputeMakerId = 'dispute-maker-id';
  const String disputeTakerId = 'dispute-taker-id';
  const String disputePreimage = 'dispute-preimage-value';
  const String disputePaymentHash = 'dispute-payment-hash-value';
  const String disputeBlikCode = '987654';
  const String disputeTakerLnAddress = 'dispute-taker@example.com';

  const String testOfferId = 'default-test-offer-id';
  const String testMakerId = 'default-test-maker-id';
  const String testTakerId = 'default-test-taker-id';
  const String testPaymentHash = 'default-test-payment-hash';
  const String testPreimage = 'default-test-preimage';
  const double testFiatAmount = 100.0;
  const int testSatsAmount = 200000;
  const int testMakerFees = 1000;
  const int testTakerFees = 1000;

  late MockDatabaseService mockDbService;
  late MockPaymentService mockPaymentService;
  late MockClient mockHttpClient;
  late CoordinatorService coordinatorService;

  Offer createTestOffer({
    String id = testOfferId,
    OfferStatus status = OfferStatus.funded,
    String makerPubkey = testMakerId,
    String? takerPubkey,
    DateTime? createdAt,
    DateTime? reservedAt,
    DateTime? blikReceivedAt,
    String holdInvoicePaymentHash = testPaymentHash,
    String holdInvoicePreimage = testPreimage,
    String? blikCode,
    String? takerLightningAddress,
    double fiatAmount = testFiatAmount,
    int amountSats = testSatsAmount,
    int makerFees = testMakerFees,
    int? takerFees = testTakerFees,
    String? takerInvoice,
    String fiatCurrency = 'PLN',
  }) {
    return Offer(
      id: id,
      status: status,
      makerPubkey: makerPubkey,
      takerPubkey: takerPubkey,
      createdAt: createdAt ?? DateTime(2023, 1, 1, 10, 0, 0).toUtc(),
      reservedAt: reservedAt,
      blikReceivedAt: blikReceivedAt,
      holdInvoicePaymentHash: holdInvoicePaymentHash,
      holdInvoicePreimage: holdInvoicePreimage,
      blikCode: blikCode,
      takerLightningAddress: takerLightningAddress,
      fiatAmount: fiatAmount,
      amountSats: amountSats,
      makerFees: makerFees,
      takerFees: takerFees,
      fiatCurrency: fiatCurrency,
      takerInvoice: takerInvoice,
    );
  }

  setUp(() {
    mockDbService = MockDatabaseService();
    mockPaymentService = MockPaymentService();
    mockHttpClient = MockClient();

    coordinatorService = CoordinatorService(
      mockDbService,
      paymentServiceForTest: mockPaymentService,
      clock: clock,
      httpClient: mockHttpClient,
    );

    const coingeckoUrl =
        'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=pln';
    const yadioUrl = 'https://api.yadio.io/exrates/pln';
    const blockchainInfoUrl = 'https://blockchain.info/ticker';

    when(mockHttpClient.get(
            argThat(predicate<Uri>((uri) => uri.toString() == coingeckoUrl))))
        .thenAnswer((_) async => http.Response(
            jsonEncode({
              'bitcoin': {'pln': 250000.0}
            }),
            200));
    when(mockHttpClient
            .get(argThat(predicate<Uri>((uri) => uri.toString() == yadioUrl))))
        .thenAnswer(
            (_) async => http.Response(jsonEncode({'BTC': 251000.0}), 200));
    when(mockHttpClient.get(argThat(
            predicate<Uri>((uri) => uri.toString() == blockchainInfoUrl))))
        .thenAnswer((_) async => http.Response(
            jsonEncode({
              'PLN': {'last': 249000.0}
            }),
            200));

    const generalLnurlWellKnownUrl =
        'https://example.com/.well-known/lnurlp/taker';
    when(mockHttpClient.get(argThat(predicate<Uri>(
        (uri) =>
            uri.toString() ==
            generalLnurlWellKnownUrl)))).thenAnswer((_) async => http.Response(
        '{"tag":"payRequest","callback":"https://example.com/lnurlpay/taker","minSendable":1000,"maxSendable":1000000000,"metadata":"[]"}',
        200));
    const generalLnurlCallbackBase = 'https://example.com/lnurlpay/taker';
    when(mockHttpClient.get(argThat(predicate<Uri>(
            (uri) => uri.toString().startsWith(generalLnurlCallbackBase)))))
        .thenAnswer((_) async => http.Response(
            '{"pr":"lnbc_test_invoice_from_general_lnurl_mock","status":"OK"}',
            200));

    const disputeLnurlWellKnownUrl =
        'https://example.com/.well-known/lnurlp/dispute-taker';
    when(mockHttpClient.get(argThat(predicate<Uri>(
            (uri) => uri.toString() == disputeLnurlWellKnownUrl))))
        .thenAnswer((_) async {
      return http.Response(
          '{"tag":"payRequest","callback":"https://example.com/lnurlpay/dispute-taker","minSendable":1000,"maxSendable":1000000000,"metadata":"[]"}',
          200);
    });
    const disputeLnurlCallbackBase =
        'https://example.com/lnurlpay/dispute-taker';
    when(mockHttpClient.get(argThat(predicate<Uri>(
            (uri) => uri.toString().startsWith(disputeLnurlCallbackBase)))))
        .thenAnswer((_) async {
      return http.Response(
          '{"pr":"lnbc_test_invoice_for_dispute_lnurl","status":"OK"}', 200);
    });

    when(mockDbService.getOfferById(any)).thenAnswer((_) async => null);
    when(mockDbService.updateOfferStatus(
      any,
      any,
      takerPubkey: anyNamed('takerPubkey'),
      blikCode: anyNamed('blikCode'),
      takerLightningAddress: anyNamed('takerLightningAddress'),
      reservedAt: anyNamed('reservedAt'),
      blikReceivedAt: anyNamed('blikReceivedAt'),
      takerFees: anyNamed('takerFees'),
    )).thenAnswer((_) async => true);
    when(mockDbService.createOffer(any)).thenAnswer((invocation) async {
      final Offer offerToCreate = invocation.positionalArguments.first as Offer;
      return offerToCreate;
    });
    when(mockDbService.cancelOffer(any, any)).thenAnswer((_) async => true);
    when(mockPaymentService.createHoldInvoice(
            amountSats: anyNamed('amountSats'),
            memo: anyNamed('memo'),
            paymentHashHex: anyNamed('paymentHashHex')))
        .thenAnswer((_) async => CreateHoldInvoiceResult(
            invoice: 'lnbc_test_hold_invoice', paymentHash: testPaymentHash));
    when(mockPaymentService.subscribeToInvoiceUpdates(
            paymentHashHex: anyNamed('paymentHashHex')))
        .thenAnswer((_) => Stream.value(InvoiceUpdate(
            status: InvoiceStatus.OPEN, paymentHash: testPaymentHash)));
    when(mockPaymentService.settleInvoice(preimageHex: anyNamed('preimageHex')))
        .thenAnswer((_) async {});
    when(mockPaymentService.cancelInvoice(
            paymentHashHex: anyNamed('paymentHashHex')))
        .thenAnswer((_) async {});
    when(mockPaymentService.payInvoice(
            invoice: anyNamed('invoice'),
            amountSat: anyNamed('amountSat'),
            feeLimitSat: anyNamed('feeLimitSat')))
        .thenAnswer((_) async =>
            PayInvoiceResult(paymentPreimage: 'paid_preimage', feeSat: 10));
    when(mockPaymentService.lookupInvoice(
            paymentHashHex: anyNamed('paymentHashHex')))
        .thenAnswer((invocation) async {
      final paymentHash =
          invocation.namedArguments[Symbol('paymentHashHex')] as String;
      return InvoiceDetails(
          paymentHash: paymentHash, status: InvoiceStatus.OPEN);
    });
    // Mock for service.init() calls
    when(mockDbService.getOffersByStatus(any, limit: anyNamed('limit')))
        .thenAnswer((_) async => []);
    when(mockDbService.updateTakerInvoice(any, any))
        .thenAnswer((_) async => true);
    when(mockDbService.updateTakerInvoiceFees(any, any))
        .thenAnswer((_) async => true);
  });

  group('Dispute Resolution Logic', () {
    test(
        'markBlikInvalid starts timer, expires, offer becomes dispute, hold invoice settled',
        () {
      fakeAsync((async) {
        final Duration serviceInternalDisputeTimeout = Duration(
            seconds: int.tryParse(const String.fromEnvironment(
                    'DISPUTE_TIMEOUT_SECONDS',
                    defaultValue: '86400')) ??
                86400);
        final Duration shortTimerDurationForTest = Duration(seconds: 2);
        final DateTime fixedTimeBeforeAction = clock.now().toUtc();
        final DateTime offerCreatedAt = fixedTimeBeforeAction
            .subtract(serviceInternalDisputeTimeout)
            .add(shortTimerDurationForTest);

        Offer currentOffer = createTestOffer(
          id: disputeOfferId,
          makerPubkey: disputeMakerId,
          takerPubkey: disputeTakerId,
          status: OfferStatus.blikSentToMaker,
          createdAt: offerCreatedAt,
          holdInvoicePreimage: disputePreimage,
          holdInvoicePaymentHash: disputePaymentHash,
          blikCode: disputeBlikCode,
          takerLightningAddress: disputeTakerLnAddress,
          reservedAt: offerCreatedAt.subtract(Duration(minutes: 1)),
          blikReceivedAt: offerCreatedAt.subtract(Duration(seconds: 30)),
        );

        when(mockDbService.getOfferById(disputeOfferId))
            .thenAnswer((_) async => currentOffer);
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.invalidBlik))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.invalidBlik);
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.dispute))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.dispute);
          return true;
        });
        when(mockPaymentService.settleInvoice(preimageHex: disputePreimage))
            .thenAnswer((_) async {});

        coordinatorService.markBlikInvalid(disputeOfferId, disputeMakerId);
        async.flushMicrotasks();
        expect(currentOffer.status, OfferStatus.invalidBlik);

        if (shortTimerDurationForTest > Duration(milliseconds: 100)) {
          async.elapse(shortTimerDurationForTest - Duration(milliseconds: 100));
          verifyNever(
              mockPaymentService.settleInvoice(preimageHex: disputePreimage));
          expect(currentOffer.status, OfferStatus.invalidBlik);
        }
        async.elapse(
          (shortTimerDurationForTest <= Duration(milliseconds: 100))
              ? Duration(
                  milliseconds: shortTimerDurationForTest.inMilliseconds + 100)
              : Duration(milliseconds: 200),
        );

        verify(mockPaymentService.settleInvoice(preimageHex: disputePreimage))
            .called(1);
        verify(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.dispute))
            .called(1);
        expect(currentOffer.status, OfferStatus.dispute);
      });
    });

    test(
        'markOfferConflict starts timer, expires, offer becomes dispute, hold invoice settled',
        () {
      fakeAsync((async) {
        final Duration serviceInternalDisputeTimeout = Duration(
            seconds: int.tryParse(const String.fromEnvironment(
                    'DISPUTE_TIMEOUT_SECONDS',
                    defaultValue: '86400')) ??
                86400);
        final Duration shortTimerDurationForTest = Duration(seconds: 2);
        final DateTime fixedTimeBeforeAction = clock.now().toUtc();
        final DateTime offerCreatedAt = fixedTimeBeforeAction
            .subtract(serviceInternalDisputeTimeout)
            .add(shortTimerDurationForTest);

        Offer currentOffer = createTestOffer(
          id: disputeOfferId,
          makerPubkey: disputeMakerId,
          takerPubkey: disputeTakerId,
          status: OfferStatus.invalidBlik,
          createdAt: offerCreatedAt,
          holdInvoicePreimage: disputePreimage,
          holdInvoicePaymentHash: disputePaymentHash,
        );

        when(mockDbService.getOfferById(disputeOfferId))
            .thenAnswer((_) async => currentOffer);
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.conflict))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.conflict);
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.dispute))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.dispute);
          return true;
        });
        when(mockPaymentService.settleInvoice(preimageHex: disputePreimage))
            .thenAnswer((_) async {});

        coordinatorService.markOfferConflict(disputeOfferId, disputeTakerId);
        async.flushMicrotasks();
        expect(currentOffer.status, OfferStatus.conflict);

        if (shortTimerDurationForTest > Duration(milliseconds: 100)) {
          async.elapse(shortTimerDurationForTest - Duration(milliseconds: 100));
          verifyNever(
              mockPaymentService.settleInvoice(preimageHex: disputePreimage));
          expect(currentOffer.status, OfferStatus.conflict);
        }
        async.elapse(
          (shortTimerDurationForTest <= Duration(milliseconds: 100))
              ? Duration(
                  milliseconds: shortTimerDurationForTest.inMilliseconds + 100)
              : Duration(milliseconds: 200),
        );

        verify(mockPaymentService.settleInvoice(preimageHex: disputePreimage))
            .called(1);
        verify(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.dispute))
            .called(1);
        expect(currentOffer.status, OfferStatus.dispute);
      });
    });

    test(
        'Dispute timer cancelled if maker confirms payment from conflict state',
        () {
      fakeAsync((async) {
        final Duration serviceInternalDisputeTimeout = Duration(
            seconds: int.tryParse(const String.fromEnvironment(
                    'DISPUTE_TIMEOUT_SECONDS',
                    defaultValue: '86400')) ??
                86400);
        final Duration shortTimerDurationForTest = Duration(seconds: 5);
        final DateTime fixedTimeBeforeAction = clock.now().toUtc();
        final DateTime offerCreatedAt = fixedTimeBeforeAction
            .subtract(serviceInternalDisputeTimeout)
            .add(shortTimerDurationForTest);

        Offer currentOffer = createTestOffer(
          id: disputeOfferId,
          makerPubkey: disputeMakerId,
          takerPubkey: disputeTakerId,
          status: OfferStatus.conflict,
          createdAt: offerCreatedAt,
          holdInvoicePreimage: disputePreimage,
          holdInvoicePaymentHash: disputePaymentHash,
          takerLightningAddress: disputeTakerLnAddress,
          amountSats: testSatsAmount,
          makerFees: testMakerFees,
          takerFees: testTakerFees,
        );

        when(mockDbService.getOfferById(disputeOfferId))
            .thenAnswer((_) async => currentOffer);
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.makerConfirmed))
            .thenAnswer((_) async {
          currentOffer =
              currentOffer.copyWith(status: OfferStatus.makerConfirmed);
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.settled))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.settled);
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.payingTaker))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.payingTaker);
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.takerPaid,
                takerFees: anyNamed('takerFees')))
            .thenAnswer((_) async {
          currentOffer = currentOffer.copyWith(status: OfferStatus.takerPaid);
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });

        when(mockPaymentService.settleInvoice(preimageHex: disputePreimage))
            .thenAnswer((_) async {});
        when(mockPaymentService.payInvoice(
                invoice: anyNamed('invoice'),
                amountSat: anyNamed('amountSat'),
                feeLimitSat: anyNamed('feeLimitSat')))
            .thenAnswer((_) async => PayInvoiceResult(
                paymentPreimage: 'dispute_cancelled_paid', feeSat: 5));

        when(mockDbService.getOffersByStatus(OfferStatus.conflict,
                limit: anyNamed('limit')))
            .thenAnswer((_) async => [currentOffer]);
        coordinatorService.init();
        async.flushMicrotasks();

        coordinatorService.confirmMakerPayment(disputeOfferId, disputeMakerId);
        async.flushMicrotasks();

        async.elapse(Duration(seconds: 1));
        async.flushMicrotasks();

        expect(currentOffer.status, OfferStatus.takerPaid);
        verify(mockPaymentService.settleInvoice(preimageHex: disputePreimage))
            .called(1);
        // Verify that the taker was paid
        verify(mockPaymentService.payInvoice(
          invoice: "lnbc_test_invoice_for_dispute_lnurl", // From LNURL mock
          amountSat: testSatsAmount - testTakerFees, // 200000 - 1000 = 199000
          feeLimitSat: 1100, // Based on the actual call from the test log
        )).called(1);

        async.elapse(shortTimerDurationForTest + Duration(seconds: 5));
        async.flushMicrotasks();

        // The previous verifications for settleInvoice and payInvoice (called once)
        // already ensure they were called. We now check that the dispute status
        // was not set, implying the timer didn't fire incorrectly.
        verifyNever(mockDbService.updateOfferStatus(
            disputeOfferId, OfferStatus.dispute));
        expect(currentOffer.status, OfferStatus.takerPaid);
      });
    });

    test('Dispute timer cancelled if offer re-reserved from invalidBlik state',
        () {
      fakeAsync((async) {
        final Duration serviceInternalDisputeTimeout = Duration(
            seconds: int.tryParse(const String.fromEnvironment(
                    'DISPUTE_TIMEOUT_SECONDS',
                    defaultValue: '86400')) ??
                86400);
        final Duration shortTimerDurationForTest = Duration(seconds: 5);
        final DateTime fixedTimeBeforeAction = clock.now().toUtc();
        final DateTime offerCreatedAt = fixedTimeBeforeAction
            .subtract(serviceInternalDisputeTimeout)
            .add(shortTimerDurationForTest);

        Offer currentOffer = createTestOffer(
          id: disputeOfferId,
          makerPubkey: disputeMakerId,
          takerPubkey: disputeTakerId,
          status: OfferStatus.invalidBlik,
          createdAt: offerCreatedAt,
          holdInvoicePreimage: disputePreimage,
          holdInvoicePaymentHash: disputePaymentHash,
        );

        when(mockDbService.getOfferById(disputeOfferId))
            .thenAnswer((_) async => currentOffer);
        when(mockDbService.updateOfferStatus(
                disputeOfferId, OfferStatus.reserved,
                takerPubkey: disputeTakerId,
                reservedAt: anyNamed('reservedAt')))
            .thenAnswer((invocation) async {
          currentOffer = currentOffer.copyWith(
            status: OfferStatus.reserved,
            reservedAt:
                invocation.namedArguments[Symbol('reservedAt')] as DateTime,
          );
          when(mockDbService.getOfferById(disputeOfferId))
              .thenAnswer((_) async => currentOffer);
          return true;
        });

        when(mockDbService.getOffersByStatus(OfferStatus.invalidBlik,
                limit: anyNamed('limit')))
            .thenAnswer((_) async => [currentOffer]);
        coordinatorService.init();
        async.flushMicrotasks();

        coordinatorService.reserveOffer(disputeOfferId, disputeTakerId);
        async.flushMicrotasks();
        expect(currentOffer.status, OfferStatus.reserved);

        async.elapse(shortTimerDurationForTest + Duration(seconds: 5));
        async.flushMicrotasks();

        verifyNever(
            mockPaymentService.settleInvoice(preimageHex: disputePreimage));
        verifyNever(mockDbService.updateOfferStatus(
            disputeOfferId, OfferStatus.dispute));
        expect(currentOffer.status, OfferStatus.reserved);
      });
    });
  });
}
