import 'economic_event.dart';
import 'money.dart';

/// The status of a review queue candidate.
enum ReviewCandidateStatus {
  /// Awaiting user review; generates ZERO accounting postings.
  pending,

  /// Confirmed and approved by user; converted into a canonical [EconomicEvent].
  approved,

  /// Explicitly dismissed or rejected by user; generates ZERO postings.
  rejected,

  /// Identified as a duplicate of an existing event; generates ZERO postings.
  duplicate;

  bool get isPending => this == pending;
  bool get isApproved => this == approved;
  bool get isRejected => this == rejected;
  bool get isDuplicate => this == duplicate;
}

/// Ingestion boundary representation of an unconfirmed transaction proposal.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// A [ReviewCandidate] is NEVER accounting truth.
/// Pending, rejected, or duplicate candidates produce ZERO rows in the postings table.
/// Only user approval triggers conversion into a canonical [EconomicEvent].
class ReviewCandidate {
  /// Unique identifier of the candidate.
  final String id;

  /// Source mechanism (e.g. 'sms', 'ocr', 'manual_import', 'bank_feed').
  final String sourceType;

  /// Original raw textual payload (subject to 30-day retention policies if SMS).
  final String? rawPayload;

  /// Inferred canonical event classification.
  final CanonicalEventType suggestedEventType;

  /// Parsed monetary amount proposal.
  final Money suggestedAmount;

  /// Suggested asset or liability account ID.
  final String? suggestedAccountId;

  /// Suggested expense or income category account ID.
  final String? suggestedCategoryId;

  /// ML/Parser confidence score between 0.0 and 1.0.
  final double confidenceScore;

  /// Ingestion lifecycle status.
  final ReviewCandidateStatus status;

  /// ID of the canonical [EconomicEvent] created if approved; null otherwise.
  final String? convertedEconomicEventId;

  /// When this candidate was ingested.
  final DateTime createdAt;

  ReviewCandidate({
    required this.id,
    required this.sourceType,
    this.rawPayload,
    required this.suggestedEventType,
    required this.suggestedAmount,
    this.suggestedAccountId,
    this.suggestedCategoryId,
    required this.confidenceScore,
    this.status = ReviewCandidateStatus.pending,
    this.convertedEconomicEventId,
    required this.createdAt,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Candidate ID cannot be empty.');
    }
    if (confidenceScore < 0.0 || confidenceScore > 1.0) {
      throw ArgumentError.value(
        confidenceScore,
        'confidenceScore',
        'Confidence score must be between 0.0 and 1.0.',
      );
    }
  }

  /// Whether this candidate currently represents actionable pending review.
  bool get isPending => status == ReviewCandidateStatus.pending;

  /// Marks this candidate as approved, referencing the newly created economic event.
  ReviewCandidate approve(String economicEventId) {
    return ReviewCandidate(
      id: id,
      sourceType: sourceType,
      rawPayload: rawPayload,
      suggestedEventType: suggestedEventType,
      suggestedAmount: suggestedAmount,
      suggestedAccountId: suggestedAccountId,
      suggestedCategoryId: suggestedCategoryId,
      confidenceScore: confidenceScore,
      status: ReviewCandidateStatus.approved,
      convertedEconomicEventId: economicEventId,
      createdAt: createdAt,
    );
  }

  /// Marks this candidate as rejected.
  ReviewCandidate reject() {
    return ReviewCandidate(
      id: id,
      sourceType: sourceType,
      rawPayload: rawPayload,
      suggestedEventType: suggestedEventType,
      suggestedAmount: suggestedAmount,
      suggestedAccountId: suggestedAccountId,
      suggestedCategoryId: suggestedCategoryId,
      confidenceScore: confidenceScore,
      status: ReviewCandidateStatus.rejected,
      convertedEconomicEventId: null,
      createdAt: createdAt,
    );
  }

  /// Marks this candidate as a duplicate of an existing event.
  ReviewCandidate markDuplicate() {
    return ReviewCandidate(
      id: id,
      sourceType: sourceType,
      rawPayload: rawPayload,
      suggestedEventType: suggestedEventType,
      suggestedAmount: suggestedAmount,
      suggestedAccountId: suggestedAccountId,
      suggestedCategoryId: suggestedCategoryId,
      confidenceScore: confidenceScore,
      status: ReviewCandidateStatus.duplicate,
      convertedEconomicEventId: null,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReviewCandidate &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          sourceType == other.sourceType &&
          suggestedEventType == other.suggestedEventType &&
          suggestedAmount == other.suggestedAmount &&
          status == other.status &&
          convertedEconomicEventId == other.convertedEconomicEventId;

  @override
  int get hashCode => Object.hash(
        id,
        sourceType,
        suggestedEventType,
        suggestedAmount,
        status,
        convertedEconomicEventId,
      );

  @override
  String toString() =>
      'ReviewCandidate(id: $id, type: ${suggestedEventType.name}, amount: $suggestedAmount, status: ${status.name})';
}
