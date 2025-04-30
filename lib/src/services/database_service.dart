import 'dart:io';
import 'package:postgres/postgres.dart';
import '../models/offer.dart';

// Load connection details from environment variables, defaulting to localhost and 5432
final _dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
final _dbPort = int.tryParse(Platform.environment['DB_PORT'] ?? '') ?? 5432;
final _dbName = 'bitblik_db';
final _dbUser = 'user'; // Replace with your DB user
final _dbPassword = 'password'; // Replace with your DB password

class DatabaseService {
  Pool? _pool; // Changed from PostgreSQLConnection to Pool

  Future<void> connect() async {
    if (_pool != null) {
      return; // Already connected/initialized
    }

    // Define Pool settings
    var poolSettings = PoolSettings(
        maxConnectionCount:
            10, // Example: Allow up to 10 concurrent connections
        // queryTimeout: const Duration(minutes: 1), // Optional: Timeout for queries
        sslMode: SslMode.disable // Adjust SSL mode as needed
        );

    // Define the endpoint using environment variables
    var endpoint = Endpoint(
      host: _dbHost,
      port: _dbPort,
      database: _dbName,
      username: _dbUser,
      password: _dbPassword,
    );

    try {
      // Initialize the pool
      _pool = Pool.withEndpoints([endpoint], settings: poolSettings);
      // The pool doesn't require an explicit 'open' call like a single connection.
      // We can test the connection by executing a simple query.
      await _pool!.execute('SELECT 1;');
      print('Database pool initialized and connection tested.');
      await _ensureOffersTable();
    } catch (e) {
      print('Error initializing database pool: $e');
      _pool = null; // Ensure pool is null on error
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await _pool?.close(); // Close the pool
    _pool = null;
    print('Database pool closed.');
  }

  Future<void> _ensureOffersTable() async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    // Use pool.execute
    await _pool!.execute('''
      CREATE TABLE IF NOT EXISTS offers (
        id UUID PRIMARY KEY,
        amount_sats BIGINT NOT NULL,
        maker_fees BIGINT NOT NULL, -- Renamed
        maker_pubkey TEXT NOT NULL,
        taker_pubkey TEXT,
        taker_lightning_address TEXT,
        taker_invoice TEXT,
        taker_invoice_fees BIGINT,
        blik_code TEXT,
        hold_invoice_payment_hash TEXT UNIQUE NOT NULL,
        hold_invoice_preimage TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ,
        reserved_at TIMESTAMPTZ,
        blik_received_at TIMESTAMPTZ,
        maker_confirmed_at TIMESTAMPTZ,
        settled_at TIMESTAMPTZ,
        taker_paid_at TIMESTAMPTZ,
        taker_fees BIGINT NULL, -- Renamed
        fiat_amount NUMERIC,
        fiat_currency TEXT
      );
    ''');
    // Use pool.execute for index creation
    await _pool!.execute('''
      CREATE INDEX IF NOT EXISTS idx_offers_status ON offers (status);
    ''');
    await _pool!.execute('''
      CREATE INDEX IF NOT EXISTS idx_offers_maker_pubkey ON offers (maker_pubkey);
    ''');
    await _pool!.execute('''
      CREATE INDEX IF NOT EXISTS idx_offers_taker_pubkey ON offers (taker_pubkey);
    ''');
    print('Offers table checked/created.');
  }

  Future<Offer> createOffer(Offer offer) async {
    if (_pool == null) throw StateError('Database pool not initialized.');

    final now = DateTime.now().toUtc();
    await _pool!.execute(
      '''
        INSERT INTO offers (id, amount_sats, maker_fees, maker_pubkey, hold_invoice_payment_hash, hold_invoice_preimage, status, created_at, updated_at, fiat_amount, fiat_currency)
        VALUES (@id, @amount_sats, @maker_fees, @maker_pubkey, @hold_invoice_payment_hash, @hold_invoice_preimage, @status, @created_at, @updated_at, @fiat_amount, @fiat_currency)
      ''',
      // Use the 'parameters' named argument
      parameters: {
        'id': offer.id,
        'amount_sats': offer.amountSats,
        'maker_fees': offer.makerFees, // Renamed
        'maker_pubkey': offer.makerPubkey,
        'hold_invoice_payment_hash': offer.holdInvoicePaymentHash,
        'hold_invoice_preimage': offer.holdInvoicePreimage,
        'status': offer.status.name,
        'created_at': offer.createdAt.toUtc(),
        'updated_at': now,
        'fiat_amount': offer.fiatAmount,
        'fiat_currency': offer.fiatCurrency,
      },
    );
    offer.updatedAt = now;
    return offer;
  }

  Future<Offer?> getOfferById(String id) async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    // Use pool.run and connection.execute
    final results = await _pool!.run((connection) => connection.execute(
          Sql.named('SELECT * FROM offers WHERE id = @id LIMIT 1'),
          parameters: {'id': id},
        ));
    if (results.isEmpty) return null;
    return _mapRowToOffer(results.first);
  }

  Future<Offer?> getOfferByPaymentHash(String paymentHash) async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    // Use pool.run and connection.execute
    final results = await _pool!.run((connection) => connection.execute(
          Sql.named(
              'SELECT * FROM offers WHERE hold_invoice_payment_hash = @paymentHash LIMIT 1'),
          parameters: {'paymentHash': paymentHash},
        ));
    if (results.isEmpty) return null;
    return _mapRowToOffer(results.first);
  }

  Future<List<Offer>> getOffersByStatus(OfferStatus status,
      {int limit = 50, int offset = 0}) async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    // Use pool.run and connection.execute
    final results = await _pool!.run((connection) => connection.execute(
          Sql.named(
              'SELECT * FROM offers WHERE status = @status ORDER BY created_at DESC LIMIT @limit OFFSET @offset'),
          parameters: {
            'status': status.name,
            'limit': limit,
            'offset': offset,
          },
        )); // Removed extra closing parenthesis
    return results.map(_mapRowToOffer).toList();
  }

  Future<bool> updateTakerInvoice(String id, String takerInvoice) async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    final now = DateTime.now().toUtc();
    final affectedRows = await _pool!.execute(
      'UPDATE offers SET taker_invoice = @taker_invoice, updated_at = @updated_at WHERE id = @id',
      parameters: {
        // Use 'parameters'
        'id': id,
        'taker_invoice': takerInvoice,
        'updated_at': now,
      },
    );
    return affectedRows == 1;
  }

  Future<bool> updateTakerInvoiceFees(String id, int fees) async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    final now = DateTime.now().toUtc();
    final affectedRows = await _pool!.execute(
      'UPDATE offers SET taker_invoice_fees = @fees, updated_at = @updated_at WHERE id = @id',
      parameters: {
        // Use 'parameters'
        'id': id,
        'fees': fees,
        'updated_at': now,
      },
    );
    return affectedRows == 1;
  }

  Future<bool> updateOfferStatus(
      // Return type back to bool
      String id,
      OfferStatus newStatus,
      {String? takerPubkey,
      String? blikCode,
      String? takerLightningAddress,
      DateTime? reservedAt,
      DateTime? blikReceivedAt,
      int? takerFees}) async {
    // Renamed parameter
    // Added takerFees
    if (_pool == null) throw StateError('Database pool not initialized.');
    final now = DateTime.now().toUtc(); // Keep 'now' for updated_at
    Map<String, dynamic> params = {
      'id': id,
      'status': newStatus.name,
      'updated_at': now,
    };
    List<String> setClauses = ['status = @status', 'updated_at = @updated_at'];

    switch (newStatus) {
      case OfferStatus.reserved:
        if (takerPubkey == null)
          throw ArgumentError('takerPubkey required for reserved status');
        if (reservedAt == null)
          throw ArgumentError(
              'reservedAt required for reserved status'); // Ensure timestamp is passed
        params['taker_pubkey'] = takerPubkey;
        params['reserved_at'] = reservedAt.toUtc(); // Use passed timestamp
        setClauses.add('taker_pubkey = @taker_pubkey');
        setClauses.add('reserved_at = @reserved_at');
        break;
      case OfferStatus.blikReceived:
        if (blikCode == null)
          throw ArgumentError('blikCode required for blikReceived status');
        if (takerLightningAddress == null)
          throw ArgumentError(
              'takerLightningAddress required for blikReceived status');
        if (blikReceivedAt == null)
          throw ArgumentError(
              'blikReceivedAt required for blikReceived status'); // Ensure timestamp is passed
        params['blik_code'] = blikCode;
        params['taker_lightning_address'] = takerLightningAddress;
        params['blik_received_at'] =
            blikReceivedAt.toUtc(); // Use passed timestamp
        setClauses.add('blik_code = @blik_code');
        setClauses.add('taker_lightning_address = @taker_lightning_address');
        setClauses.add('blik_received_at = @blik_received_at');
        break;
      case OfferStatus.makerConfirmed:
        params['maker_confirmed_at'] = now;
        setClauses.add('maker_confirmed_at = @maker_confirmed_at');
        break;
      case OfferStatus.settled:
        params['settled_at'] = now;
        setClauses.add('settled_at = @settled_at');
        break;
      case OfferStatus.takerPaid:
        if (takerFees == null) {
          // Renamed check
          // Optionally throw an error, or just log a warning if fees are expected
          print(
              'Warning: Updating status to takerPaid without providing takerFees for offer $id');
        }
        params['taker_paid_at'] = now;
        params['taker_fees'] = takerFees; // Renamed parameter and column
        setClauses.add('taker_paid_at = @taker_paid_at');
        setClauses.add('taker_fees = @taker_fees'); // Renamed column
        break;
      case OfferStatus.funded: // Explicitly handle reverting to funded
      case OfferStatus.expired:
      case OfferStatus.cancelled: // Also clear fields when cancelling
        setClauses.add('taker_pubkey = NULL');
        setClauses.add('reserved_at = NULL');
        setClauses.add('blik_code = NULL');
        setClauses.add('taker_lightning_address = NULL');
        setClauses.add('blik_received_at = NULL');
        break;
      default:
        break;
    }

    print(
        '[DatabaseService.updateOfferStatus] Executing update for offer $id with status $newStatus. Params: $params');
    print(
        '[DatabaseService.updateOfferStatus] SQL: UPDATE offers SET ${setClauses.join(', ')} WHERE id = @id');

    final affectedRows = await _pool!.execute(
      'UPDATE offers SET ${setClauses.join(', ')} WHERE id = @id',
      parameters: params, // Use 'parameters'
    );
    // Return bool indicating success
    return affectedRows == 1;
  }

  // Cancel an offer (set status to cancelled) only if it's currently funded
  Future<bool> cancelOffer(String id, String makerPubkey) async {
    if (_pool == null) throw StateError('Database pool not initialized.');
    final now = DateTime.now().toUtc();
    final affectedRows = await _pool!.execute(
      // Use _pool
      '''
         UPDATE offers
         SET status = @newStatus,
             updated_at = @updated_at,
             taker_pubkey = NULL,
             reserved_at = NULL,
             blik_code = NULL,
             taker_lightning_address = NULL,
             blik_received_at = NULL
         WHERE id = @id
           AND maker_pubkey = @makerPubkey
           AND status = @requiredStatus
       ''',
      parameters: {
        // Use 'parameters'
        'id': id,
        'makerPubkey': makerPubkey,
        'newStatus': OfferStatus.cancelled.name, // Use cancelled status
        'requiredStatus': OfferStatus.funded.name,
        'updated_at': now,
      },
    );
    return affectedRows == 1;
  }

  // Fetch active offers where the user is either maker or taker
  Future<List<Offer>> getMyActiveOffers(String userPubkey) async {
    // Check _pool instead of _connection
    if (_pool == null) throw StateError('Database pool not initialized.');
    // Define "active" statuses (exclude terminal/cancelled states)
    final activeStatuses = [
      OfferStatus.created.name,
      OfferStatus.funded.name,
      OfferStatus.reserved.name,
      OfferStatus.blikReceived.name,
      OfferStatus.blikSentToMaker.name,
      OfferStatus.makerConfirmed.name,
      OfferStatus.payingTaker.name,
      OfferStatus.takerPaymentFailed.name,
      OfferStatus.takerPaid.name
    ];

    // Use pool.run and connection.execute
    final results = await _pool!.run((connection) => connection.execute(
          Sql.named('''
         SELECT * FROM offers
         WHERE (maker_pubkey = @userPubkey OR taker_pubkey = @userPubkey)
         AND status = ANY(@activeStatuses)
         ORDER BY created_at DESC
       '''), // Close Sql.named
          parameters: {
            'userPubkey': userPubkey,
            'activeStatuses': activeStatuses,
          },
        )); // Close pool.run
    return results.map(_mapRowToOffer).toList();
  }

  // Correct type hint to ResultRow
  Offer _mapRowToOffer(ResultRow row) {
    final map = row.toColumnMap();
    return Offer(
      id: map['id'],
      amountSats: map['amount_sats'],
      makerFees: map['maker_fees'], // Renamed field and column
      makerPubkey: map['maker_pubkey'],
      holdInvoicePaymentHash: map['hold_invoice_payment_hash'],
      holdInvoicePreimage: map['hold_invoice_preimage'],
      status: OfferStatus.values.byName(map['status']),
      createdAt: (map['created_at'] as DateTime).toLocal(),
      // Safely handle NUMERIC to double conversion, providing default if null
      fiatAmount: (map['fiat_amount'] as num?)?.toDouble() ?? 0.0,
      fiatCurrency: map['fiat_currency'], // Allow null currency
    )
      ..takerPubkey = map['taker_pubkey']
      ..takerLightningAddress = map['taker_lightning_address']
      ..takerInvoice = map['taker_invoice']
      ..takerInvoiceFees = map['taker_invoice_fees']
      ..blikCode = map['blik_code']
      ..updatedAt = (map['updated_at'] as DateTime?)?.toLocal()
      ..reservedAt = (map['reserved_at'] as DateTime?)?.toLocal()
      ..blikReceivedAt = (map['blik_received_at'] as DateTime?)?.toLocal()
      ..makerConfirmedAt = (map['maker_confirmed_at'] as DateTime?)?.toLocal()
      ..settledAt = (map['settled_at'] as DateTime?)?.toLocal()
      ..takerPaidAt = (map['taker_paid_at'] as DateTime?)?.toLocal()
      ..takerFees = map['taker_fees']; // Renamed field and column
  }
} // Removed extra closing brace
