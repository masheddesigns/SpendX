import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/parsed_sms.dart';
import 'sms_parser.dart';
import 'deduplicator_service.dart';
import 'balance_sync_service.dart';
import 'transaction_validator.dart';
import 'sms_pipeline_logger.dart';
import 'sms_safe_mode.dart';
import 'drift_detector.dart';
import 'merchant_learning_service.dart';
import '../../../data/repositories/transaction_repo.dart';
import '../../../data/repositories/category_repo.dart';
import '../../../data/repositories/account_repo.dart';
import '../../../models/transaction.dart';
import '../../../core/utils/category_classifier.dart';
import '../../../features/transactions/providers/transaction_providers.dart'
    show computeAccountImpact;

/// Production-grade real-time SMS auto-import listener.
///
/// Full pipeline per SMS:
///   1. Parse → 2. Safe-mode check → 3. Validate → 4. Deduplicate
///   → 5. Classify → 6. Insert → 7. Balance sync → 8. Drift check → 9. Notify
///
/// Reliability features:
///   - Structured logging at every stage
///   - Safe mode auto-triggers on consecutive failures
///   - Drift detection for balance mismatches
///   - Idempotent inserts (external_ref dedup)
///   - Non-blocking balance sync
class SmsAutoListener {
  SmsAutoListener._();
  static final SmsAutoListener instance = SmsAutoListener._();

  static const _channel = EventChannel('spend_x/sms_stream');

  StreamSubscription? _subscription;
  bool _isListening = false;

  /// Callback invoked after a transaction is auto-imported.
  VoidCallback? onTransactionImported;

  /// Callback for drift alerts (optional — UI can show a warning).
  void Function(DriftResult)? onDriftDetected;

  void start() {
    if (_isListening) return;
    _isListening = true;

    _subscription = _channel.receiveBroadcastStream().listen(
      (event) async {
        if (event is! Map) return;
        final data = Map<String, dynamic>.from(event);

        final sender = data['sender'] as String? ?? '';
        final body = data['body'] as String? ?? '';
        final dateMs = data['date'] as int? ?? 0;

        if (body.isEmpty) return;

        try {
          await _processIncomingSms(sender, body, dateMs);
        } catch (e) {
          _log.log(
            stage: 'pipeline',
            result: PipelineResult.failed,
            reason: 'Unhandled error: $e',
          );
          await _safeMode.recordFailure();
        }
      },
      onError: (e) {
        debugPrint('\u26A0\uFE0F SMS stream error: $e');
        _isListening = false;
      },
    );

    // Initialize safe mode from persisted state
    SmsSafeMode.instance.init();

    debugPrint('\u{1F4F1} SMS auto-listener started');
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _isListening = false;
  }

  SmsPipelineLogger get _log => SmsPipelineLogger.instance;
  SmsSafeMode get _safeMode => SmsSafeMode.instance;

  Future<void> _processIncomingSms(
      String sender, String body, int dateMs) async {
    final sw = Stopwatch()..start();
    final smsId = '${sender}_$dateMs';

    // ── STEP 1: PARSE ─────────────────────────────────────────────────
    final parsed = SmsParser.parse(
        sender: sender, body: body, timestampMillis: dateMs);

    if (parsed == null) {
      _log.log(
        stage: 'parse',
        result: PipelineResult.skipped,
        smsId: smsId,
        reason: 'not_financial',
        durationMs: sw.elapsedMilliseconds,
      );
      return;
    }

    // ── STEP 2: VALIDATE ──────────────────────────────────────────────
    final validation = TransactionValidator.validate(parsed);

    if (validation.isRejected) {
      _log.log(
        stage: 'validate',
        result: PipelineResult.skipped,
        smsId: smsId,
        amount: parsed.amount,
        reason: validation.rejectionReason,
        confidence: parsed.confidence,
      );
      return;
    }

    // Skip internal transfers
    if (parsed.kind == SmsKind.transfer) {
      _log.log(
        stage: 'classify',
        result: PipelineResult.skipped,
        smsId: smsId,
        amount: parsed.amount,
        reason: 'internal_transfer',
      );
      return;
    }

    // ── STEP 3: DEDUPLICATE ───────────────────────────────────────────
    final repo = TransactionRepo();
    final dedup = DeduplicatorService(repo);
    final externalRef = DeduplicatorService.buildExternalRef(parsed);

    if (await dedup.isDuplicate(parsed, externalRef)) {
      _log.log(
        stage: 'dedupe',
        result: PipelineResult.skipped,
        smsId: smsId,
        amount: parsed.amount,
        reason: 'duplicate',
      );
      return;
    }

    // ── STEP 4: SAFE MODE CHECK ───────────────────────────────────────
    // After validation + dedup — react to validated failures, not raw noise
    if (_safeMode.isEnabled || validation.needsReview) {
      _log.log(
        stage: _safeMode.isEnabled ? 'safe_mode' : 'validate',
        result: PipelineResult.review,
        smsId: smsId,
        amount: parsed.amount,
        merchant: parsed.merchant,
        confidence: parsed.confidence,
        reason: _safeMode.isEnabled ? 'safe_mode_active' : 'low_confidence',
      );
      await _safeMode.recordReview();
      return;
    }

    // ── STEP 5: CLASSIFY CATEGORY ─────────────────────────────────────
    final type = validation.correctedType ?? parsed.transactionType;
    String? categoryId;

    // Priority 1: Check learned merchant rules (user corrections)
    if (parsed.merchant != null) {
      categoryId = await MerchantLearningService.instance
          .suggestCategory(parsed.merchant!);
    }

    // Priority 2: Fall back to keyword classifier
    if (categoryId == null) {
      try {
        final searchText = '${parsed.merchant ?? ''} $body';
        final categoryName =
            CategoryClassifier.detect(text: searchText, type: type);
        if (categoryName != null) {
          final categories = await CategoryRepo().getAll();
          final match = categories.where(
              (c) => c.name.toLowerCase() == categoryName.toLowerCase());
          if (match.isNotEmpty) categoryId = match.first.id;
        }
      } catch (_) {}
    }

    // ── STEP 5b: MATCH ACCOUNT by last4 or bank name ───────────────
    String? accountId;
    try {
      final accRepo = AccountRepo();
      final accounts = await accRepo.getAll();
      if (parsed.last4 != null && parsed.last4!.isNotEmpty) {
        final match = accounts.where((a) =>
            a.name.contains(parsed.last4!)).firstOrNull;
        accountId = match?.id;
      }
      if (accountId == null && parsed.bankName != null) {
        final bankLower = parsed.bankName!.toLowerCase();
        final match = accounts.where((a) =>
            a.bank.toLowerCase().contains(bankLower) ||
            a.name.toLowerCase().contains(bankLower)).firstOrNull;
        accountId = match?.id;
      }
    } catch (_) {}

    // ── STEP 6: INSERT TRANSACTION ────────────────────────────────────
    final txn = Transaction(
      userId: 'offline_user',
      type: type,
      amount: parsed.amount.toDouble(),
      date: parsed.date,
      categoryId: categoryId,
      accountId: accountId,
      notes: parsed.merchant ??
          (body.length > 100 ? body.substring(0, 100) : body),
      source: 'sms_auto',
      externalRef: externalRef,
      tags: const [],
    );

    try {
      await repo.create(txn);

      // Apply balance impact (same logic as addTransactionProvider)
      if (accountId != null) {
        final accRepo = AccountRepo();
        final deltas = <String, double>{};
        computeAccountImpact(txn, deltas);
        for (final entry in deltas.entries) {
          await accRepo.adjustBalance(entry.key, entry.value);
        }
      }
    } catch (e) {
      _log.log(
        stage: 'insert',
        result: PipelineResult.failed,
        smsId: smsId,
        amount: parsed.amount,
        reason: 'db_error: $e',
      );
      await _safeMode.recordFailure();
      return;
    }

    sw.stop();
    _log.log(
      stage: 'insert',
      result: PipelineResult.success,
      smsId: smsId,
      amount: parsed.amount,
      merchant: parsed.merchant,
      type: type,
      confidence: parsed.confidence,
      durationMs: sw.elapsedMilliseconds,
    );
    _safeMode.recordSuccess();

    // ── STEP 7: BALANCE SYNC (non-blocking) ───────────────────────────
    if (parsed.balance != null) {
      try {
        await BalanceSyncService.instance.syncFromSms(parsed);
      } catch (_) {
        // Non-fatal — don't fail the pipeline
      }
    }

    // ── STEP 8: DRIFT DETECTION (non-blocking) ────────────────────────
    if (parsed.balance != null && txn.accountId != null) {
      final drift = await DriftDetector.instance.checkDrift(
        sms: parsed,
        accountId: txn.accountId,
      );
      if (drift != null) {
        onDriftDetected?.call(drift);
      }
    }

    // ── STEP 9: NOTIFY UI ─────────────────────────────────────────────
    onTransactionImported?.call();
  }
}
