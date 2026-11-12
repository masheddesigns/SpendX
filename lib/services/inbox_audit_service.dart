import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/logging/app_logger.dart';
import '../data/core/app_database.dart';
import '../data/core/tables_v24.dart';
import '../data/repositories/canonical/canonical_event_repository.dart';
import '../data/repositories/canonical/canonical_transaction_adapter.dart';
import '../data/repositories/review_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../models/review_item.dart';
import 'smart_category_classifier.dart';
import 'sms_import_service.dart';
import 'transaction_text_parser.dart';

/// Item representing a financial alert discovered in SMS or notifications
/// that was not yet recorded in the double-entry accounting ledger.
class MissedInboxItem {
  final String id;
  final String sender;
  final String body;
  final double amount;
  final bool isCredit;
  final String? merchant;
  final String? bankName;
  final String? last4;
  final DateTime date;
  final String? reviewCandidateId;

  const MissedInboxItem({
    required this.id,
    required this.sender,
    required this.body,
    required this.amount,
    required this.isCredit,
    this.merchant,
    this.bankName,
    this.last4,
    required this.date,
    this.reviewCandidateId,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'sender': sender,
        'body': body,
        'amount': amount,
        'isCredit': isCredit,
        'merchant': merchant,
        'bankName': bankName,
        'last4': last4,
        'date': date.toIso8601String(),
        'reviewCandidateId': reviewCandidateId,
      };

  factory MissedInboxItem.fromMap(Map<String, dynamic> map) => MissedInboxItem(
        id: map['id'] as String,
        sender: map['sender'] as String? ?? '',
        body: map['body'] as String? ?? '',
        amount: (map['amount'] as num).toDouble(),
        isCredit: map['isCredit'] as bool? ?? false,
        merchant: map['merchant'] as String?,
        bankName: map['bankName'] as String?,
        last4: map['last4'] as String?,
        date: DateTime.tryParse(map['date'] as String? ?? '') ?? DateTime.now(),
        reviewCandidateId: map['reviewCandidateId'] as String?,
      );
}

/// The diagnostic result of an Inbox & Notification Gap Audit.
class InboxAuditResult {
  final bool permissionGranted;
  final int totalScanned;
  final int capturedCount;
  final int missedCount;
  final double coveragePercentage;
  final List<MissedInboxItem> missedItems;
  final DateTime scannedAt;
  final String? error;

  const InboxAuditResult({
    required this.permissionGranted,
    required this.totalScanned,
    required this.capturedCount,
    required this.missedCount,
    required this.coveragePercentage,
    required this.missedItems,
    required this.scannedAt,
    this.error,
  });

  bool get isClean => missedCount == 0 && permissionGranted;

  Map<String, dynamic> toMap() => {
        'permissionGranted': permissionGranted,
        'totalScanned': totalScanned,
        'capturedCount': capturedCount,
        'missedCount': missedCount,
        'coveragePercentage': coveragePercentage,
        'missedItems': missedItems.map((e) => e.toMap()).toList(),
        'scannedAt': scannedAt.toIso8601String(),
        'error': error,
      };

  factory InboxAuditResult.fromMap(Map<String, dynamic> map) => InboxAuditResult(
        permissionGranted: map['permissionGranted'] as bool? ?? false,
        totalScanned: map['totalScanned'] as int? ?? 0,
        capturedCount: map['capturedCount'] as int? ?? 0,
        missedCount: map['missedCount'] as int? ?? 0,
        coveragePercentage: (map['coveragePercentage'] as num?)?.toDouble() ?? 100.0,
        missedItems: (map['missedItems'] as List<dynamic>? ?? [])
            .map((e) => MissedInboxItem.fromMap(e as Map<String, dynamic>))
            .toList(),
        scannedAt: DateTime.tryParse(map['scannedAt'] as String? ?? '') ?? DateTime.now(),
        error: map['error'] as String?,
      );
}

/// Intelligent diagnostic and reconciliation engine that audits recent SMS
/// and push notifications against SpendX's double-entry ledger.
///
/// Features:
/// 1. Scans recent SMS and active notifications (past 14–30 days).
/// 2. Performs two-tiered deduplication:
///    - Direct Evidence fingerprint matching (`TablesV24.evidence`).
///    - Ledger reconciliation (amount + timestamp correlation in `economic_events`).
/// 3. Filters out noise (OTPs, balance inquiries, promotional spam, bill due alerts).
/// 4. Pushes newly discovered genuine transactions into `review_candidates` for
///    1-tap user confirmation, strictly preserving double-entry accounting invariants.
class InboxAuditService {
  InboxAuditService._();
  static final instance = InboxAuditService._();

  static const MethodChannel _channel = MethodChannel('spendx/sms_live');
  static const String _prefKeyLastResult = 'spendx_inbox_audit_last_result';

  InboxAuditResult? _lastResult;
  InboxAuditResult? get lastResult => _lastResult;

  /// Automatically runs a lightweight background audit if the cooldown interval (default 6 hours)
  /// has elapsed. Safe to call on app launch, resume, or pull-to-refresh.
  Future<InboxAuditResult?> runAutoAuditIfDue({
    Duration interval = const Duration(hours: 6),
    int? daysBack,
    bool pushToReviewQueue = true,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastRunMs = prefs.getInt('spendx_inbox_audit_last_auto_run_ms') ?? 0;
      final now = DateTime.now();
      if (now.millisecondsSinceEpoch - lastRunMs < interval.inMilliseconds) {
        return _lastResult ?? await loadCachedResult();
      }
      await prefs.setInt('spendx_inbox_audit_last_auto_run_ms', now.millisecondsSinceEpoch);
      return await runAudit(daysBack: daysBack, pushToReviewQueue: pushToReviewQueue);
    } catch (e) {
      AppLogger.w('[InboxAuditService] Auto audit failed: $e');
      return null;
    }
  }

  /// Loads the cached audit result from SharedPreferences.
  Future<InboxAuditResult?> loadCachedResult() async {
    if (_lastResult != null) return _lastResult;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKeyLastResult);
      if (raw != null && raw.isNotEmpty) {
        _lastResult = InboxAuditResult.fromMap(jsonDecode(raw) as Map<String, dynamic>);
        return _lastResult;
      }
    } catch (e) {
      AppLogger.w('[InboxAuditService] Error loading cached result: $e');
    }
    return null;
  }

  /// Runs an inbox diagnostic scan. If [daysBack] is omitted, defaults dynamically
  /// to the 1st of the previous calendar month up to today.
  ///
  /// Any uncaptured financial alerts are optionally pushed to [ReviewRepo] so the user
  /// can confirm them into the accounting ledger.
  Future<InboxAuditResult> runAudit({
    int? daysBack,
    bool pushToReviewQueue = true,
    int limit = 500,
  }) async {
    final hasPermission = await Permission.sms.isGranted;
    if (!hasPermission) {
      final result = InboxAuditResult(
        permissionGranted: false,
        totalScanned: 0,
        capturedCount: 0,
        missedCount: 0,
        coveragePercentage: 100.0,
        missedItems: const [],
        scannedAt: DateTime.now(),
        error: 'SMS permission not granted',
      );
      _lastResult = result;
      return result;
    }

    try {
      // 1. Sync any active notifications in the status bar
      try {
        await _channel.invokeMethod('syncActiveNotifications');
      } catch (e) {
        AppLogger.d('[InboxAuditService] syncActiveNotifications: $e');
      }

      // 2. Query recent inbox SMS messages from telephony provider
      final now = DateTime.now();
      final DateTime cutoffDate;
      if (daysBack != null) {
        cutoffDate = now.subtract(Duration(days: daysBack));
      } else {
        final year = now.month == 1 ? now.year - 1 : now.year;
        final month = now.month == 1 ? 12 : now.month - 1;
        cutoffDate = DateTime(year, month, 1);
      }
      final sinceEpochMs = cutoffDate.millisecondsSinceEpoch;
      final rawInbox = await _channel.invokeListMethod<dynamic>('queryInboxSince', {
        'sinceEpochMs': sinceEpochMs,
        'limit': limit,
      });

      // 3. Query any queued SMS/notifications from native SmsStore
      List<dynamic>? rawPending;
      try {
        rawPending = await _channel.invokeListMethod<dynamic>('getPendingSms');
      } catch (_) {}

      final combinedMessages = <Map<String, dynamic>>[];
      if (rawInbox != null) {
        for (final m in rawInbox) {
          if (m is Map) combinedMessages.add(Map<String, dynamic>.from(m));
        }
      }
      if (rawPending != null) {
        for (final m in rawPending) {
          if (m is Map) {
            combinedMessages.add({
              'address': m['sender']?.toString() ?? '',
              'body': m['body']?.toString() ?? '',
              'date': DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
      }

      final processedFingerprints = <String>{};
      int capturedCount = 0;
      final missedList = <MissedInboxItem>[];

      final eventRepo = CanonicalEventRepository();
      final reviewRepo = ReviewRepo();
      final txRepo = TransactionRepo();

      // Cache existing review candidate fingerprints/texts to avoid duplicate candidate creations
      final existingPendingReviews = await reviewRepo.getPending();
      final pendingFingerprints = <String>{};
      for (final r in existingPendingReviews) {
        final fp = CanonicalTransactionAdapter.computeBodyFingerprint(
          r.parsed.rawText.isNotEmpty ? r.parsed.rawText : r.rawSource,
        );
        pendingFingerprints.add(fp);
      }

      for (final raw in combinedMessages) {
        final body = (raw['body']?.toString() ?? '').trim();
        final sender = (raw['address']?.toString() ?? '').trim();
        if (body.isEmpty) continue;

        final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(body);
        if (processedFingerprints.contains(bodyFp)) continue;
        processedFingerprints.add(bodyFp);

        // Filter out non-financial messages (OTPs, promos, rewards, bill reminder dues)
        if (!_isPotentialFinancialAlert(body, sender)) {
          continue;
        }

        // Parse message content
        final classification = SmsImportService.instance.classifyMessage(body, sender);
        if (classification.upcomingObligation != null ||
            classification.eventType == SmsEventType.billReminder ||
            classification.eventType == SmsEventType.failed) {
          // Bill reminders and statements are obligations, not completed transactions
          continue;
        }
        final parsed = classification.transaction ??
            TransactionTextParser.parse(body, source: 'audit_inbox');

        if (parsed.amount <= 0) {
          // No actionable monetary value detected
          continue;
        }

        final rawDateMs = raw['date'];
        DateTime msgDate = now;
        if (rawDateMs is num && rawDateMs > 0) {
          msgDate = DateTime.fromMillisecondsSinceEpoch(rawDateMs.toInt());
        } else {
          msgDate = parsed.date;
        }

        // --- STEP A: Evidence Fingerprint Check ---
        final existingEvidence = await eventRepo.getEvidenceByFingerprint(bodyFp);
        if (existingEvidence != null) {
          capturedCount++;
          continue;
        }

        // --- STEP B: Pending Review Candidates Check ---
        if (pendingFingerprints.contains(bodyFp)) {
          // Already in review queue awaiting user confirmation
          capturedCount++;
          continue;
        }

        // --- STEP C: Ledger Reconciled Check (Amount + Date correlation) ---
        final matchingTxns = await txRepo.findByAmountAndDateRange(
          amount: parsed.amount,
          from: msgDate.subtract(const Duration(hours: 36)),
          to: msgDate.add(const Duration(hours: 36)),
        );

        if (matchingTxns.isNotEmpty) {
          // A transaction with this exact amount was already recorded within +/- 36h
          capturedCount++;
          continue;
        }

        // Check if there is an existing posting matching amount in double-entry database
        final db = await AppDatabase.instance.database;
        final minorUnits = CanonicalTransactionAdapter.toMinorUnits(parsed.amount);
        final fromUtc = msgDate.subtract(const Duration(hours: 36)).toUtc().toIso8601String();
        final toUtc = msgDate.add(const Duration(hours: 36)).toUtc().toIso8601String();

        final postingMatch = await db.rawQuery('''
          SELECT p.id FROM ${TablesV24.postings} p
          JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
          WHERE p.amount_minor_units = ?
            AND e.timestamp BETWEEN ? AND ?
          LIMIT 1
        ''', [minorUnits, fromUtc, toUtc]);

        if (postingMatch.isNotEmpty) {
          capturedCount++;
          continue;
        }

        // --- STEP D: Genuine Missed Financial Alert Detected! ---
        String? candidateId;
        if (pushToReviewQueue) {
          candidateId = const Uuid().v4();
          await SmartCategoryClassifier.instance.classify(
            rawText: body,
            merchant: parsed.merchant,
          );

          final item = ReviewItem(
            id: candidateId,
            rawSource: body,
            parsed: ParsedTransaction(
              amount: parsed.amount,
              isCredit: parsed.isCredit,
              rawText: body,
              date: msgDate,
              merchant: parsed.merchant,
              refId: parsed.refId,
              last4: parsed.last4,
              bankName: parsed.bankName ?? _inferBankFromSender(sender),
              method: parsed.method ?? 'bank',
              source: 'inbox_audit',
              confidence: 0.88,
              merchantSource: parsed.merchantSource ?? 'audit_engine',
              hasDirectionSignal: parsed.hasDirectionSignal,
            ),
            confidence: 0.88,
            status: 'pending',
            createdAt: msgDate,
          );

          await reviewRepo.insert(item);
          pendingFingerprints.add(bodyFp);
        }

        missedList.add(MissedInboxItem(
          id: const Uuid().v4(),
          sender: sender,
          body: body,
          amount: parsed.amount,
          isCredit: parsed.isCredit,
          merchant: parsed.merchant,
          bankName: parsed.bankName ?? _inferBankFromSender(sender),
          last4: parsed.last4,
          date: msgDate,
          reviewCandidateId: candidateId,
        ));
      }

      final totalFinancial = capturedCount + missedList.length;
      final coverage = totalFinancial == 0
          ? 100.0
          : ((capturedCount / totalFinancial) * 100).clamp(0.0, 100.0);

      final auditResult = InboxAuditResult(
        permissionGranted: true,
        totalScanned: totalFinancial,
        capturedCount: capturedCount,
        missedCount: missedList.length,
        coveragePercentage: double.parse(coverage.toStringAsFixed(1)),
        missedItems: missedList,
        scannedAt: now,
      );

      _lastResult = auditResult;
      await _persistResult(auditResult);
      return auditResult;
    } catch (e, stack) {
      AppLogger.e('[InboxAuditService] Audit failed: $e', e, stack);
      final result = InboxAuditResult(
        permissionGranted: true,
        totalScanned: 0,
        capturedCount: 0,
        missedCount: 0,
        coveragePercentage: 100.0,
        missedItems: const [],
        scannedAt: DateTime.now(),
        error: e.toString(),
      );
      _lastResult = result;
      return result;
    }
  }

  Future<void> _persistResult(InboxAuditResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyLastResult, jsonEncode(result.toMap()));
    } catch (e) {
      AppLogger.w('[InboxAuditService] Error persisting audit result: $e');
    }
  }

  /// Determines if a text message is likely an actionable financial alert,
  /// strictly filtering out OTPs, promotional spam, balance checks, and bill reminders.
  bool _isPotentialFinancialAlert(String body, String sender) {
    final lower = body.toLowerCase();

    // 1. Reject OTPs, verification codes, logins
    if (RegExp(
      r'\b(?:otp|one\s*time\s*password|verification\s*code|secret\s*code|security\s*code|login\s*code)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return false;
    }

    // 2. Reject upcoming bill reminders and due notices (they are obligations, not completed transactions)
    if (RegExp(
      r'\b(?:bill\s*due|due\s*date|payment\s*due|bill\s*generated|minimum\s*amount\s*due|total\s*amount\s*due|'
      r'statement\s*for\s*your|statement\s*is\s*sent|statement\s*generated|e-?statement|'
      r'is\s*due\s*by|is\s*due\s*on|due\s*by|due\s*on|minimum\s*due)\b',
      caseSensitive: false,
    ).hasMatch(lower) && !RegExp(r'\b(?:received\s*payment|payment\s*received|thank\s*you\s*for\s*(?:payment|paying)|auto-?debited)\b', caseSensitive: false).hasMatch(lower)) {
      return false;
    }

    // 3. Reject marketing promotions, offers, scratch cards, discounts
    if (RegExp(
      r'\b(?:scratch\s*card|win\s*up\s*to|earn\s*up\s*to|cashback\s*offer|flat\s*.*?\s*off|'
      r'apply\s*now|claim\s*now|invite\s*friends|special\s*offer|limited\s*period\s*offer|'
      r'congratulations!|pre-?approved\s*loan|increase\s*your\s*limit)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return false;
    }

    // 4. Reject incoming UPI collect requests
    if (RegExp(
      r'\b(?:collect\s*request|has\s*requested|requested\s*(?:money|payment|rs\.?|inr|₹)|approve\s*or\s*decline)\b',
      caseSensitive: false,
    ).hasMatch(lower) && !RegExp(r'\b(?:debited|paid|transferred)\b', caseSensitive: false).hasMatch(lower)) {
      return false;
    }

    // 5. Must have monetary value
    final hasAmount = RegExp(r'(?:₹|rs\.?|inr)\s*[\d,]+(?:\.\d{1,2})?|\bamt\s*[\d,]+', caseSensitive: false).hasMatch(lower);
    if (!hasAmount) {
      return false;
    }

    // 6. Must have transaction directional signal or execution keyword
    final hasActionSignal = RegExp(
      r'\b(?:debited|credited|spent|paid|sent|withdrawn|deducted|charged|transferred|'
      r'refund|cashback|reversal|standing\s*instruction|mandate\s*executed|autopay|auto-?debit|'
      r'ecs|nach|ach\s*debit|purchase\s*at|txn\s*of|transaction\s*of)\b',
      caseSensitive: false,
    ).hasMatch(lower);

    return hasActionSignal;
  }

  String? _inferBankFromSender(String sender) {
    final clean = sender.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (clean.contains('HDFC')) return 'HDFC Bank';
    if (clean.contains('SBI')) return 'SBI';
    if (clean.contains('ICICI')) return 'ICICI Bank';
    if (clean.contains('AXIS')) return 'Axis Bank';
    if (clean.contains('KOTAK')) return 'Kotak Mahindra Bank';
    if (clean.contains('FED') || clean.contains('FEDERAL')) return 'Federal Bank';
    if (clean.contains('BOB') || clean.contains('BARODA')) return 'Bank of Baroda';
    if (clean.contains('PNB')) return 'Punjab National Bank';
    if (clean.contains('INDUS')) return 'IndusInd Bank';
    if (clean.contains('YES')) return 'Yes Bank';
    if (clean.contains('IDFC')) return 'IDFC FIRST Bank';
    if (clean.contains('CANARA') || clean.contains('CNRB')) return 'Canara Bank';
    if (clean.contains('UNION') || clean.contains('UBI')) return 'Union Bank of India';
    if (clean.contains('JIO')) return 'Jio Payments Bank';
    if (clean.contains('AIRTEL')) return 'Airtel Payments Bank';
    if (clean.contains('PAYTM')) return 'Paytm Payments Bank';
    return null;
  }
}
