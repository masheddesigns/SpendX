import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';
import 'canonical_event_repository.dart';

/// Canonical Review Repository for SpendX 2.0.
///
/// Implements ingestion boundary persistence for unconfirmed transaction proposals.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// A [ReviewCandidate] NEVER creates accounting postings. It resides purely in
/// `review_candidates` until confirmed by the user and explicitly converted into
/// an [EconomicEvent].
class CanonicalReviewRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalReviewRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor(Transaction? txn) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Stashes an ingested review proposal.
  Future<void> createCandidate(
    ReviewCandidate candidate, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final statusStr = candidate.status == ReviewCandidateStatus.approved
        ? 'approved'
        : (candidate.status == ReviewCandidateStatus.pending
            ? 'pending'
            : 'rejected');

    await db.insert(
      TablesV24.reviewCandidates,
      {
        'id': candidate.id,
        'source_type': candidate.sourceType,
        'raw_payload': candidate.rawPayload,
        'suggested_event_type':
            CanonicalEventTypeMapper.toSql(candidate.suggestedEventType),
        'suggested_amount_minor_units': candidate.suggestedAmount.minorUnits,
        'suggested_account_id': candidate.suggestedAccountId,
        'suggested_category_id': candidate.suggestedCategoryId,
        'confidence_score': candidate.confidenceScore,
        'status': statusStr,
        'created_at': candidate.createdAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Retrieves a review candidate by ID.
  Future<ReviewCandidate?> getCandidate(
    String id, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.reviewCandidates,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToCandidate(rows.first);
  }

  /// Lists review candidates with optional status filter.
  Future<List<ReviewCandidate>> listCandidates({
    ReviewCandidateStatus? status,
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final where = status != null ? 'status = ?' : null;
    final whereArgs = status != null
        ? [
            status == ReviewCandidateStatus.approved
                ? 'approved'
                : (status == ReviewCandidateStatus.pending ? 'pending' : 'rejected')
          ]
        : null;

    final rows = await db.query(
      TablesV24.reviewCandidates,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
    );

    return rows.map(_mapRowToCandidate).toList();
  }

  /// Marks a candidate as approved.
  Future<void> approveCandidate(
    String id, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.reviewCandidates,
      {'status': 'approved'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marks a candidate as rejected.
  Future<void> rejectCandidate(
    String id, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.reviewCandidates,
      {'status': 'rejected'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Returns count of pending candidates.
  Future<int> getPendingCount({Transaction? txn}) async {
    final db = await _getExecutor(txn);
    final res = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM ${TablesV24.reviewCandidates} WHERE status = ?;',
      ['pending'],
    );
    return (res.first['cnt'] as int?) ?? 0;
  }

  /// Marks all pending candidates as rejected.
  Future<void> rejectAllPending({Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.reviewCandidates,
      {'status': 'rejected'},
      where: 'status = ?',
      whereArgs: ['pending'],
    );
  }

  /// Cleans up approved candidates.
  Future<void> deleteApproved({Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.delete(
      TablesV24.reviewCandidates,
      where: 'status = ?',
      whereArgs: ['approved'],
    );
  }

  ReviewCandidate _mapRowToCandidate(Map<String, dynamic> row) {
    final statusStr = row['status'] as String;
    final status = switch (statusStr) {
      'approved' => ReviewCandidateStatus.approved,
      'rejected' => ReviewCandidateStatus.rejected,
      _ => ReviewCandidateStatus.pending,
    };

    final eventTypeStr = row['suggested_event_type'] as String;
    final eventType = CanonicalEventTypeMapper.fromSql(eventTypeStr);
    final amount = (row['suggested_amount_minor_units'] as num).toInt();

    return ReviewCandidate(
      id: row['id'] as String,
      sourceType: row['source_type'] as String,
      rawPayload: row['raw_payload'] as String?,
      suggestedEventType: eventType,
      suggestedAmount: Money.fromMinorUnits(amount),
      suggestedAccountId: row['suggested_account_id'] as String?,
      suggestedCategoryId: row['suggested_category_id'] as String?,
      confidenceScore: (row['confidence_score'] as num).toDouble(),
      status: status,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}
