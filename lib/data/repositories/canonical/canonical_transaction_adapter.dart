import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' hide Transaction;
import '../../../domain/finance/finance.dart';
import '../../../models/transaction.dart';
import '../../core/tables_v24.dart';

/// Bidirectional translation layer between legacy [Transaction] models
/// and canonical SpendX 2.0 double-entry [EconomicEvent], [Posting], and [Evidence].
class CanonicalTransactionAdapter {
  /// Converts a legacy monetary [double] (INR) to integer minor units (paise)
  /// using deterministic half-away-from-zero rounding.
  static int toMinorUnits(double rupees) {
    return (rupees * 100.0).round();
  }

  /// Converts integer minor units (paise) back to legacy [double] (INR).
  static double toRupees(int minorUnits) {
    return minorUnits / 100.0;
  }

  /// Computes a standard SHA-256 fingerprint for forensic evidence deduplication.
  static String computeSha256(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Deterministic normalization for text payloads (SMS, OCR, imported bodies).
  /// Trims, standardizes newlines, and collapses inline whitespace.
  static String normalizePayloadText(String text) {
    return text
        .trim()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ');
  }

  /// One shared deterministic normalization and fingerprint function for raw evidence bodies.
  /// Used for both evidence creation and duplicate lookup.
  static String computeBodyFingerprint(String rawBody) {
    return computeSha256(normalizePayloadText(rawBody));
  }

  /// Canonical serialization for manual transaction fingerprints.
  /// Handles null values, field boundaries, date formatting, and account identity explicitly.
  /// Strictly distinguishes null from literal "null" and empty strings via JSON array encoding.
  /// Does not assume a userId field exists.
  static String computeManualTransactionFingerprint({
    required String type,
    required double amount,
    required DateTime date,
    String? accountId,
    String? categoryId,
    String? notes,
  }) {
    final normType = type.trim().toLowerCase();
    final minorUnits = toMinorUnits(amount);
    final normDate = date.toUtc().toIso8601String();
    final normAcc = accountId?.trim();
    final normCat = categoryId?.trim();
    final normNotes = notes != null ? normalizePayloadText(notes) : null;

    final canonicalJson = jsonEncode([
      'manual_v1',
      normType,
      minorUnits,
      normDate,
      normAcc,
      normCat,
      normNotes,
    ]);
    return computeSha256(canonicalJson);
  }

  /// Ensures that all required account IDs referenced in [tx] exist in [TablesV24.accounts].
  /// If missing, creates minimal account records to satisfy foreign key constraints.
  static Future<void> ensureAccountsExist(
    DatabaseExecutor db,
    Transaction tx,
  ) async {
    final nowStr = DateTime.now().toIso8601String();

    Future<void> ensureAccount(
      String? id, {
      required String accountType,
      required String subtype,
      required String defaultName,
    }) async {
      if (id == null || id.isEmpty) return;
      final existing = await db.rawQuery(
        'SELECT id FROM ${TablesV24.accounts} WHERE id = ? LIMIT 1;',
        [id],
      );
      if (existing.isEmpty) {
        await db.insert(
          TablesV24.accounts,
          {
            'id': id,
            'account_type': accountType,
            'subtype': subtype,
            'name': defaultName,
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'created_at': nowStr,
            'updated_at': nowStr,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    // 1. Primary account (asset or liability)
    if (tx.source == 'credit_card_purchase' || tx.type == 'credit_card_purchase') {
      await ensureAccount(
        tx.accountId,
        accountType: 'liability',
        subtype: 'credit_card',
        defaultName: 'Credit Card',
      );
    } else {
      await ensureAccount(
        tx.accountId,
        accountType: 'asset',
        subtype: 'liquid_cash',
        defaultName: 'Bank Account',
      );
    }

    // 2. Category account (expense or income)
    if (tx.categoryId != null && tx.categoryId!.isNotEmpty) {
      final isIncome = tx.type == 'income';
      await ensureAccount(
        tx.categoryId,
        accountType: isIncome ? 'income' : 'expense',
        subtype: 'category',
        defaultName: 'Category',
      );
    }

    // 3. Related entity (destination asset or liability)
    if (tx.relatedEntityId != null && tx.relatedEntityId!.isNotEmpty) {
      if (tx.type == 'transfer') {
        await ensureAccount(
          tx.relatedEntityId,
          accountType: 'asset',
          subtype: 'liquid_cash',
          defaultName: 'Destination Account',
        );
      } else if (tx.type == 'credit_payment' ||
          tx.type == 'credit_card_payment') {
        await ensureAccount(
          tx.relatedEntityId,
          accountType: 'liability',
          subtype: 'credit_card',
          defaultName: 'Credit Card',
        );
      } else if (tx.type == 'loan_disbursement' ||
          tx.type == 'loan_repayment' ||
          tx.type == 'loan_payment') {
        await ensureAccount(
          tx.relatedEntityId,
          accountType: 'liability',
          subtype: 'loan',
          defaultName: 'Loan',
        );
      }
    }
  }

  /// Maps a legacy [Transaction] to a canonical [EconomicEvent].
  static EconomicEvent toEconomicEvent(Transaction tx) {
    final type = _resolveCanonicalType(tx);
    final nowStr = tx.createdAt.toIso8601String();

    return EconomicEvent(
      id: tx.id,
      canonicalType: type,
      lifecycleStatus: EventLifecycle.draft,
      occurredAt: tx.date,
      createdAt: tx.createdAt,
      description: tx.notes.isNotEmpty ? tx.notes : tx.type,
      metadata: {
        'user_id': tx.userId,
        'notes': tx.notes,
        'tags': tx.tags,
        'source': tx.source,
        if (tx.externalRef != null) 'external_ref': tx.externalRef,
        if (tx.location != null) 'location': tx.location,
        if (tx.accountId != null) 'account_id': tx.accountId,
        if (tx.categoryId != null) 'category_id': tx.categoryId,
        if (tx.relatedEntityId != null) 'related_entity_id': tx.relatedEntityId,
        if (tx.interestAmount != null) 'interest_amount': tx.interestAmount,
        'created_at': nowStr,
        'updated_at': tx.updatedAt.toIso8601String(),
      },
    );
  }

  /// Generates the balanced double-entry [Posting] legs for a [Transaction].
  static List<Posting> toPostings(Transaction tx, {required String eventId}) {
    final amountMinor = toMinorUnits(tx.amount);
    final money = Money.fromPaise(amountMinor);
    final now = tx.createdAt;
    final type = _resolveCanonicalType(tx);

    switch (type) {
      case CanonicalEventType.expense:
        final catId = (tx.categoryId != null && tx.categoryId!.isNotEmpty)
            ? tx.categoryId!
            : TablesV24.sysExpMisc;
        final assetId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: catId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: assetId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.income:
        final assetId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        final catId = (tx.categoryId != null && tx.categoryId!.isNotEmpty)
            ? tx.categoryId!
            : TablesV24.sysIncMisc;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: assetId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: catId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.transfer:
        final fromId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        final toId = (tx.relatedEntityId != null && tx.relatedEntityId!.isNotEmpty)
            ? tx.relatedEntityId!
            : TablesV24.sysSuspenseTransfer;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: toId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: fromId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.cardPurchase:
        final catId = (tx.categoryId != null && tx.categoryId!.isNotEmpty)
            ? tx.categoryId!
            : TablesV24.sysExpMisc;
        final cardId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseCard;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: catId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: cardId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.cardPayment:
        final cardId = (tx.relatedEntityId != null && tx.relatedEntityId!.isNotEmpty)
            ? tx.relatedEntityId!
            : TablesV24.sysSuspenseCard;
        final bankId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: cardId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: bankId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.refund:
        final bankId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        final catId = (tx.categoryId != null && tx.categoryId!.isNotEmpty)
            ? tx.categoryId!
            : TablesV24.sysExpRefunds;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: bankId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: catId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.loanDisbursement:
        final bankId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        final loanId = (tx.relatedEntityId != null && tx.relatedEntityId!.isNotEmpty)
            ? tx.relatedEntityId!
            : TablesV24.sysSuspenseLoan;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: bankId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: loanId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      case CanonicalEventType.loanRepayment:
        final bankId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        final loanId = (tx.relatedEntityId != null && tx.relatedEntityId!.isNotEmpty)
            ? tx.relatedEntityId!
            : TablesV24.sysSuspenseLoan;

        // Structured interestAmount takes strict precedence over free-text notes
        ({int principalMinor, int interestMinor})? split;
        if (tx.interestAmount != null) {
          final interestMinor = toMinorUnits(tx.interestAmount!);
          if (interestMinor < 0 || interestMinor > amountMinor) {
            throw ArgumentError(
              'Invalid interestAmount: ₹${tx.interestAmount} cannot be negative or exceed total repayment amount of ₹${tx.amount}',
            );
          }
          final principalMinor = amountMinor - interestMinor;
          split = (
            principalMinor: principalMinor,
            interestMinor: interestMinor,
          );
        } else {
          split = _parseLoanSplit(tx.notes, amountMinor);
        }
        if (split != null && split.interestMinor > 0) {
          final postings = <Posting>[];
          if (split.principalMinor > 0) {
            postings.add(
              Posting(
                id: 'pst_${eventId}_1',
                economicEventId: eventId,
                accountId: loanId,
                direction: PostingDirection.debit,
                amount: Money.fromPaise(split.principalMinor),
                createdAt: now,
              ),
            );
          }
          postings.add(
            Posting(
              id: 'pst_${eventId}_2',
              economicEventId: eventId,
              accountId: TablesV24.sysExpInterest,
              direction: PostingDirection.debit,
              amount: Money.fromPaise(split.interestMinor),
              createdAt: now,
            ),
          );
          postings.add(
            Posting(
              id: 'pst_${eventId}_3',
              economicEventId: eventId,
              accountId: bankId,
              direction: PostingDirection.credit,
              amount: money,
              createdAt: now,
            ),
          );
          return postings;
        }

        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: loanId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: bankId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];

      default:
        // Default 2-leg balanced fallback
        final assetId = (tx.accountId != null && tx.accountId!.isNotEmpty)
            ? tx.accountId!
            : TablesV24.sysSuspenseTransfer;
        final catId = (tx.categoryId != null && tx.categoryId!.isNotEmpty)
            ? tx.categoryId!
            : TablesV24.sysExpMisc;
        return [
          Posting(
            id: 'pst_${eventId}_1',
            economicEventId: eventId,
            accountId: catId,
            direction: PostingDirection.debit,
            amount: money,
            createdAt: now,
          ),
          Posting(
            id: 'pst_${eventId}_2',
            economicEventId: eventId,
            accountId: assetId,
            direction: PostingDirection.credit,
            amount: money,
            createdAt: now,
          ),
        ];
    }
  }

  /// Generates forensic [Evidence] for [tx].
  static Evidence? toEvidence(
    Transaction tx, {
    required String eventId,
    String? rawPayload,
  }) {
    final effectivePayload = rawPayload ?? tx.rawPayload;
    final hasExternalRef = tx.externalRef != null && tx.externalRef!.trim().isNotEmpty;
    final hasPayload = effectivePayload != null && effectivePayload.trim().isNotEmpty;

    if (!hasExternalRef && !hasPayload) return null;

    const allowed = {
      'sms',
      'ocr',
      'manual',
      'import_csv',
      'backup',
      'system',
      'migration_v24_reconciliation',
      'migration_v24_unbacked_balance',
    };
    final resolvedSource = allowed.contains(tx.source)
        ? tx.source
        : (tx.source == 'review' ? 'sms' : 'manual');

    final String fingerprint;
    if (hasPayload) {
      fingerprint = computeBodyFingerprint(effectivePayload);
    } else if (resolvedSource == 'manual') {
      fingerprint = computeManualTransactionFingerprint(
        type: tx.type,
        amount: tx.amount,
        date: tx.date,
        accountId: tx.accountId,
        categoryId: tx.categoryId,
        notes: tx.notes,
      );
    } else if (hasExternalRef) {
      fingerprint = computeSha256(tx.externalRef!);
    } else {
      fingerprint = computeSha256('tx_$eventId');
    }

    return Evidence(
      id: 'evi_$eventId',
      economicEventId: eventId,
      sourceType: resolvedSource,
      sourceIdentifier: tx.userId,
      sourceTimestamp: tx.date,
      extractedAmount: Money.fromPaise(toMinorUnits(tx.amount)),
      externalReference: tx.externalRef,
      bodyFingerprint: fingerprint,
      rawPayloadEncrypted: hasPayload ? effectivePayload : null,
      createdAt: tx.createdAt,
    );
  }

  /// Projects a canonical [EconomicEvent] and its [postings] back to a legacy [Transaction].
  static Transaction toTransaction(
    EconomicEvent event,
    List<Posting> postings, {
    Evidence? evidence,
    bool isReversed = false,
  }) {
    final meta = event.metadata;
    final totalMinor = postings.isEmpty
        ? 0
        : postings
            .where((p) => p.direction == PostingDirection.debit)
            .fold<int>(0, (sum, p) => sum + p.amount.minorUnits);
    final amountRupees = toRupees(totalMinor > 0 ? totalMinor : 0);

    String typeStr = 'expense';
    String? accountId = meta['account_id'] as String?;
    String? categoryId = meta['category_id'] as String?;
    String? relatedEntityId = meta['related_entity_id'] as String?;

    switch (event.canonicalType) {
      case CanonicalEventType.income:
        typeStr = 'income';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.debit,
              orElse: () => postings.first,
            )
            .accountId;
        if (postings.length > 1) {
          categoryId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.credit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;

      case CanonicalEventType.transfer:
        typeStr = 'transfer';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.credit,
              orElse: () => postings.first,
            )
            .accountId;
        if (postings.length > 1) {
          relatedEntityId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.debit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;

      case CanonicalEventType.cardPurchase:
        typeStr = 'credit_card_purchase';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.credit,
              orElse: () => postings.first,
            )
            .accountId;
        if (postings.length > 1) {
          categoryId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.debit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;

      case CanonicalEventType.cardPayment:
        typeStr = 'credit_payment';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.credit,
              orElse: () => postings.first,
            )
            .accountId;
        if (postings.length > 1) {
          relatedEntityId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.debit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;

      case CanonicalEventType.refund:
        typeStr = 'refund';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.debit,
              orElse: () => postings.first,
            )
            .accountId;
        if (postings.length > 1) {
          categoryId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.credit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;

      case CanonicalEventType.loanDisbursement:
        typeStr = 'loan_disbursement';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.debit,
              orElse: () => postings.first,
            )
            .accountId;
        if (postings.length > 1) {
          relatedEntityId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.credit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;

      case CanonicalEventType.loanRepayment:
        typeStr = 'loan_repayment';
        accountId ??= postings
            .firstWhere(
              (p) => p.direction == PostingDirection.credit,
              orElse: () => postings.first,
            )
            .accountId;
        relatedEntityId ??= meta['loan_id'] as String?;
        if (postings.length > 1) {
          final debitPosting = postings.firstWhere(
            (p) =>
                p.direction == PostingDirection.debit &&
                p.accountId != TablesV24.sysExpInterest,
            orElse: () => postings.firstWhere(
              (p) => p.direction == PostingDirection.debit,
              orElse: () => postings.last,
            ),
          );
          relatedEntityId ??= debitPosting.accountId;
        }
        break;

      case CanonicalEventType.openingBalance:
        typeStr = 'opening_balance';
        if (postings.isNotEmpty) {
          accountId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.debit,
                orElse: () => postings.first,
              )
              .accountId;
        }
        break;

      default:
        typeStr = 'expense';
        if (postings.isNotEmpty) {
          accountId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.credit,
                orElse: () => postings.first,
              )
              .accountId;
        }
        if (postings.length > 1) {
          categoryId ??= postings
              .firstWhere(
                (p) => p.direction == PostingDirection.debit,
                orElse: () => postings.last,
              )
              .accountId;
        }
        break;
    }

    final extRef = evidence?.externalReference ?? meta['external_ref'] as String?;
    final tagsRaw = meta['tags'];
    List<String> tags = const [];
    if (tagsRaw is List) {
      tags = tagsRaw.map((e) => e.toString()).toList();
    }

    // Detect structured interest debit leg from canonical postings, or fallback to metadata
    Posting? interestPosting;
    for (final p in postings) {
      if (p.accountId == TablesV24.sysExpInterest && p.direction == PostingDirection.debit) {
        interestPosting = p;
        break;
      }
    }
    final double? interestAmount = interestPosting != null
        ? interestPosting.amount.toRupees
        : (meta['interest_amount'] is num
            ? (meta['interest_amount'] as num).toDouble()
            : null);

    return Transaction(
      id: event.id,
      userId: meta['user_id'] as String? ?? 'offline_user',
      type: typeStr,
      categoryId: categoryId,
      accountId: accountId,
      amount: amountRupees,
      date: event.occurredAt,
      notes: meta['notes'] as String? ?? event.description,
      tags: tags,
      source: meta['source'] as String? ??
          (event.canonicalType == CanonicalEventType.cardPayment
              ? 'credit_card_payment'
              : 'manual'),
      relatedEntityId: relatedEntityId,
      externalRef: extRef,
      location: meta['location'] as String?,
      isDeleted: isReversed || event.description.startsWith('REVERSAL:'),
      interestAmount: interestAmount,
      createdAt: event.createdAt,
      updatedAt: meta['updated_at'] != null
          ? DateTime.tryParse(meta['updated_at'] as String) ?? event.createdAt
          : event.createdAt,
    );
  }

  /// Creates a balanced reversal event negating [originalEvent].
  static ({EconomicEvent event, List<Posting> postings}) createReversal(
    EconomicEvent originalEvent,
    List<Posting> originalPostings, {
    String? reason,
  }) {
    final reversalId =
        'rev_${originalEvent.id}_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();

    final reversalEvent = EconomicEvent(
      id: reversalId,
      canonicalType: CanonicalEventType.adjustment,
      lifecycleStatus: EventLifecycle.draft,
      occurredAt: originalEvent.occurredAt,
      createdAt: now,
      description:
          'REVERSAL: ${originalEvent.id}${reason != null ? " - $reason" : ""}',
      reversalOfEventId: originalEvent.id,
      metadata: {
        'reversal_of': originalEvent.id,
        'reversal_of_event_id': originalEvent.id,
        'reason': reason ?? 'Transaction deletion/correction',
        'is_reversal': true,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
    );

    final reversalPostings = <Posting>[];
    for (int i = 0; i < originalPostings.length; i++) {
      final p = originalPostings[i];
      // Invert direction: debit becomes credit, credit becomes debit
      final inverted = p.direction == PostingDirection.debit
          ? PostingDirection.credit
          : PostingDirection.debit;
      reversalPostings.add(
        Posting(
          id: 'pst_${reversalId}_${i + 1}',
          economicEventId: reversalId,
          accountId: p.accountId,
          direction: inverted,
          amount: p.amount,
          createdAt: now,
        ),
      );
    }

    return (event: reversalEvent, postings: reversalPostings);
  }

  static CanonicalEventType _resolveCanonicalType(Transaction tx) {
    if (tx.type == 'credit_payment' || tx.type == 'credit_card_payment') {
      return CanonicalEventType.cardPayment;
    }
    if (tx.type == 'refund') {
      return CanonicalEventType.refund;
    }
    if (tx.source == 'credit_card_purchase' || tx.type == 'credit_card_purchase') {
      return CanonicalEventType.cardPurchase;
    }
    return switch (tx.type) {
      'income' => CanonicalEventType.income,
      'transfer' => CanonicalEventType.transfer,
      'credit_card_purchase' => CanonicalEventType.cardPurchase,
      'credit_payment' || 'credit_card_payment' => CanonicalEventType.cardPayment,
      'refund' => CanonicalEventType.refund,
      'loan_disbursement' => CanonicalEventType.loanDisbursement,
      'loan_repayment' => CanonicalEventType.loanRepayment,
      'loan_payment' => CanonicalEventType.loanRepayment,
      _ => CanonicalEventType.expense,
    };
  }

  static ({int principalMinor, int interestMinor})? _parseLoanSplit(
    String notes,
    int totalMinor,
  ) {
    try {
      final principalMatch =
          RegExp(r'Principal:\s*([\d\.]+)').firstMatch(notes);
      final interestMatch =
          RegExp(r'Interest:\s*([\d\.]+)').firstMatch(notes);
      if (principalMatch != null && interestMatch != null) {
        final p = double.parse(principalMatch.group(1)!);
        final i = double.parse(interestMatch.group(1)!);
        return (
          principalMinor: toMinorUnits(p),
          interestMinor: toMinorUnits(i),
        );
      }
    } catch (_) {}
    return null;
  }
}
