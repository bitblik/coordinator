import 'package:uuid/uuid.dart';

enum OfferStatus {
  created, // Initial state, invoice generated but not paid
  funded, // Hold invoice paid by maker, offer listed

  expired, // Offer timed out (e.g., reservation, BLIK confirmation)
  cancelled, // Offer explicitly cancelled by Maker while in 'funded' state

  reserved, // Taker has expressed interest, 15s timer started
  blikReceived, // Taker submitted BLIK, 120s timer started
  blikSentToMaker, // Maker requested BLIK code
  expiredBlik, // Maker did not get BLIK in time

  invalidBlik, // Maker marked the BLIK code as invalid
  expiredSentBlik, // BLIK expired after being sent to Maker
  takerConfirmed, // Taker confirmed BLIK payment success
  conflict, // Taker reported conflict after Maker marked BLIK as invalid
  dispute, // Maker opened a dispute after conflict

  makerConfirmed, // Maker confirmed BLIK payment success
  settled, // Hold invoice settled by coordinator

  payingTaker, // Taker is being paid
  takerPaymentFailed, // Settled, but LNURL payment to taker failed
  takerPaid, // Taker successfully paid via LNURL-pay
}

class Offer {
  final String id;
  final int amountSats;
  final int makerFees; // Renamed from feeSats
  final String makerPubkey;
  final String holdInvoicePaymentHash;
  final String holdInvoicePreimage; // Store preimage for settling
  OfferStatus status;
  DateTime createdAt;
  DateTime? updatedAt;
  String? takerPubkey;
  DateTime? reservedAt; // Timestamp when offer was reserved
  String? blikCode; // Store the submitted BLIK code
  DateTime? blikReceivedAt; // Timestamp when BLIK was received
  String? takerLightningAddress; // Store taker's LN address
  String? takerInvoice; // Store the invoice generated from LNURL-pay
  int? takerInvoiceFees; // Store the fees for taker's invoice
  DateTime? makerConfirmedAt; // Timestamp when maker confirmed payment
  DateTime? settledAt; // Timestamp when hold invoice was settled
  DateTime? takerPaidAt; // Timestamp when taker was paid
  int? takerFees; // Renamed from takerFeesSats

  // Fiat support
  final double fiatAmount;
  final String fiatCurrency;

  Offer({
    String? id,
    required this.amountSats,
    required this.makerFees, // Renamed from feeSats
    required this.makerPubkey,
    required this.holdInvoicePaymentHash,
    required this.holdInvoicePreimage,
    this.status = OfferStatus.created,
    DateTime? createdAt,
    this.updatedAt,
    this.takerPubkey,
    this.reservedAt,
    this.blikCode,
    this.blikReceivedAt,
    this.takerLightningAddress,
    this.takerInvoice,
    this.takerInvoiceFees,
    this.makerConfirmedAt,
    this.settledAt,
    this.takerPaidAt,
    this.takerFees, // Renamed from takerFeesSats
    required this.fiatAmount,
    required this.fiatCurrency,
  })  : id = id ?? Uuid().v4(),
        createdAt = createdAt ?? DateTime.now().toUtc();

  Offer copyWith({
    String? id,
    int? amountSats,
    int? makerFees,
    String? makerPubkey,
    String? holdInvoicePaymentHash,
    String? holdInvoicePreimage,
    OfferStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? takerPubkey,
    DateTime? reservedAt,
    String? blikCode,
    DateTime? blikReceivedAt,
    String? takerLightningAddress,
    String? takerInvoice,
    int? takerInvoiceFees,
    DateTime? makerConfirmedAt,
    DateTime? settledAt,
    DateTime? takerPaidAt,
    int? takerFees,
    double? fiatAmount,
    String? fiatCurrency,
  }) {
    return Offer(
      id: id ?? this.id,
      amountSats: amountSats ?? this.amountSats,
      makerFees: makerFees ?? this.makerFees,
      makerPubkey: makerPubkey ?? this.makerPubkey,
      holdInvoicePaymentHash:
          holdInvoicePaymentHash ?? this.holdInvoicePaymentHash,
      holdInvoicePreimage: holdInvoicePreimage ?? this.holdInvoicePreimage,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      takerPubkey: takerPubkey ?? this.takerPubkey,
      reservedAt: reservedAt ?? this.reservedAt,
      blikCode: blikCode ?? this.blikCode,
      blikReceivedAt: blikReceivedAt ?? this.blikReceivedAt,
      takerLightningAddress:
          takerLightningAddress ?? this.takerLightningAddress,
      takerInvoice: takerInvoice ?? this.takerInvoice,
      takerInvoiceFees: takerInvoiceFees ?? this.takerInvoiceFees,
      makerConfirmedAt: makerConfirmedAt ?? this.makerConfirmedAt,
      settledAt: settledAt ?? this.settledAt,
      takerPaidAt: takerPaidAt ?? this.takerPaidAt,
      takerFees: takerFees ?? this.takerFees,
      fiatAmount: fiatAmount ?? this.fiatAmount,
      fiatCurrency: fiatCurrency ?? this.fiatCurrency,
    );
  }

  Map<String, dynamic> toJson() => {
        'created_at': createdAt.toIso8601String(),
        'reserved_at': reservedAt?.toIso8601String(),
        'blik_received_at': blikReceivedAt?.toIso8601String(),
        'settled_at': settledAt?.toIso8601String(),
        'fiat_amount': fiatAmount,
        'fiat_currency': fiatCurrency,
      };
}
