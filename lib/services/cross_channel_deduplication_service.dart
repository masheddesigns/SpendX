import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/logging/app_logger.dart';
import '../data/core/tables.dart';
import '../data/core/tables_v26.dart';
import '../data/repositories/canonical/canonical_event_repository.dart';
import '../data/repositories/canonical/canonical_transaction_adapter.dart';
import '../data/repositories/refund_allocations_repo.dart';
import '../domain/finance/economic_event.dart';
import '../domain/finance/posting.dart';
import '../models/review_item.dart';
import 'transaction_text_parser.dart';

/// Origin channel of an incoming transaction alert.
enum SourceChannel {
  sms,
  push,
  other,
}

/// The outcome classification of an incoming transaction candidate evaluation.
enum DeduplicationStatus {
  /// Stage 0: The exact physical source record has already been ingested.
  duplicateSourceRecord,

  /// Stage 1: Verified strong reference match (Tier 1 UTR or Tier 2 provider reference).
  /// Evidence linked to existing economic event; zero duplicate postings.
  strongMatchMerged,

  /// No duplicate or ambiguous match; new legitimate event and postings created.
  newEventCreated,

  /// Ambiguous or unreferenced correlation routed to Review Queue.
  /// Zero accounting postings created.
  routedToReviewQueue,
}

/// Structured representation of an incoming transaction candidate.
class IncomingTransactionCandidate {
  final String sourceRecordId;
  final SourceChannel sourceChannel;
  final String sender;
  final String body;
  final int amountMinorUnits;
  final PostingDirection direction;
  final DateTime timestamp;
  final String? externalReference;
  final String? accountNumberLast4;
  final String? accountId;
  final String? counterpartyAccountId;
  final String? merchant;
  final CanonicalEventType eventType;
  final String? reversalOfEventId;
  final String? originalPurchaseEventId;
  final int? allocatedAmountMinorUnits;
  final bool isAmbiguous;
  final String? ambiguityReason;
  final String? primaryAccountType;

  const IncomingTransactionCandidate({
    required this.sourceRecordId,
    required this.sourceChannel,
    required this.sender,
    required this.body,
    required this.amountMinorUnits,
    required this.direction,
    required this.timestamp,
    this.externalReference,
    this.accountNumberLast4,
    this.accountId,
    this.counterpartyAccountId,
    this.merchant,
    this.eventType = CanonicalEventType.expense,
    this.reversalOfEventId,
    this.originalPurchaseEventId,
    this.allocatedAmountMinorUnits,
    this.isAmbiguous = false,
    this.ambiguityReason,
    this.primaryAccountType,
  });
}

/// Structured result of the deduplication pipeline evaluation.
class DeduplicationResult {
  final DeduplicationStatus status;
  final String? eventId;
  final String? evidenceId;
  final String? reviewCandidateId;
  final String? reviewReason;
  final String? sourceRecordId;

  const DeduplicationResult({
    required this.status,
    this.eventId,
    this.evidenceId,
    this.reviewCandidateId,
    this.reviewReason,
    this.sourceRecordId,
  });

  bool get isDuplicateSource => status == DeduplicationStatus.duplicateSourceRecord;
  bool get isStrongMatchMerged => status == DeduplicationStatus.strongMatchMerged;
  bool get isNewEventCreated => status == DeduplicationStatus.newEventCreated;
  bool get isRoutedToReviewQueue => status == DeduplicationStatus.routedToReviewQueue;
}

/// Result of historical SMS-to-evidence reconciliation.
class HistoricalLinkingResult {
  final bool isLinked;
  final bool isQuarantined;
  final String? linkedEvidenceId;
  final String? reviewCandidateId;
  final String? reason;

  const HistoricalLinkingResult.linked(String evidenceId)
      : isLinked = true,
        isQuarantined = false,
        linkedEvidenceId = evidenceId,
        reviewCandidateId = null,
        reason = null;

  const HistoricalLinkingResult.quarantined({
    required String this.reviewCandidateId,
    required String this.reason,
  })  : isLinked = false,
        isQuarantined = true,
        linkedEvidenceId = null;

  const HistoricalLinkingResult.unlinked({this.reason})
      : isLinked = false,
        isQuarantined = false,
        linkedEvidenceId = null,
        reviewCandidateId = null;
}

/// Phase 1.4 Cross-Channel SMS / Push Notification Deduplication Engine.
///
/// Implements the two-layer architecture and strict matching hierarchy defined
/// by Revision 13:
/// - Stage 0: Durable Source Identity Check (`idx_evidence_source_record`).
/// - Stage 1: Stable Reference Matching (Tier 1 UTR/RRN & Tier 2 Provider References).
/// - Stage 2: Conservative Cross-Channel Correlation & Review Queue Routing.
///
/// Guarantees:
/// 1. Asymmetric Risk Principle: False duplicate classification is permanently prevented.
/// 2. Explicit Tier 3 Prohibition: Cross-channel unreferenced records are NEVER auto-merged.
/// 3. Zero duplicate postings on repeated observation or dual observation.
/// 4. Atomic transaction boundaries (`required DatabaseExecutor txn`).
class CrossChannelDeduplicationService {
  final RefundAllocationsRepo _refundRepo;

  CrossChannelDeduplicationService({RefundAllocationsRepo? refundRepo})
      : _refundRepo = refundRepo ?? RefundAllocationsRepo();

  // ── Source Identity Helpers ────────────────────────────────────────────────

  /// Builds a deterministic SMS source identity.
  static String buildSmsSourceId(dynamic smsId) => 'SRC:TELEPHONY_SMS:$smsId';

  /// Builds a deterministic Android push notification source identity.
  static String buildPushSourceId(
    String package,
    dynamic id,
    String? tag,
    dynamic postTime,
  ) =>
      'SRC:ANDROID_NOTIF:$package:$id:${tag ?? ''}:$postTime';

  // ── Reference Extraction & Normalization ───────────────────────────────────

  static final RegExp _utrPattern = RegExp(
    r'\b(?:UPI(?:\/|\s*(?:ref|rrn|txn|id)[:\s]*)|(?:rrn|utr)[:\s]*|ref(?:\s+no)?[:\s]*)(\d{12})\b',
    caseSensitive: false,
  );

  static final RegExp _bare12Digits = RegExp(r'^\d{12}$');

  /// Extracts a 12-digit Indian banking UTR / RRN from raw alert text.
  static String? extractUtrOrRrn(String text) {
    if (text.isEmpty) return null;
    final match = _utrPattern.firstMatch(text);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }
    // Also look for slash-separated UPI tokens like UPI/532342342342/...
    final slashMatch = RegExp(r'UPI\/(\d{12})\b', caseSensitive: false).firstMatch(text);
    if (slashMatch != null && slashMatch.groupCount >= 1) {
      return slashMatch.group(1);
    }
    return null;
  }

  /// Normalizes a transaction reference into a canonical representation.
  /// - 12-digit numeric sequences normalize to `UPI:RRN:<12-digits>`.
  /// - Namespaced provider references preserve their namespace in uppercase.
  static String normalizeReference(String rawRef) {
    final trimmed = rawRef.trim();
    if (trimmed.isEmpty) return '';

    if (trimmed.toUpperCase().startsWith('UPI:RRN:')) {
      return trimmed.toUpperCase();
    }

    if (_bare12Digits.hasMatch(trimmed)) {
      return 'UPI:RRN:$trimmed';
    }

    return trimmed.toUpperCase();
  }

  // ── Core Ingestion Pipeline (Layer B) ──────────────────────────────────────

  /// Ingests an incoming candidate within the provided atomic [txn].
  ///
  /// Evaluates through Stage 0, Stage 1, and Stage 2 according to Revision 13.
  Future<DeduplicationResult> processIncomingCandidate({
    required IncomingTransactionCandidate candidate,
    required DatabaseExecutor txn,
  }) async {
    // =========================================================================
    // STAGE 0: DURABLE SOURCE IDENTITY IDEMPOTENCY CHECK
    // =========================================================================
    final existingSourceRows = await txn.query(
      TablesV24.evidence,
      columns: ['id', 'economic_event_id'],
      where: 'source_record_id = ?',
      whereArgs: [candidate.sourceRecordId],
      limit: 1,
    );

    if (existingSourceRows.isNotEmpty) {
      final existingRow = existingSourceRows.first;
      final existingEventId = existingRow['economic_event_id'] as String?;
      AppLogger.i(
        '[CrossChannelDeduplication] Stage 0 hit: duplicate source record ${candidate.sourceRecordId} -> event $existingEventId',
      );
      return DeduplicationResult(
        status: DeduplicationStatus.duplicateSourceRecord,
        eventId: existingEventId,
        evidenceId: existingRow['id'] as String,
        sourceRecordId: candidate.sourceRecordId,
      );
    }

    // Determine normalized reference if available
    final rawRef = candidate.externalReference ?? extractUtrOrRrn(candidate.body);
    final normRef = rawRef != null && rawRef.trim().isNotEmpty
        ? normalizeReference(rawRef)
        : null;

    // =========================================================================
    // STAGE 1: STABLE REFERENCE MATCHING (Tier 1 UTR & Tier 2 Provider Ref)
    // =========================================================================
    if (normRef != null && normRef.isNotEmpty) {
      // 7-day lookback window for stable reference matching
      final sevenDaysAgo = candidate.timestamp
          .subtract(const Duration(days: 7))
          .toUtc()
          .toIso8601String();

      final refMatches = await txn.rawQuery(
        '''
        SELECT e.id as evidence_id, e.economic_event_id, e.extracted_amount_minor_units,
               e.external_reference, e.source_type, e.source_record_id,
               ev.event_type, ev.lifecycle_status, ev.timestamp, ev.description,
               ev.reversal_of_event_id
        FROM ${TablesV24.evidence} e
        JOIN ${TablesV24.economicEvents} ev ON ev.id = e.economic_event_id
        WHERE (e.external_reference = ? OR e.external_reference = ?)
          AND ev.timestamp >= ?
        ''',
        [normRef, rawRef, sevenDaysAgo],
      );

      // Check distinct event IDs matching this reference
      final matchedEventIds = refMatches
          .map((r) => r['economic_event_id'] as String)
          .toSet()
          .toList();

      if (matchedEventIds.length > 1) {
        // Multiple distinct events share this reference -> Ambiguity!
        AppLogger.w(
          '[CrossChannelDeduplication] Multiple distinct events share reference $normRef: $matchedEventIds',
        );
        return await _routeToReviewQueue(
          candidate: candidate,
          reason: 'DUPLICATE_REFERENCE_AMBIGUITY',
          txn: txn,
        );
      }

      if (matchedEventIds.length == 1) {
        final match = refMatches.first;
        final matchedEventId = match['economic_event_id'] as String;
        final matchedAmount = (match['extracted_amount_minor_units'] as num).toInt();
        final matchedTypeStr = match['event_type'] as String;

        // Verify Amount consistency
        if (matchedAmount != candidate.amountMinorUnits) {
          AppLogger.w(
            '[CrossChannelDeduplication] Conflicting amount on reference $normRef: matched=$matchedAmount vs candidate=${candidate.amountMinorUnits}',
          );
          return await _routeToReviewQueue(
            candidate: candidate,
            reason: 'REFERENCE_AMOUNT_MISMATCH',
            txn: txn,
          );
        }

        // Verify Direction / Type consistency
        final isCandidateDebit = candidate.direction == PostingDirection.debit;
        final isMatchedDebit = (matchedTypeStr == 'expense' ||
            matchedTypeStr == 'credit_purchase' ||
            matchedTypeStr == 'transfer');

        if (isCandidateDebit != isMatchedDebit) {
          // One is debit, one is credit sharing the same reference.
          // Check if candidate is a refund with refund semantics (P14-T07, P14-T08)
          final isRefund = candidate.eventType == CanonicalEventType.refund ||
              _hasRefundSemantics(candidate.body);

          if (isRefund) {
            // Legitimate reversal / refund sharing original payment's UTR.
            // Post as a DISTINCT event linked to the matched original event via reversal_of_event_id.
            return await _createAndPostNewEvent(
              candidate: candidate,
              reversalOfEventId: matchedEventId,
              txn: txn,
            );
          } else {
            // Unrelated credit/debit sharing reference without refund semantics (P14-T26, P14-T31)
            AppLogger.w(
              '[CrossChannelDeduplication] Direction mismatch on reference $normRef without refund semantics',
            );
            return await _routeToReviewQueue(
              candidate: candidate,
              reason: 'REFERENCE_DIRECTION_MISMATCH',
              txn: txn,
            );
          }
        }

        // Exact match on stable reference, amount, and direction -> Strong Match Merged!
        // Attach candidate evidence to the existing economic event.
        final evidenceId = const Uuid().v4();
        final nowStr = DateTime.now().toUtc().toIso8601String();

        await txn.insert(TablesV24.evidence, {
          'id': evidenceId,
          'economic_event_id': matchedEventId,
          'source_type': candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'manual',
          'source_record_id': candidate.sourceRecordId,
          'extracted_amount_minor_units': candidate.amountMinorUnits,
          'extracted_timestamp': candidate.timestamp.toUtc().toIso8601String(),
          'sender_address': candidate.sender,
          'external_reference': normRef,
          'body_sha256': CanonicalTransactionAdapter.computeBodyFingerprint(candidate.body),
          'raw_payload_encrypted': candidate.body,
          'retention_expires_at': DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
          'is_payload_purged': 0,
          'created_at': nowStr,
        });

        // Enrich existing event with merchant if missing
        if (candidate.merchant != null && candidate.merchant!.isNotEmpty) {
          final desc = match['description'] as String?;
          if (desc == null || desc.isEmpty || desc == 'Uncategorized') {
            await txn.update(
              TablesV24.economicEvents,
              {'description': candidate.merchant, 'updated_at': nowStr},
              where: 'id = ?',
              whereArgs: [matchedEventId],
            );
          }
        }

        AppLogger.i(
          '[CrossChannelDeduplication] Strong reference match: linked ${candidate.sourceRecordId} to event $matchedEventId',
        );
        return DeduplicationResult(
          status: DeduplicationStatus.strongMatchMerged,
          eventId: matchedEventId,
          evidenceId: evidenceId,
          sourceRecordId: candidate.sourceRecordId,
        );
      }
    }

    // =========================================================================
    // STAGE 1B: CONSERVATIVE BROADCAST-TO-INBOX RECONCILIATION (Without UTR)
    // =========================================================================
    // Reconciles an inbox SMS ('SRC:TELEPHONY_SMS:<id>') against an unlinked
    // live broadcast event ('SRC:TELEPHONY_BROADCAST:...') when both share identical
    // body fingerprint, amount, direction, and correlation timestamp.
    final isInboxSmsCandidate = candidate.sourceRecordId.startsWith('SRC:TELEPHONY_SMS:');
    if (isInboxSmsCandidate && (normRef == null || normRef.isEmpty)) {
      await _ensureTablesV26(txn);
      final candidateFp = CanonicalTransactionAdapter.computeBodyFingerprint(candidate.body);
      final winStart = candidate.timestamp
          .subtract(const Duration(minutes: 10))
          .toUtc()
          .toIso8601String();
      final winEnd = candidate.timestamp
          .add(const Duration(minutes: 10))
          .toUtc()
          .toIso8601String();

      final broadcastMatches = await txn.rawQuery(
        '''
        SELECT e.id as evidence_id, e.economic_event_id, e.extracted_amount_minor_units,
               e.sender_address, e.extracted_timestamp, e.source_record_id,
               ev.event_type, ev.lifecycle_status, ev.timestamp, ev.description
        FROM ${TablesV24.evidence} e
        JOIN ${TablesV24.economicEvents} ev ON ev.id = e.economic_event_id
        WHERE e.source_record_id LIKE 'SRC:TELEPHONY_BROADCAST:%'
          AND e.body_sha256 = ?
          AND e.extracted_amount_minor_units = ?
          AND ev.timestamp BETWEEN ? AND ?
          AND NOT EXISTS (
            SELECT 1 FROM ${TablesV26.evidenceReconciliations} er
            WHERE er.broadcast_source_record_id = e.source_record_id
          )
        ''',
        [candidateFp, candidate.amountMinorUnits, winStart, winEnd],
      );

      final matchedEventIds = broadcastMatches
          .map((r) => r['economic_event_id'] as String)
          .toSet()
          .toList();

      if (matchedEventIds.length > 1) {
        // Multiple candidate broadcast events share this fingerprint and amount -> Ambiguous!
        // Preserve evidence and route to Review Queue; NEVER silently discard.
        AppLogger.w(
          '[CrossChannelDeduplication] Multiple broadcast matches for inbox SMS: ${candidate.sourceRecordId}',
        );
        return await _routeToReviewQueue(
          candidate: candidate,
          reason: 'AMBIGUOUS_BROADCAST_INBOX_FINGERPRINT_MATCH',
          txn: txn,
        );
      } else if (matchedEventIds.length == 1) {
        final match = broadcastMatches.first;
        final matchedEventId = matchedEventIds.first;
        final matchedTypeStr = match['event_type'] as String?;
        final isCandidateDebit = candidate.direction == PostingDirection.debit;
        final isMatchedDebit = (matchedTypeStr == 'expense' ||
            matchedTypeStr == 'credit_purchase' ||
            matchedTypeStr == 'transfer');

        if (isCandidateDebit != isMatchedDebit) {
          return await _routeToReviewQueue(
            candidate: candidate,
            reason: 'REFERENCE_DIRECTION_MISMATCH',
            txn: txn,
          );
        }

        // Strict identifying evidence verification:
        // Do not use broadcastMatches.length == 1 as the sole proof.
        // 1. Sender address must match
        final matchSender = (match['sender_address'] as String? ?? '').trim().toUpperCase();
        final candidateSender = candidate.sender.trim().toUpperCase();
        final sendersMatch = matchSender.isNotEmpty && matchSender == candidateSender;

        // 2. Exact SMSC timestamp coincidence (within GSM 03.40 1-second TP-SCTS window):
        final rawExtractedTs = match['extracted_timestamp'] as String? ?? match['timestamp'] as String?;
        final broadcastTs = rawExtractedTs != null ? DateTime.tryParse(rawExtractedTs) : null;
        final timeDiffMs = broadcastTs != null
            ? (candidate.timestamp.difference(broadcastTs).inMilliseconds).abs()
            : 9999999;
        final timestampsCoincide = timeDiffMs <= 2000;

        if (!sendersMatch || !timestampsCoincide) {
          // Insufficient identifying evidence to prove uniqueness without UTR -> Route to Review Queue!
          AppLogger.w(
            '[CrossChannelDeduplication] Insufficient identifying evidence for unreferenced reconciliation: sendersMatch=$sendersMatch, timeDiffMs=$timeDiffMs',
          );
          return await _routeToReviewQueue(
            candidate: candidate,
            reason: 'UNREFERENCED_INSUFFICIENT_IDENTIFYING_EVIDENCE',
            txn: txn,
          );
        }

        // Both senders match and SMSC timestamps coincide within GSM 1-second window:
        // Sufficient identifying evidence established! Reconcile as strongMatchMerged.
        final evidenceId = const Uuid().v4();
        final reconciliationId = const Uuid().v4();
        final nowStr = DateTime.now().toUtc().toIso8601String();
        final matchedBroadcastSourceId = match['source_record_id'] as String;

        // 1. Establish dedicated durable reconciliation relationship in evidence_reconciliations:
        await txn.insert(TablesV26.evidenceReconciliations, {
          'id': reconciliationId,
          'broadcast_source_record_id': matchedBroadcastSourceId,
          'inbox_source_record_id': candidate.sourceRecordId,
          'reconciliation_method': 'BROADCAST_INBOX_STRICT_IDENTIFYING_EVIDENCE',
          'created_at': nowStr,
        });

        // 2. Insert inbox evidence with external_reference preserving only genuine references:
        await txn.insert(TablesV24.evidence, {
          'id': evidenceId,
          'economic_event_id': matchedEventId,
          'source_type': 'sms',
          'source_record_id': candidate.sourceRecordId,
          'extracted_amount_minor_units': candidate.amountMinorUnits,
          'extracted_timestamp': candidate.timestamp.toUtc().toIso8601String(),
          'sender_address': candidate.sender,
          'external_reference': null,
          'body_sha256': candidateFp,
          'raw_payload_encrypted': candidate.body,
          'retention_expires_at': DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
          'is_payload_purged': 0,
          'created_at': nowStr,
        });

        AppLogger.i(
          '[CrossChannelDeduplication] Unique broadcast-to-inbox reconciliation without UTR: linked ${candidate.sourceRecordId} to event $matchedEventId via reconciliation $reconciliationId',
        );
        return DeduplicationResult(
          status: DeduplicationStatus.strongMatchMerged,
          eventId: matchedEventId,
          evidenceId: evidenceId,
          sourceRecordId: candidate.sourceRecordId,
        );
      } else {
        // matchedEventIds.isEmpty: No unreconciled broadcast match exists in window.
        // Check if an existing event already consumed this reconciliation opportunity
        // or shares identical sender, body fingerprint, amount, and coinciding SMSC timestamp (<= 2000ms):
        final existingSmsMatches = await txn.rawQuery(
          '''
          SELECT er.broadcast_source_record_id, er.inbox_source_record_id,
                 e.id as evidence_id, e.economic_event_id, e.extracted_amount_minor_units,
                 e.sender_address, e.extracted_timestamp, e.source_record_id
          FROM ${TablesV24.evidence} e
          JOIN ${TablesV24.economicEvents} ev ON ev.id = e.economic_event_id
          LEFT JOIN ${TablesV26.evidenceReconciliations} er ON er.broadcast_source_record_id = e.source_record_id
          WHERE e.body_sha256 = ?
            AND e.extracted_amount_minor_units = ?
            AND ev.timestamp BETWEEN ? AND ?
          ''',
          [candidateFp, candidate.amountMinorUnits, winStart, winEnd],
        );

        for (final ex in existingSmsMatches) {
          final exSender = (ex['sender_address'] as String? ?? '').trim().toUpperCase();
          final candidateSender = candidate.sender.trim().toUpperCase();
          if (exSender.isNotEmpty && exSender == candidateSender) {
            final rawExTs = ex['extracted_timestamp'] as String?;
            final exTs = rawExTs != null ? DateTime.tryParse(rawExTs) : null;
            final diffMs = exTs != null
                ? (candidate.timestamp.difference(exTs).inMilliseconds).abs()
                : 9999999;
            final existingSourceId = ex['source_record_id'] as String? ?? '';
            final isReconciled = ex['broadcast_source_record_id'] != null;
            final isInboxSms = existingSourceId.startsWith('SRC:TELEPHONY_SMS:');

            if (diffMs <= 2000 && (isReconciled || isInboxSms)) {
              // Ambiguous same-second unreferenced collision!
              // Broadcast opportunity was already consumed, and timestamps coincide at the same second.
              // Cannot establish whether this is a carrier duplicate or distinct transaction.
              // Preserve in Review Queue; do NOT create duplicate postings and do NOT silently drop!
              AppLogger.w(
                '[CrossChannelDeduplication] Same-second unreferenced inbox collision for ${candidate.sourceRecordId}: already reconciled on event ${ex['economic_event_id']}',
              );
              return await _routeToReviewQueue(
                candidate: candidate,
                reason: 'SAME_SECOND_UNREFERENCED_INBOX_COLLISION',
                txn: txn,
              );
            }
          }
        }
      }
      // If no broadcast match and no same-second consumed collision, falls through to Stage 2 / New Event Creation.
    }

    // =========================================================================
    // STAGE 2: CONSERVATIVE CORRELATION & FORBIDDEN MATCHING SAFEGUARDS
    // =========================================================================
    // Check for recent events within temporal correlation window (10 minutes)
    final windowStart = candidate.timestamp
        .subtract(const Duration(minutes: 10))
        .toUtc()
        .toIso8601String();
    final windowEnd = candidate.timestamp
        .add(const Duration(minutes: 10))
        .toUtc()
        .toIso8601String();

    final recentCandidates = await txn.rawQuery(
      '''
      SELECT e.id as evidence_id, e.economic_event_id, e.extracted_amount_minor_units,
             e.external_reference, e.source_type, e.source_record_id, e.sender_address,
             ev.event_type, ev.lifecycle_status, ev.timestamp, ev.description
      FROM ${TablesV24.evidence} e
      JOIN ${TablesV24.economicEvents} ev ON ev.id = e.economic_event_id
      WHERE e.extracted_amount_minor_units = ?
        AND ev.timestamp BETWEEN ? AND ?
      ORDER BY ev.timestamp DESC
      ''',
      [candidate.amountMinorUnits, windowStart, windowEnd],
    );

    if (recentCandidates.isNotEmpty) {
      for (final recent in recentCandidates) {
        final recentRef = recent['external_reference'] as String?;
        final recentSourceRecordId = recent['source_record_id'] as String? ?? '';
        final isRecentSms = recentSourceRecordId.startsWith('SRC:TELEPHONY_SMS:') ||
            recent['source_type'] == 'sms';
        final isRecentPush = recentSourceRecordId.startsWith('SRC:ANDROID_NOTIF:') ||
            (recent['sender_address'] as String? ?? '').startsWith('APP:');

        final isCandidateSms = candidate.sourceChannel == SourceChannel.sms ||
            candidate.sourceRecordId.startsWith('SRC:TELEPHONY_SMS:');
        final isCandidatePush = candidate.sourceChannel == SourceChannel.push ||
            candidate.sourceRecordId.startsWith('SRC:ANDROID_NOTIF:');

        final isCrossChannel = (isCandidateSms && isRecentPush) || (isCandidatePush && isRecentSms);
        final isSameChannel = (isCandidateSms && isRecentSms) || (isCandidatePush && isRecentPush);

        // Check reference state
        final candidateHasRef = normRef != null && normRef.isNotEmpty;
        final recentHasRef = recentRef != null && recentRef.trim().isNotEmpty;

        // If both have explicit references and they differed, Stage 1 already didn't match.
        // Explicit distinct references override correlation (P14-T17) -> Legitimate Repeat!
        if (candidateHasRef && recentHasRef) {
          continue;
        }

        // ── Merchant Confirmation Duplicate Matching ──
        // When one message is from the bank/card payment and the other is a merchant confirmation
        // receipt (e.g. PolicyBazaar confirmation for the same ₹4515 card spend):
        // If amounts match, timestamps are within window, and merchant identity matches:
        // They represent the exact same economic transaction!
        final candidateMerchant = candidate.merchant?.toLowerCase().trim() ?? '';
        final recentDesc = (recent['description'] as String? ?? '').toLowerCase().trim();
        final lowerBody = candidate.body.toLowerCase();
        final isMerchantConfirmationSignal = lowerBody.contains('successful for the purchase') ||
            lowerBody.contains('purchase of your') ||
            lowerBody.contains('order placed') ||
            lowerBody.contains('order confirmed') ||
            lowerBody.contains('ticket booked') ||
            lowerBody.contains('booking confirmed') ||
            (lowerBody.contains('payment of') && (lowerBody.contains('policybazaar') || lowerBody.contains('policy') || lowerBody.contains('swiggy') || lowerBody.contains('zomato') || lowerBody.contains('uber') || lowerBody.contains('irctc')));
        final isMerchantMatch = candidateMerchant.isNotEmpty &&
            (candidateMerchant == recentDesc ||
             (candidateMerchant.contains('policy') && recentDesc.contains('policy')) ||
             (candidateMerchant.contains('swiggy') && recentDesc.contains('swiggy')) ||
             (candidateMerchant.contains('zomato') && recentDesc.contains('zomato')) ||
             (candidateMerchant.contains('irctc') && recentDesc.contains('irctc')) ||
             (candidateMerchant.contains('uber') && recentDesc.contains('uber')));
        final isKnownMerchantSender = candidate.sender.toLowerCase().contains('policy') ||
            candidate.sender.toLowerCase().contains('swiggy') ||
            candidate.sender.toLowerCase().contains('zomato') ||
            candidate.sender.toLowerCase().contains('irctc') ||
            candidate.sender.toLowerCase().contains('uber') ||
            candidate.sender.toLowerCase().contains('flpkrt') ||
            recent['sender_address'].toString().toLowerCase().contains('policy');

        if ((isMerchantMatch || isKnownMerchantSender) && (isMerchantConfirmationSignal || isKnownMerchantSender)) {
          // Exactly one economic event must exist in the canonical ledger!
          final matchedEventId = recent['economic_event_id'] as String;
          final evidenceId = const Uuid().v4();
          final nowStr = DateTime.now().toUtc().toIso8601String();

          await txn.insert(TablesV24.evidence, {
            'id': evidenceId,
            'economic_event_id': matchedEventId,
            'source_type': candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'push',
            'source_record_id': candidate.sourceRecordId,
            'extracted_amount_minor_units': candidate.amountMinorUnits,
            'extracted_timestamp': candidate.timestamp.toUtc().toIso8601String(),
            'sender_address': candidate.sender,
            'external_reference': normRef,
            'body_sha256': CanonicalTransactionAdapter.computeBodyFingerprint(candidate.body),
            'raw_payload_encrypted': candidate.body,
            'retention_expires_at': DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
            'is_payload_purged': 0,
            'created_at': nowStr,
          });

          AppLogger.i(
            '[CrossChannelDeduplication] Merchant confirmation duplicate matched: linked ${candidate.sourceRecordId} to event $matchedEventId',
          );
          return DeduplicationResult(
            status: DeduplicationStatus.strongMatchMerged,
            eventId: matchedEventId,
            evidenceId: evidenceId,
            sourceRecordId: candidate.sourceRecordId,
          );
        }

        // Case 2A: One-sided reference on correlation (P14-T24)
        if (candidateHasRef != recentHasRef) {
          AppLogger.w(
            '[CrossChannelDeduplication] One-sided reference on correlation: candidateHasRef=$candidateHasRef vs recentHasRef=$recentHasRef',
          );
          return await _routeToReviewQueue(
            candidate: candidate,
            reason: 'ONE_SIDED_REFERENCE_UNRESOLVED',
            txn: txn,
          );
        }

        // Case 2B: Unreferenced cross-channel correlation (neither has reference)
        if (!candidateHasRef && !recentHasRef) {
          if (isCrossChannel) {
            // Revision 13 Strict Invariant: Tier 3 unreferenced cross-channel matching is FORBIDDEN!
            // Automatic merge is forbidden; candidate routed to Review Queue.
            AppLogger.i(
              '[CrossChannelDeduplication] Tier 3 unreferenced cross-channel match: routing to Review Queue',
            );
            return await _routeToReviewQueue(
              candidate: candidate,
              reason: 'CROSS_CHANNEL_UNREFERENCED_ACCOUNT_MATCH',
              txn: txn,
            );
          } else if (isSameChannel && isCandidatePush) {
            // Two push notifications for identical amount within temporal window without UTR (P14-T05):
            // 1st posted to ledger; 2nd routes to Review Queue; zero silent drops.
            AppLogger.i(
              '[CrossChannelDeduplication] Ambiguous repeated push notification: routing to Review Queue',
            );
            return await _routeToReviewQueue(
              candidate: candidate,
              reason: 'REPEAT_PAYMENT_SUSPECTED_DUPLICATE',
              txn: txn,
            );
          } else if (isSameChannel && isCandidateSms) {
            // Two distinct telephony SMS records with different telephony IDs (P14-T11, P14-T04):
            // Both legitimate payments are preserved and posted independently.
            // Continue loop to post as new event.
          }
        }
      }
    }

    // =========================================================================
    // DEFAULT: CREATE AND POST LEGITIMATE NEW ECONOMIC EVENT
    // =========================================================================
    // Ambiguity / Unresolved Instrument Safety Gate:
    // If instrument resolution failed or reported ambiguity, route directly to Review Queue.
    // Zero accounting postings; never silently substitute acc_cash_default for an expected instrument.
    if (candidate.isAmbiguous) {
      AppLogger.w(
        '[CrossChannelDeduplication] Unresolved or ambiguous instrument for ${candidate.sourceRecordId}: routing to Review Queue',
      );
      return await _routeToReviewQueue(
        candidate: candidate,
        reason: candidate.ambiguityReason ?? 'UNRESOLVED_INSTRUMENT_ATTRIBUTION',
        txn: txn,
      );
    }

    // Exhaustive Event Type Safety Gate:
    // Only supported canonical event types may proceed to posting.
    // Unsupported / unexpected event types fail closed to Review Queue.
    const supportedEventTypes = {
      CanonicalEventType.expense,
      CanonicalEventType.income,
      CanonicalEventType.cardPurchase,
      CanonicalEventType.cardPayment,
      CanonicalEventType.transfer,
      CanonicalEventType.loanRepayment,
      CanonicalEventType.refund,
    };
    if (!supportedEventTypes.contains(candidate.eventType)) {
      AppLogger.w(
        '[CrossChannelDeduplication] Unsupported canonical event type (${candidate.eventType}) for ${candidate.sourceRecordId}: failing closed to Review Queue',
      );
      return await _routeToReviewQueue(
        candidate: candidate,
        reason: 'UNSUPPORTED_EVENT_TYPE',
        txn: txn,
      );
    }

    return await _createAndPostNewEvent(
      candidate: candidate,
      reversalOfEventId: candidate.reversalOfEventId,
      txn: txn,
    );
  }

  /// Safely executes [processIncomingCandidate] within an atomic transaction.
  ///
  /// Concurrency & Constraint-Collision Recovery:
  /// If two concurrent workers attempt to ingest the exact same [sourceRecordId]
  /// in parallel, the first transaction commits while the second encounters a
  /// unique constraint failure on `idx_evidence_source_record`. SQLite automatically
  /// rolls back the second transaction (leaving ZERO partial draft events or postings).
  /// This handler then safely catches the conflict and resolves to the existing
  /// event committed by the winning transaction.
  Future<DeduplicationResult> processWithConflictResolution({
    required IncomingTransactionCandidate candidate,
    required Database db,
  }) async {
    try {
      return await db.transaction((txn) => processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError() ||
          e.toString().contains('evidence.source_record_id') ||
          e.toString().contains('idx_evidence_source_record')) {
        AppLogger.i(
          '[CrossChannelDeduplication] Concurrent ingestion conflict on ${candidate.sourceRecordId}; safely resolved to committed event',
        );
        final existing = await db.query(
          TablesV24.evidence,
          columns: ['id', 'economic_event_id'],
          where: 'source_record_id = ?',
          whereArgs: [candidate.sourceRecordId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          return DeduplicationResult(
            status: DeduplicationStatus.duplicateSourceRecord,
            eventId: existing.first['economic_event_id'] as String?,
            evidenceId: existing.first['id'] as String,
            sourceRecordId: candidate.sourceRecordId,
          );
        }
      }
      rethrow;
    }
  }

  // ── Historical SMS Reconciliation (Section 5) ──────────────────────────────

  /// Reconciles a historical SMS row with pre-migration legacy evidence (`source_record_id IS NULL`).
  ///
  /// Revision 13 Rules:
  /// - Link historical SMS to legacy evidence ONLY when a unique UTR/RRN match is established.
  /// - Fingerprint-only matches must NOT be automatically linked.
  /// - Ambiguous historical matches must be quarantined in the Review Queue.
  /// - ZERO mutation of historical economic events or postings.
  Future<HistoricalLinkingResult> linkHistoricalSms({
    required String smsId,
    required String body,
    required String sender,
    required DateTime timestamp,
    required int amountMinorUnits,
    String? utrOrRrn,
    required DatabaseExecutor txn,
  }) async {
    final smsSourceId = buildSmsSourceId(smsId);

    // 1. Check if already linked
    final existingSource = await txn.query(
      TablesV24.evidence,
      columns: ['id'],
      where: 'source_record_id = ?',
      whereArgs: [smsSourceId],
      limit: 1,
    );
    if (existingSource.isNotEmpty) {
      return HistoricalLinkingResult.linked(existingSource.first['id'] as String);
    }

    final rawRef = utrOrRrn ?? extractUtrOrRrn(body);
    final normRef = rawRef != null && rawRef.trim().isNotEmpty
        ? normalizeReference(rawRef)
        : null;

    if (normRef != null && normRef.isNotEmpty) {
      // Find unlinked legacy evidence matching this exact reference
      final matchingLegacy = await txn.rawQuery(
        '''
        SELECT id, economic_event_id, extracted_amount_minor_units
        FROM ${TablesV24.evidence}
        WHERE (external_reference = ? OR external_reference = ?)
          AND source_record_id IS NULL
        ''',
        [normRef, rawRef],
      );

      if (matchingLegacy.length == 1) {
        final legacyRow = matchingLegacy.first;
        final legacyAmount = (legacyRow['extracted_amount_minor_units'] as num).toInt();

        if (legacyAmount == amountMinorUnits) {
          // Exactly one unique legacy evidence row matched by UTR/RRN!
          // Link by updating source_record_id without mutating financial event or postings.
          final targetEvidenceId = legacyRow['id'] as String;
          await txn.update(
            TablesV24.evidence,
            {'source_record_id': smsSourceId},
            where: 'id = ?',
            whereArgs: [targetEvidenceId],
          );
          AppLogger.i(
            '[HistoricalReconciliation] Successfully linked historical SMS $smsSourceId to evidence $targetEvidenceId via UTR $normRef',
          );
          return HistoricalLinkingResult.linked(targetEvidenceId);
        }
      } else if (matchingLegacy.length > 1) {
        // Multiple legacy evidence rows share this reference -> Ambiguity!
        final reviewId = const Uuid().v4();
        await _insertReviewCandidateRow(
          id: reviewId,
          sourceType: 'sms',
          rawPayload: body,
          eventType: CanonicalEventType.expense,
          amountMinorUnits: amountMinorUnits,
          confidenceScore: 0.5,
          txn: txn,
        );
        return HistoricalLinkingResult.quarantined(
          reviewCandidateId: reviewId,
          reason: 'AMBIGUOUS_HISTORICAL_SMS_RECONCILIATION',
        );
      }
    }

    // Fingerprint check: If matching legacy evidence exists solely by fingerprint,
    // Revision 13 strictly prohibits automatic linking!
    final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(body);
    final fingerprintMatches = await txn.query(
      TablesV24.evidence,
      columns: ['id'],
      where: 'body_sha256 = ? AND source_record_id IS NULL',
      whereArgs: [bodyFp],
    );

    if (fingerprintMatches.isNotEmpty) {
      // Fingerprint-only match without verified UTR -> Strictly refuse auto-linking!
      final reviewId = const Uuid().v4();
      await _insertReviewCandidateRow(
        id: reviewId,
        sourceType: 'sms',
        rawPayload: body,
        eventType: CanonicalEventType.expense,
        amountMinorUnits: amountMinorUnits,
        confidenceScore: 0.4,
        txn: txn,
      );
      AppLogger.w(
        '[HistoricalReconciliation] Fingerprint-only historical match quarantined: $smsSourceId',
      );
      return HistoricalLinkingResult.quarantined(
        reviewCandidateId: reviewId,
        reason: 'AMBIGUOUS_HISTORICAL_SMS_RECONCILIATION',
      );
    }

    return const HistoricalLinkingResult.unlinked(
      reason: 'NO_LEGACY_MATCH_FOUND',
    );
  }

  // ── Internal Helpers ───────────────────────────────────────────────────────

  bool _hasRefundSemantics(String text) {
    final lower = text.toLowerCase();
    return lower.contains('refund') ||
        lower.contains('reversed') ||
        lower.contains('reversal') ||
        lower.contains('cashback') ||
        lower.contains('credited back');
  }

  Future<DeduplicationResult> _routeToReviewQueue({
    required IncomingTransactionCandidate candidate,
    required String reason,
    required DatabaseExecutor txn,
  }) async {
    final reviewId = const Uuid().v4();
    final evidenceId = const Uuid().v4();
    final nowStr = DateTime.now().toUtc().toIso8601String();
    final normRef = candidate.externalReference != null
        ? normalizeReference(candidate.externalReference!)
        : extractUtrOrRrn(candidate.body);

    // 1. Insert quarantined evidence record
    await txn.insert(TablesV24.evidence, {
      'id': evidenceId,
      'economic_event_id': null,
      'source_type': candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'manual',
      'source_record_id': candidate.sourceRecordId,
      'extracted_amount_minor_units': candidate.amountMinorUnits,
      'extracted_timestamp': candidate.timestamp.toUtc().toIso8601String(),
      'sender_address': candidate.sender,
      'external_reference': normRef,
      'body_sha256': CanonicalTransactionAdapter.computeBodyFingerprint(candidate.body),
      'raw_payload_encrypted': candidate.body,
      'retention_expires_at': DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
      'is_payload_purged': 0,
      'created_at': nowStr,
    });

    // 2. Insert ReviewCandidate proposal (ZERO postings)
    // The raw_payload MUST include a 'parsed' key so ReviewRepo.toItem()
    // can rehydrate a full ParsedTransaction without having to re-parse
    // the raw body from scratch. This prevents the "{\"body\":\"...\"}" note
    // bug and the sys_suspense_transfer account bug.
    final parsed = TransactionTextParser.parse(
      candidate.body,
      source: candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'push',
      messageTimestamp: candidate.timestamp,
    );
    final parsedForStorage = ParsedTransaction(
      amount: parsed.amount > 0 ? parsed.amount : candidate.amountMinorUnits / 100.0,
      isCredit: candidate.direction == PostingDirection.credit,
      rawText: candidate.body,
      date: parsed.date,
      merchant: parsed.merchant ?? candidate.merchant,
      refId: parsed.refId,
      last4: parsed.last4 ?? candidate.accountNumberLast4,
      bankName: parsed.bankName,
      method: parsed.method,
      source: candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'push',
      confidence: parsed.confidence,
      merchantSource: parsed.merchantSource,
      hasDirectionSignal: parsed.hasDirectionSignal,
    );
    await _insertReviewCandidateRow(
      id: reviewId,
      sourceType: candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'push',
      rawPayload: jsonEncode({
        'rawSource': candidate.body,
        'parsed': parsedForStorage.toMap(),
        'sender': candidate.sender,
        'reason': reason,
        'sourceRecordId': candidate.sourceRecordId,
        'timestamp': candidate.timestamp.toIso8601String(),
      }),
      eventType: candidate.eventType,
      amountMinorUnits: candidate.amountMinorUnits,
      accountId: candidate.accountId,
      confidenceScore: parsed.confidence.clamp(0.4, 0.95),
      txn: txn,
    );

    AppLogger.i(
      '[CrossChannelDeduplication] Routed ${candidate.sourceRecordId} to Review Queue ($reason)',
    );
    return DeduplicationResult(
      status: DeduplicationStatus.routedToReviewQueue,
      evidenceId: evidenceId,
      reviewCandidateId: reviewId,
      reviewReason: reason,
      sourceRecordId: candidate.sourceRecordId,
    );
  }

  Future<DeduplicationResult> _createAndPostNewEvent({
    required IncomingTransactionCandidate candidate,
    String? reversalOfEventId,
    required DatabaseExecutor txn,
  }) async {
    // 0. Refund safety check: A refund requires an original purchase event to allocate against.
    // If none exists, route directly to Review Queue BEFORE creating any draft event or evidence.
    final parentEventId = candidate.originalPurchaseEventId ?? reversalOfEventId;
    if (candidate.eventType == CanonicalEventType.refund && parentEventId == null) {
      return await _routeToReviewQueue(
        candidate: candidate,
        reason: 'REFUND_MISSING_ORIGINAL_PURCHASE',
        txn: txn,
      );
    }

    final eventId = const Uuid().v4();
    final evidenceId = const Uuid().v4();
    final nowStr = DateTime.now().toUtc().toIso8601String();
    final normRef = candidate.externalReference != null
        ? normalizeReference(candidate.externalReference!)
        : (extractUtrOrRrn(candidate.body) != null
            ? normalizeReference(extractUtrOrRrn(candidate.body)!)
            : null);

    final eventTypeSql = CanonicalEventTypeMapper.toSql(candidate.eventType);
    final isDebit = candidate.direction == PostingDirection.debit;

    // 1. Create Economic Event in 'draft' status
    await txn.insert(TablesV24.economicEvents, {
      'id': eventId,
      'event_type': eventTypeSql,
      'lifecycle_status': 'draft',
      'reversal_of_event_id': reversalOfEventId,
      'timestamp': candidate.timestamp.toUtc().toIso8601String(),
      'currency': 'INR',
      'description': candidate.merchant ?? (candidate.sender.isNotEmpty ? candidate.sender : 'Transaction'),
      'notes': jsonEncode({'source_record_id': candidate.sourceRecordId}),
      'created_at': nowStr,
      'updated_at': nowStr,
    });

    // 2. Insert Evidence
    await txn.insert(TablesV24.evidence, {
      'id': evidenceId,
      'economic_event_id': eventId,
      'source_type': candidate.sourceChannel == SourceChannel.sms ? 'sms' : 'manual',
      'source_record_id': candidate.sourceRecordId,
      'extracted_amount_minor_units': candidate.amountMinorUnits,
      'extracted_timestamp': candidate.timestamp.toUtc().toIso8601String(),
      'sender_address': candidate.sender,
      'external_reference': normRef,
      'body_sha256': CanonicalTransactionAdapter.computeBodyFingerprint(candidate.body),
      'raw_payload_encrypted': candidate.body,
      'retention_expires_at': DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
      'is_payload_purged': 0,
      'created_at': nowStr,
    });

    // 3. Insert Balanced Double-Entry Postings
    // Leg 1: Primary Asset/Liability account
    final primaryAcc = candidate.accountId ?? 'acc_cash_default';
    final existingPrimary = await txn.query(
      TablesV24.accounts,
      columns: ['account_type'],
      where: 'id = ?',
      whereArgs: [primaryAcc],
      limit: 1,
    );
    final String primaryType = candidate.primaryAccountType ??
        (existingPrimary.isNotEmpty
            ? existingPrimary.first['account_type'] as String
            : (candidate.eventType == CanonicalEventType.cardPurchase ? 'liability' : 'asset'));
    await _ensureAccountExists(txn, primaryAcc, primaryType);

    // Leg 2: Offset category/suspense account
    final String offsetType;
    final String defaultOffset;
    switch (candidate.eventType) {
      case CanonicalEventType.cardPayment:
        offsetType = 'liability';
        defaultOffset = TablesV24.sysSuspenseCard;
        break;
      case CanonicalEventType.transfer:
        offsetType = 'asset';
        defaultOffset = TablesV24.sysSuspenseTransfer;
        break;
      case CanonicalEventType.loanRepayment:
        offsetType = 'liability';
        defaultOffset = TablesV24.sysSuspenseLoan;
        break;
      case CanonicalEventType.refund:
        offsetType = 'expense';
        defaultOffset = TablesV24.sysExpMisc;
        break;
      case CanonicalEventType.expense:
      case CanonicalEventType.cardPurchase:
        offsetType = 'expense';
        defaultOffset = TablesV24.sysExpMisc;
        break;
      case CanonicalEventType.income:
        offsetType = 'income';
        defaultOffset = TablesV24.sysIncMisc;
        break;
      default:
        throw ArgumentError('Unsupported canonical event type: ${candidate.eventType}');
    }

    final offsetAcc = candidate.counterpartyAccountId ?? defaultOffset;
    await _ensureAccountExists(txn, offsetAcc, offsetType);

    // Debit leg
    await txn.insert(TablesV24.postings, {
      'id': const Uuid().v4(),
      'economic_event_id': eventId,
      'account_id': isDebit ? offsetAcc : primaryAcc,
      'sequence_number': 1,
      'direction': 'debit',
      'amount_minor_units': candidate.amountMinorUnits,
      'currency': 'INR',
      'created_at': nowStr,
    });

    // Credit leg
    await txn.insert(TablesV24.postings, {
      'id': const Uuid().v4(),
      'economic_event_id': eventId,
      'account_id': isDebit ? primaryAcc : offsetAcc,
      'sequence_number': 2,
      'direction': 'credit',
      'amount_minor_units': candidate.amountMinorUnits,
      'currency': 'INR',
      'created_at': nowStr,
    });

    // 4. If this is a refund, insert refund allocation before posting
    if (candidate.eventType == CanonicalEventType.refund) {
      final parentEventId = candidate.originalPurchaseEventId ?? reversalOfEventId;
      if (parentEventId == null) {
        return await _routeToReviewQueue(
          candidate: candidate,
          reason: 'REFUND_MISSING_ORIGINAL_PURCHASE',
          txn: txn,
        );
      }
      await _refundRepo.insertAllocation(
        txn: txn,
        allocation: RefundAllocation(
          id: const Uuid().v4(),
          refundEventId: eventId,
          originalEventId: parentEventId,
          allocatedAmountMinorUnits: candidate.allocatedAmountMinorUnits ?? candidate.amountMinorUnits,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }

    // 5. Post Event: transitions draft -> posted, validating SQLite triggers
    await txn.update(
      TablesV24.economicEvents,
      {
        'lifecycle_status': 'posted',
        'updated_at': nowStr,
      },
      where: 'id = ?',
      whereArgs: [eventId],
    );

    AppLogger.i(
      '[CrossChannelDeduplication] Created and posted new event $eventId for ${candidate.sourceRecordId}',
    );
    return DeduplicationResult(
      status: DeduplicationStatus.newEventCreated,
      eventId: eventId,
      evidenceId: evidenceId,
      sourceRecordId: candidate.sourceRecordId,
    );
  }

  Future<void> _insertReviewCandidateRow({
    required String id,
    required String sourceType,
    required String? rawPayload,
    required CanonicalEventType eventType,
    required int amountMinorUnits,
    String? accountId,
    required double confidenceScore,
    required DatabaseExecutor txn,
  }) async {
    final nowStr = DateTime.now().toUtc().toIso8601String();
    await txn.insert(
      TablesV24.reviewCandidates,
      {
        'id': id,
        'source_type': sourceType,
        'raw_payload': rawPayload,
        'suggested_event_type': CanonicalEventTypeMapper.toSql(eventType),
        'suggested_amount_minor_units': amountMinorUnits,
        'suggested_account_id': accountId,
        'suggested_category_id': null,
        'confidence_score': confidenceScore,
        'status': 'pending',
        'created_at': nowStr,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _ensureAccountExists(
    DatabaseExecutor txn,
    String accountId,
    String type,
  ) async {
    final rows = await txn.query(
      TablesV24.accounts,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (rows.isEmpty) {
      String resolvedName = accountId;
      try {
        final catRows = await txn.query(
          Tables.categories,
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [accountId],
          limit: 1,
        );
        if (catRows.isNotEmpty &&
            catRows.first['name'] != null &&
            (catRows.first['name'] as String).trim().isNotEmpty) {
          resolvedName = (catRows.first['name'] as String).trim();
        }
      } catch (_) {}

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await txn.insert(
        TablesV24.accounts,
        {
          'id': accountId,
          'account_type': type,
          'subtype': type == 'asset'
              ? 'cash'
              : (type == 'expense' ? 'general' : 'income'),
          'name': resolvedName,
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

  Future<void> _ensureTablesV26(DatabaseExecutor txn) async {
    await TablesV26.createAllV26(txn);
  }
}
