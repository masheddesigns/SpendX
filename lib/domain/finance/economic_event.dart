import 'event_balance_validator.dart';
import 'exceptions.dart';
import 'posting.dart';

/// The lifecycle status of an [EconomicEvent].
enum EventLifecycle {
  /// Draft: Staged event in preparation; may contain incomplete or zero postings.
  draft,

  /// Posted: Committed financial truth; MUST have balanced postings. Postings are immutable.
  posted;

  bool get isDraft => this == draft;
  bool get isPosted => this == posted;
}

/// The typed canonical financial classification of an event.
enum CanonicalEventType {
  expense,
  income,
  transfer,
  cardPurchase,
  cardPayment,
  refund,
  loanDisbursement,
  loanRepayment,
  openingBalance,
  adjustment;

  bool get isExpense => this == expense;
  bool get isIncome => this == income;
  bool get isTransfer => this == transfer;
  bool get isCardPurchase => this == cardPurchase;
  bool get isCardPayment => this == cardPayment;
  bool get isRefund => this == refund;
  bool get isLoanDisbursement => this == loanDisbursement;
  bool get isLoanRepayment => this == loanRepayment;
  bool get isOpeningBalance => this == openingBalance;
  bool get isAdjustment => this == adjustment;
}

/// The atomic unit of financial truth in SpendX 2.0.
///
/// CRITICAL DOMAIN INVARIANTS:
/// 1. Draft events ([EventLifecycle.draft]) represent staged work in progress
///    and may be incomplete or have zero postings.
/// 2. An event with [lifecycleStatus] == [EventLifecycle.posted] CANNOT be
///    constructed or represented in memory without mathematically balanced postings.
/// 3. Once posted, an event's postings cannot be mutated, added, or deleted in the domain.
///    Any financial correction strictly requires a new reversal or adjustment event.
/// 4. **Domain vs Persistence Immutability Boundary**:
///    Dart-level immutability in this entity enforces business invariants in-memory.
///    Persistence-level immutability against raw SQL modifications or process restarts
///    is NOT implied to be guaranteed solely by Dart; it will be physically enforced
///    at the storage layer by native SQLite triggers in Milestone C2.
class EconomicEvent {
  /// Unique identifier of the economic event.
  final String id;

  /// Canonical domain classification.
  final CanonicalEventType canonicalType;

  /// Current lifecycle stage (draft or posted).
  final EventLifecycle lifecycleStatus;

  /// When the actual financial event occurred in the physical world.
  final DateTime occurredAt;

  /// When this record was created in the system.
  final DateTime createdAt;

  /// Descriptive memo or narrative.
  final String description;

  /// Associated evidence IDs (e.g. SMS receipts, OCR evidence records).
  final List<String> evidenceIds;

  /// Arbitrary structured audit metadata (merchant info, external refs, etc.).
  final Map<String, dynamic> metadata;

  /// The list of posting legs for this event.
  final List<Posting> postings;

  EconomicEvent({
    required this.id,
    required this.canonicalType,
    required this.lifecycleStatus,
    required this.occurredAt,
    required this.createdAt,
    this.description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
    List<Posting>? postings,
    EventBalanceValidator validator = const EventBalanceValidator(),
  })  : evidenceIds = List.unmodifiable(evidenceIds ?? const <String>[]),
        metadata = Map.unmodifiable(metadata ?? const <String, dynamic>{}),
        postings = List.unmodifiable(postings ?? const <Posting>[]) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'EconomicEvent ID cannot be empty.');
    }

    // MANDATORY DOMAIN INVARIANT:
    // A posted event CANNOT exist with unbalanced postings.
    if (lifecycleStatus == EventLifecycle.posted) {
      validator.validateOrThrow(id, this.postings);
    }
  }

  /// Creates a staged [EconomicEvent] in draft status.
  factory EconomicEvent.draft({
    required String id,
    required CanonicalEventType canonicalType,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
    List<Posting>? postings,
  }) {
    return EconomicEvent(
      id: id,
      canonicalType: canonicalType,
      lifecycleStatus: EventLifecycle.draft,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates an immediately posted [EconomicEvent], asserting balance.
  factory EconomicEvent.posted({
    required String id,
    required CanonicalEventType canonicalType,
    required DateTime occurredAt,
    required DateTime createdAt,
    required List<Posting> postings,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
    EventBalanceValidator validator = const EventBalanceValidator(),
  }) {
    return EconomicEvent(
      id: id,
      canonicalType: canonicalType,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
      validator: validator,
    );
  }

  /// Attaches postings to a draft event. Throws if event is already posted.
  EconomicEvent withPostings(List<Posting> newPostings) {
    if (lifecycleStatus == EventLifecycle.posted) {
      throw AccountingInvariantException(
        'Cannot modify or attach postings to an already-posted EconomicEvent.',
        eventId: id,
      );
    }
    return EconomicEvent.draft(
      id: id,
      canonicalType: canonicalType,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: newPostings,
    );
  }

  /// Transitions this event from draft to posted status after validating balance.
  /// Throws [AccountingInvariantException] if postings are unbalanced.
  EconomicEvent post({
    EventBalanceValidator validator = const EventBalanceValidator(),
  }) {
    if (lifecycleStatus == EventLifecycle.posted) {
      return this; // Already posted
    }
    validator.validateOrThrow(id, postings);
    return EconomicEvent(
      id: id,
      canonicalType: canonicalType,
      lifecycleStatus: EventLifecycle.posted,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
      validator: validator,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EconomicEvent &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          canonicalType == other.canonicalType &&
          lifecycleStatus == other.lifecycleStatus &&
          occurredAt == other.occurredAt &&
          description == other.description;

  @override
  int get hashCode => Object.hash(
        id,
        canonicalType,
        lifecycleStatus,
        occurredAt,
        description,
      );

  @override
  String toString() =>
      'EconomicEvent(id: $id, type: ${canonicalType.name}, status: ${lifecycleStatus.name}, legs: ${postings.length})';
}
