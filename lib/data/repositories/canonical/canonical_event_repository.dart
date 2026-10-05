import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';

/// Mapping between domain [CanonicalEventType] and SQLite [TablesV24.economicEvents.event_type].
class CanonicalEventTypeMapper {
  static String toSql(CanonicalEventType type) {
    return switch (type) {
      CanonicalEventType.expense => 'expense',
      CanonicalEventType.income => 'income',
      CanonicalEventType.transfer => 'transfer',
      CanonicalEventType.cardPurchase => 'credit_purchase',
      CanonicalEventType.cardPayment => 'liability_settlement',
      CanonicalEventType.refund => 'refund',
      CanonicalEventType.loanDisbursement => 'loan_disbursement',
      CanonicalEventType.loanRepayment => 'loan_payment',
      CanonicalEventType.openingBalance => 'opening_balance',
      CanonicalEventType.adjustment => 'adjustment',
    };
  }

  static CanonicalEventType fromSql(String type) {
    return switch (type) {
      'expense' => CanonicalEventType.expense,
      'income' => CanonicalEventType.income,
      'transfer' => CanonicalEventType.transfer,
      'credit_purchase' => CanonicalEventType.cardPurchase,
      'liability_settlement' => CanonicalEventType.cardPayment,
      'refund' => CanonicalEventType.refund,
      'loan_disbursement' => CanonicalEventType.loanDisbursement,
      'loan_payment' => CanonicalEventType.loanRepayment,
      'opening_balance' => CanonicalEventType.openingBalance,
      'adjustment' => CanonicalEventType.adjustment,
      _ => CanonicalEventType.expense,
    };
  }
}

/// Canonical Event Repository for SpendX 2.0.
///
/// Implements the atomic persistence boundary for [EconomicEvent], [Posting],
/// and [Evidence] adhering strictly to the Draft -> Posted lifecycle and SQLite triggers.
class CanonicalEventRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalEventRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor([DatabaseExecutor? executor]) async {
    if (executor != null) return executor;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Creates a new staged draft event in `economic_events`.
  /// May optionally include initial postings and evidence.
  Future<void> createDraftEvent(
    EconomicEvent event, {
    List<Posting>? postings,
    List<Evidence>? evidence,
  }) async {
    final db = await _getExecutor();

    await _runInTransaction(db, (txn) async {
      final nowStr = event.createdAt.toUtc().toIso8601String();
      await txn.insert(TablesV24.economicEvents, {
        'id': event.id,
        'event_type': CanonicalEventTypeMapper.toSql(event.canonicalType),
        'lifecycle_status': 'draft',
        'timestamp': event.occurredAt.toUtc().toIso8601String(),
        'currency': 'INR',
        'description': event.description,
        'notes': event.metadata['notes'] as String?,
        'created_at': nowStr,
        'updated_at': nowStr,
      });

      if (postings != null && postings.isNotEmpty) {
        for (int i = 0; i < postings.length; i++) {
          final p = postings[i];
          await txn.insert(TablesV24.postings, {
            'id': p.id,
            'economic_event_id': event.id,
            'account_id': p.accountId,
            'sequence_number': i + 1,
            'direction': p.direction.name,
            'amount_minor_units': p.amount.minorUnits,
            'currency': 'INR',
            'created_at': p.createdAt.toUtc().toIso8601String(),
          });
        }
      }

      if (evidence != null && evidence.isNotEmpty) {
        for (final ev in evidence) {
          await txn.insert(TablesV24.evidence, {
            'id': ev.id,
            'economic_event_id': event.id,
            'source_type': ev.sourceType,
            'extracted_amount_minor_units':
                ev.extractedAmount?.minorUnits ?? 0,
            'extracted_timestamp': ev.sourceTimestamp.toUtc().toIso8601String(),
            'sender_address': ev.sourceIdentifier,
            'external_reference': ev.externalReference,
            'body_sha256': ev.bodyFingerprint ?? '',
            'raw_payload_encrypted': ev.rawPayloadEncrypted,
            'retention_expires_at': ev.retentionExpiresAt?.toUtc().toIso8601String(),
            'is_payload_purged': ev.isPayloadPurged ? 1 : 0,
            'created_at': ev.createdAt.toUtc().toIso8601String(),
          });
        }
      }
    });
  }

  /// Attaches postings to an existing draft event.
  /// Throws [DatabaseException] / trigger abort if event is already posted.
  Future<void> attachPostings(String eventId, List<Posting> postings) async {
    final db = await _getExecutor();

    await _runInTransaction(db, (txn) async {
      for (int i = 0; i < postings.length; i++) {
        final p = postings[i];
        await txn.insert(TablesV24.postings, {
          'id': p.id,
          'economic_event_id': eventId,
          'account_id': p.accountId,
          'sequence_number': i + 1,
          'direction': p.direction.name,
          'amount_minor_units': p.amount.minorUnits,
          'currency': 'INR',
          'created_at': p.createdAt.toUtc().toIso8601String(),
        });
      }
    });
  }

  /// Attaches a piece of evidence to an event.
  Future<void> attachEvidence(String eventId, Evidence evidence) async {
    final db = await _getExecutor();

    await db.insert(TablesV24.evidence, {
      'id': evidence.id,
      'economic_event_id': eventId,
      'source_type': evidence.sourceType,
      'extracted_amount_minor_units':
          evidence.extractedAmount?.minorUnits ?? 0,
      'extracted_timestamp': evidence.sourceTimestamp.toUtc().toIso8601String(),
      'sender_address': evidence.sourceIdentifier,
      'external_reference': evidence.externalReference,
      'body_sha256': evidence.bodyFingerprint ?? '',
      'raw_payload_encrypted': evidence.rawPayloadEncrypted,
      'retention_expires_at': evidence.retentionExpiresAt?.toUtc().toIso8601String(),
      'is_payload_purged': evidence.isPayloadPurged ? 1 : 0,
      'created_at': evidence.createdAt.toUtc().toIso8601String(),
    });
  }

  /// Inserts a standalone or pre-event piece of evidence.
  Future<void> insertEvidence(Evidence evidence, {Transaction? txn}) async {
    final db = await _getExecutor(txn);

    await db.insert(
      TablesV24.evidence,
      {
        'id': evidence.id,
        'economic_event_id': evidence.economicEventId,
        'source_type': evidence.sourceType,
        'extracted_amount_minor_units':
            evidence.extractedAmount?.minorUnits ?? 0,
        'extracted_timestamp': evidence.sourceTimestamp.toUtc().toIso8601String(),
        'sender_address': evidence.sourceIdentifier,
        'external_reference': evidence.externalReference,
        'body_sha256': evidence.bodyFingerprint ?? '',
        'raw_payload_encrypted': evidence.rawPayloadEncrypted,
        'retention_expires_at': evidence.retentionExpiresAt?.toUtc().toIso8601String(),
        'is_payload_purged': evidence.isPayloadPurged ? 1 : 0,
        'created_at': evidence.createdAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Transitions a draft event to posted status.
  /// Enforces double-entry balance via SQLite trigger `trg_economic_events_validate_posted`.
  Future<void> postEvent(String eventId) async {
    final db = await _getExecutor();

    try {
      final count = await db.update(
        TablesV24.economicEvents,
        {
          'lifecycle_status': 'posted',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ? AND lifecycle_status = ?',
        whereArgs: [eventId, 'draft'],
      );

      if (count == 0) {
        final existing = await getEvent(eventId);
        if (existing == null) {
          throw ArgumentError('EconomicEvent $eventId does not exist.');
        }
        if (existing.lifecycleStatus.isPosted) {
          return; // Already posted
        }
      }
    } on DatabaseException catch (e) {
      if (e.toString().contains('Invariant Violation')) {
        throw AccountingInvariantException(
          e.toString(),
          eventId: eventId,
        );
      }
      rethrow;
    }
  }

  /// Atomically creates and posts an [EconomicEvent] with balanced postings.
  Future<void> createAndPostEvent(
    EconomicEvent event, {
    required List<Posting> postings,
    List<Evidence>? evidence,
    EventBalanceValidator validator = const EventBalanceValidator(),
  }) async {
    // 1. In-memory domain validation before touching storage
    validator.validateOrThrow(event.id, postings);

    final db = await _getExecutor();

    await _runInTransaction(db, (txn) async {
      final nowStr = event.createdAt.toUtc().toIso8601String();

      // Step A: Insert as draft (direct insert as posted is blocked by SQLite trigger)
      await txn.insert(TablesV24.economicEvents, {
        'id': event.id,
        'event_type': CanonicalEventTypeMapper.toSql(event.canonicalType),
        'lifecycle_status': 'draft',
        'timestamp': event.occurredAt.toUtc().toIso8601String(),
        'currency': 'INR',
        'description': event.description,
        'notes': event.metadata['notes'] as String?,
        'created_at': nowStr,
        'updated_at': nowStr,
      });

      // Step B: Insert postings
      for (int i = 0; i < postings.length; i++) {
        final p = postings[i];
        await txn.insert(TablesV24.postings, {
          'id': p.id,
          'economic_event_id': event.id,
          'account_id': p.accountId,
          'sequence_number': i + 1,
          'direction': p.direction.name,
          'amount_minor_units': p.amount.minorUnits,
          'currency': 'INR',
          'created_at': p.createdAt.toUtc().toIso8601String(),
        });
      }

      // Step C: Insert evidence if provided
      if (evidence != null && evidence.isNotEmpty) {
        for (final ev in evidence) {
          await txn.insert(TablesV24.evidence, {
            'id': ev.id,
            'economic_event_id': event.id,
            'source_type': ev.sourceType,
            'extracted_amount_minor_units':
                ev.extractedAmount?.minorUnits ?? 0,
            'extracted_timestamp': ev.sourceTimestamp.toUtc().toIso8601String(),
            'sender_address': ev.sourceIdentifier,
            'external_reference': ev.externalReference,
            'body_sha256': ev.bodyFingerprint ?? '',
            'raw_payload_encrypted': ev.rawPayloadEncrypted,
            'retention_expires_at': ev.retentionExpiresAt?.toUtc().toIso8601String(),
            'is_payload_purged': ev.isPayloadPurged ? 1 : 0,
            'created_at': ev.createdAt.toUtc().toIso8601String(),
          });
        }
      }

      // Step D: Transition to posted status (SQLite trigger validates balance)
      await txn.update(
        TablesV24.economicEvents,
        {
          'lifecycle_status': 'posted',
          'updated_at': nowStr,
        },
        where: 'id = ?',
        whereArgs: [event.id],
      );
    });
  }

  /// Retrieves an [EconomicEvent] by ID, including its associated postings.
  Future<EconomicEvent?> getEvent(String id) async {
    final db = await _getExecutor();

    final eventRows = await db.query(
      TablesV24.economicEvents,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (eventRows.isEmpty) return null;

    final e = eventRows.first;
    final postings = await getPostingsForEvent(id);
    final evidence = await getEvidenceForEvent(id);

    return EconomicEvent(
      id: e['id'] as String,
      canonicalType: CanonicalEventTypeMapper.fromSql(e['event_type'] as String),
      lifecycleStatus: (e['lifecycle_status'] as String) == 'posted'
          ? EventLifecycle.posted
          : EventLifecycle.draft,
      occurredAt: DateTime.parse(e['timestamp'] as String),
      createdAt: DateTime.parse(e['created_at'] as String),
      description: e['description'] as String? ?? '',
      evidenceIds: evidence.map((ev) => ev.id).toList(),
      metadata: {
        if (e['notes'] != null) 'notes': e['notes'],
        if (e['category_id'] != null) 'category_id': e['category_id'],
      },
      postings: postings,
    );
  }

  /// Lists posted events with optional pagination and date filters.
  Future<List<EconomicEvent>> listPostedEvents({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
    int? offset,
  }) async {
    final db = await _getExecutor();

    final whereClauses = <String>["lifecycle_status = 'posted'"];
    final whereArgs = <dynamic>[];

    if (startDate != null) {
      whereClauses.add('timestamp >= ?');
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('timestamp <= ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
    }

    final rows = await db.query(
      TablesV24.economicEvents,
      where: whereClauses.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );

    final events = <EconomicEvent>[];
    for (final r in rows) {
      final id = r['id'] as String;
      final postings = await getPostingsForEvent(id);
      events.add(
        EconomicEvent(
          id: id,
          canonicalType:
              CanonicalEventTypeMapper.fromSql(r['event_type'] as String),
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: DateTime.parse(r['timestamp'] as String),
          createdAt: DateTime.parse(r['created_at'] as String),
          description: r['description'] as String? ?? '',
          postings: postings,
        ),
      );
    }
    return events;
  }

  /// Retrieves postings belonging to an economic event.
  Future<List<Posting>> getPostingsForEvent(String eventId) async {
    final db = await _getExecutor();

    final rows = await db.query(
      TablesV24.postings,
      where: 'economic_event_id = ?',
      whereArgs: [eventId],
      orderBy: 'sequence_number ASC',
    );

    return rows.map((r) {
      return Posting(
        id: r['id'] as String,
        economicEventId: r['economic_event_id'] as String,
        accountId: r['account_id'] as String,
        direction: (r['direction'] as String) == 'debit'
            ? PostingDirection.debit
            : PostingDirection.credit,
        amount: Money.fromPaise(r['amount_minor_units'] as int),
        createdAt: DateTime.parse(r['created_at'] as String),
      );
    }).toList();
  }

  /// Retrieves postings affecting a specific account (posted events only).
  Future<List<Posting>> getPostingsForAccount(
    String accountId, {
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
    int? offset,
  }) async {
    final db = await _getExecutor();

    final whereClauses = [
      'p.account_id = ?',
      "e.lifecycle_status = 'posted'",
    ];
    final whereArgs = <dynamic>[accountId];

    if (startDate != null) {
      whereClauses.add('e.timestamp >= ?');
      whereArgs.add(startDate.toUtc().toIso8601String());
    }
    if (endDate != null) {
      whereClauses.add('e.timestamp <= ?');
      whereArgs.add(endDate.toUtc().toIso8601String());
    }

    final query = '''
      SELECT p.* FROM ${TablesV24.postings} p
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE ${whereClauses.join(' AND ')}
      ORDER BY e.timestamp DESC, p.sequence_number ASC
      ${limit != null ? 'LIMIT $limit' : ''}
      ${offset != null ? 'OFFSET $offset' : ''}
    ''';

    final rows = await db.rawQuery(query, whereArgs);

    return rows.map((r) {
      return Posting(
        id: r['id'] as String,
        economicEventId: r['economic_event_id'] as String,
        accountId: r['account_id'] as String,
        direction: (r['direction'] as String) == 'debit'
            ? PostingDirection.debit
            : PostingDirection.credit,
        amount: Money.fromPaise(r['amount_minor_units'] as int),
        createdAt: DateTime.parse(r['created_at'] as String),
      );
    }).toList();
  }

  /// Retrieves evidence associated with an event.
  Future<List<Evidence>> getEvidenceForEvent(String eventId) async {
    final db = await _getExecutor();

    final rows = await db.query(
      TablesV24.evidence,
      where: 'economic_event_id = ?',
      whereArgs: [eventId],
    );

    return rows.map(_mapRowToEvidence).toList();
  }

  /// Retrieves evidence by external reference (e.g. Bank UTR / Ref ID).
  Future<Evidence?> getEvidenceByExternalReference(String ref, {Transaction? txn}) async {
    if (ref.trim().isEmpty) return null;
    final db = await _getExecutor(txn);

    final rows = await db.query(
      TablesV24.evidence,
      where: 'external_reference = ?',
      whereArgs: [ref.trim()],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToEvidence(rows.first);
  }

  /// Retrieves evidence by SHA-256 body fingerprint.
  Future<Evidence?> getEvidenceByFingerprint(String hash, {Transaction? txn}) async {
    if (hash.trim().isEmpty) return null;
    final db = await _getExecutor(txn);

    final rows = await db.query(
      TablesV24.evidence,
      where: 'body_sha256 = ?',
      whereArgs: [hash.trim()],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToEvidence(rows.first);
  }

  static Evidence _mapRowToEvidence(Map<String, dynamic> r) {
    final amt = r['extracted_amount_minor_units'] as int?;
    final expires = r['retention_expires_at'] as String?;
    return Evidence(
      id: r['id'] as String,
      sourceType: r['source_type'] as String,
      sourceIdentifier: r['sender_address'] as String?,
      sourceTimestamp: DateTime.parse(r['extracted_timestamp'] as String),
      bodyFingerprint: r['body_sha256'] as String?,
      extractedAmount: amt != null ? Money.fromPaise(amt) : null,
      externalReference: r['external_reference'] as String?,
      rawPayloadEncrypted: r['raw_payload_encrypted'] as String?,
      retentionExpiresAt: expires != null ? DateTime.parse(expires) : null,
      isPayloadPurged: (r['is_payload_purged'] as int? ?? 0) == 1,
      economicEventId: r['economic_event_id'] as String?,
      createdAt: DateTime.parse(r['created_at'] as String),
    );
  }

  Future<T> _runInTransaction<T>(
    DatabaseExecutor executor,
    Future<T> Function(Transaction txn) action,
  ) async {
    if (executor is Database) {
      return await executor.transaction(action);
    } else if (executor is Transaction) {
      return await action(executor);
    } else {
      throw UnsupportedError('Unsupported DatabaseExecutor type');
    }
  }
}
