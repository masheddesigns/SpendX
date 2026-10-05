import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../domain/finance/finance.dart';
import '../../models/review_item.dart';
import 'canonical/canonical_event_repository.dart';
import 'canonical/canonical_review_repository.dart';
import 'canonical/canonical_transaction_adapter.dart';

/// Review Repository for SpendX 2.0.
///
/// Refactored in Milestone C5 to operate as a canonical adapter over
/// [CanonicalReviewRepository] and [CanonicalEventRepository]:
/// - All proposed review items persist as [ReviewCandidate] in `TablesV24.reviewCandidates`.
/// - Every accepted ingestion item produces an immutable [Evidence] record in `TablesV24.evidence`.
/// - Runtime writes to legacy `Tables.reviewQueue` are strictly **ZERO**.
/// - Review candidates produce **ZERO** accounting postings until explicit user confirmation.
class ReviewRepo {
  final CanonicalReviewRepository _canonicalReviewRepo;
  final CanonicalEventRepository _eventRepo;

  ReviewRepo({
    DatabaseExecutor? executor,
    CanonicalReviewRepository? canonicalReviewRepo,
    CanonicalEventRepository? eventRepo,
  })  : _canonicalReviewRepo = canonicalReviewRepo ??
            CanonicalReviewRepository(executor: executor),
        _eventRepo = eventRepo ?? CanonicalEventRepository(executor: executor);

  // ── 1. Candidate Queries (CANONICAL) ──────────────────────────────────────

  /// Fetches all unconfirmed pending review items.
  Future<List<ReviewItem>> getPending({Transaction? txn}) async {
    final candidates = await _canonicalReviewRepo.listCandidates(
      status: ReviewCandidateStatus.pending,
      txn: txn,
    );
    return candidates.map(toItem).toList();
  }

  /// Fetches a review item by unique candidate ID.
  Future<ReviewItem?> getById(String id, {Transaction? txn}) async {
    final candidate = await _canonicalReviewRepo.getCandidate(id, txn: txn);
    if (candidate == null) return null;
    return toItem(candidate);
  }

  /// Returns the count of pending review proposals.
  Future<int> getPendingCount({Transaction? txn}) async {
    return await _canonicalReviewRepo.getPendingCount(txn: txn);
  }

  // ── 2. Ingestion Storage (CANONICAL) ──────────────────────────────────────

  /// Ingests a new review item, creating an immutable [Evidence] record and
  /// a pending [ReviewCandidate] proposal. Produces ZERO accounting postings.
  Future<void> insert(ReviewItem item, {Transaction? txn}) async {
    final bodyText = item.parsed.rawText.isNotEmpty
        ? item.parsed.rawText
        : item.rawSource;
    final fingerprint = CanonicalTransactionAdapter.computeSha256(bodyText);

    final evidence = Evidence(
      id: const Uuid().v4(),
      sourceType: item.parsed.source ?? 'sms',
      sourceIdentifier: item.parsed.bankName,
      sourceTimestamp: item.parsed.date.toUtc(),
      bodyFingerprint: fingerprint,
      extractedAmount: Money.fromRupees(item.parsed.amount),
      extractedMerchant: item.parsed.merchant,
      externalReference: item.parsed.refId,
      accountContext:
          item.parsed.last4 != null ? 'XX${item.parsed.last4}' : null,
      rawPayloadEncrypted: bodyText,
      retentionExpiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      isPayloadPurged: false,
      economicEventId: null,
      createdAt: item.createdAt.toUtc(),
    );

    await _eventRepo.insertEvidence(evidence, txn: txn);
    await _canonicalReviewRepo.createCandidate(toCandidate(item), txn: txn);
  }

  /// Batch ingests multiple review items with evidence artifacts.
  Future<void> insertAll(List<ReviewItem> items, {Transaction? txn}) async {
    for (final item in items) {
      await insert(item, txn: txn);
    }
  }

  // ── 3. Candidate Lifecycle (CANONICAL) ───────────────────────────────────

  /// Marks a candidate as approved. User confirmation triggers accounting
  /// conversion through FinancialTransactionService.
  Future<void> approve(String id, {Transaction? txn}) async {
    await _canonicalReviewRepo.approveCandidate(id, txn: txn);
  }

  /// Marks a candidate as rejected. Produces ZERO accounting entries.
  Future<void> reject(String id, {Transaction? txn}) async {
    await _canonicalReviewRepo.rejectCandidate(id, txn: txn);
  }

  /// Rejects all pending review proposals.
  Future<void> rejectAll({Transaction? txn}) async {
    await _canonicalReviewRepo.rejectAllPending(txn: txn);
  }

  /// Cleans up confirmed approved candidates.
  Future<void> deleteApproved({Transaction? txn}) async {
    await _canonicalReviewRepo.deleteApproved(txn: txn);
  }

  // ── 4. Presentation Adapters ──────────────────────────────────────────────

  /// Converts a [ReviewItem] presentation model into a [ReviewCandidate] domain entity.
  static ReviewCandidate toCandidate(ReviewItem item) {
    final parsed = item.parsed;
    final payloadJson = jsonEncode({
      'rawSource': item.rawSource,
      'parsed': parsed.toJson(),
      'confidence': item.confidence,
    });

    return ReviewCandidate(
      id: item.id,
      sourceType: parsed.source ?? 'sms',
      rawPayload: payloadJson,
      suggestedEventType: parsed.isCredit
          ? CanonicalEventType.income
          : CanonicalEventType.expense,
      suggestedAmount: Money.fromRupees(parsed.amount),
      suggestedAccountId: null,
      suggestedCategoryId: null,
      confidenceScore: item.confidence.clamp(0.0, 1.0),
      status: switch (item.status) {
        'approved' => ReviewCandidateStatus.approved,
        'rejected' => ReviewCandidateStatus.rejected,
        'duplicate' => ReviewCandidateStatus.duplicate,
        _ => ReviewCandidateStatus.pending,
      },
      createdAt: item.createdAt,
    );
  }

  /// Converts a [ReviewCandidate] domain entity into a [ReviewItem] presentation model.
  static ReviewItem toItem(ReviewCandidate candidate) {
    if (candidate.rawPayload != null && candidate.rawPayload!.isNotEmpty) {
      try {
        final decoded = jsonDecode(candidate.rawPayload!);
        if (decoded is Map<String, dynamic> && decoded.containsKey('parsed')) {
          final parsedJson = decoded['parsed'];
          final parsed = parsedJson is String
              ? ParsedTransaction.fromJson(parsedJson)
              : ParsedTransaction.fromJson(jsonEncode(parsedJson));
          return ReviewItem(
            id: candidate.id,
            rawSource: decoded['rawSource'] as String? ?? candidate.sourceType,
            parsed: parsed,
            confidence: candidate.confidenceScore,
            status: candidate.status.name,
            createdAt: candidate.createdAt,
          );
        }
      } catch (_) {}
    }

    final isCredit = candidate.suggestedEventType == CanonicalEventType.income;
    return ReviewItem(
      id: candidate.id,
      rawSource: candidate.sourceType,
      parsed: ParsedTransaction(
        amount: candidate.suggestedAmount.toRupees,
        isCredit: isCredit,
        rawText: candidate.rawPayload ?? '',
        date: candidate.createdAt,
        confidence: candidate.confidenceScore,
        source: candidate.sourceType,
      ),
      confidence: candidate.confidenceScore,
      status: candidate.status.name,
      createdAt: candidate.createdAt,
    );
  }
}
