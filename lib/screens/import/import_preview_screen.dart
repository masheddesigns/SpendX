import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/smart_category_classifier.dart';
import '../../data/repositories/transaction_repo.dart';
import '../../features/accounts/providers/account_providers.dart';
import '../../models/bank_account.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../features/merchant_rules/providers/merchant_rule_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/category.dart';
import '../../models/review_item.dart';
import '../../models/transaction.dart';
import '../../services/duplicate_detector.dart';
import '../../services/import_validation_log.dart';
import '../../services/merchant_memory.dart';
import '../../services/merchant_normalizer.dart';
import '../../services/recurring_detector.dart';
import '../../shared/widgets/app_card.dart';
import '../../utils/app_format.dart';

/// Mandatory preview screen for Smart Import.
///
/// User always confirms before a transaction is inserted. Confidence drives
/// the visual hierarchy:
///   ≥ 0.75 → "Confirm" — looks correct, just tap to save
///   0.50 – 0.74 → "Check & Confirm" — most fields filled, please verify
///   < 0.50 → "Edit Required" — too little detected, manual fields needed
///
/// Failed payments are shown with a clear warning and a separate
/// "Add anyway" path so the user has full agency.
class ImportPreviewScreen extends ConsumerStatefulWidget {
  final ParsedTransaction parsed;
  final bool isFailed;

  const ImportPreviewScreen({
    super.key,
    required this.parsed,
    this.isFailed = false,
  });

  @override
  ConsumerState<ImportPreviewScreen> createState() =>
      _ImportPreviewScreenState();
}

class _ImportPreviewScreenState extends ConsumerState<ImportPreviewScreen> {
  late TextEditingController _amountController;
  late TextEditingController _merchantController;
  late TextEditingController _notesController;
  late bool _isExpense;
  Category? _selectedCategory;
  String? _selectedAccountId;
  bool _saving = false;
  bool _failedAcknowledged = false;

  /// Recurring pattern that matches the parsed merchant AND whose
  /// average amount is within drift tolerance of the current parse.
  /// Drives the "🔄 Monthly ₹199 · next 28 May" awareness chip.
  RecurringPattern? _recurringMatch;

  /// Recurring pattern that matches the parsed merchant but whose
  /// average is significantly different from the current amount.
  /// Drives the "⚠ Unusual amount" chip — same data source, different
  /// surface, mutually exclusive with [_recurringMatch].
  RecurringPattern? _amountAnomalyMatch;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
        text: widget.parsed.amount > 0
            ? widget.parsed.amount.toStringAsFixed(2)
            : '');
    _merchantController =
        TextEditingController(text: widget.parsed.merchant ?? '');
    _notesController =
        TextEditingController(text: _shortRaw(widget.parsed.rawText));
    _isExpense = !widget.parsed.isCredit;

    // Resolve initial category from merchant rules (memory) or classifier
    Future.microtask(_resolveInitialCategory);

    // Look up recurring pattern in the background — surfaces a "🔁
    // Monthly" badge if this merchant has a stable history. Pure read,
    // never blocks the preview.
    Future.microtask(_resolveRecurringMatch);

    // Validation telemetry: stop the share→preview timer + snapshot the
    // parser's predictions so save() can detect what the user changed.
    ImportValidationLog.instance.previewShown(
      parsedAmount: widget.parsed.amount,
      parsedMerchant: widget.parsed.merchant,
    );
  }

  /// Maximum acceptable drift between the current parsed amount and
  /// the recurring pattern's average before we suppress the recurring
  /// badge. 30% catches "same merchant, different product" cases — a
  /// one-off ₹2,500 Amazon purchase shouldn't get badged as the
  /// user's monthly ₹199 Prime renewal.
  static const _recurringAmountDriftCeiling = 0.3;

  /// Drift above which we surface the "Unusual amount" anomaly chip
  /// instead of the recurring chip. Between 0.3 and 0.5, no badge
  /// fires — that band is ambiguous (could be a tier change, a
  /// promotional charge, etc.) and not worth a strong UI claim.
  static const _amountAnomalyFloor = 0.5;

  /// Minimum pattern confidence required to surface the anomaly
  /// chip. Stricter than the recurring badge floor (0.7) because a
  /// "this is unusual" claim is only meaningful against a strong
  /// historical baseline — weak pattern + high drift = noise, not
  /// a real anomaly.
  static const _anomalyConfidenceFloor = 0.75;

  /// Minimum recurring-pattern confidence to surface the badge.
  /// Stricter than the detector's own 0.6 floor — a "Recurring" claim
  /// in the UI is strong, so we only render it for patterns that pass
  /// at least two of (occurrences, stability, amount-tightness).
  static const _badgeConfidenceFloor = 0.7;

  /// Minimum occurrence count to surface the badge. Three sightings
  /// can accidentally align on date/amount; four is when the pattern
  /// becomes credible enough to make a strong UI claim.
  static const _badgeOccurrenceFloor = 4;

  /// How long after the pattern's projected next-expected date a
  /// pattern stays "live" for badging. Past this, the user has
  /// effectively stopped the subscription / changed merchants — a
  /// "next 28 May" badge in July would be a ghost. Suppress.
  static const _badgeOverdueGraceDays = 7;

  /// Run [RecurringDetector] over the user's history once at preview
  /// time and route the result to one of three outcomes:
  ///
  ///   * Recurring badge   — confident pattern, amount within drift
  ///                         tolerance, not overdue
  ///   * Anomaly badge     — confident pattern, current amount >50%
  ///                         off the historical average ("Unusual
  ///                         amount, expected ₹X")
  ///   * No badge          — ambiguous drift (30-50%), overdue,
  ///                         or below confidence/occurrence floors
  ///
  /// Pure read; runs after first frame so it never blocks the preview.
  Future<void> _resolveRecurringMatch() async {
    final merchant = widget.parsed.merchant?.trim();
    if (merchant == null || merchant.isEmpty) return;
    try {
      final all = await TransactionRepo().getAll();
      final patterns = RecurringDetector.analyze(all);
      final key = MerchantNormalizer.canonicalKey(merchant);
      final match = patterns.firstWhereOrNull((p) => p.merchantKey == key);
      if (match == null) return;

      // Confidence + occurrence gates apply to BOTH chip kinds — we
      // only want to compare against a credible historical average.
      if (match.confidence < _badgeConfidenceFloor) return;
      if (match.occurrences < _badgeOccurrenceFloor) return;

      // Overdue suppression: if the projected next-expected has come
      // and gone by more than the grace window, the pattern is stale
      // (cancelled subscription, moved out, etc.). Drop both badges.
      final overdueDays =
          DateTime.now().difference(match.nextExpected).inDays;
      if (overdueDays > _badgeOverdueGraceDays) return;

      final currentAmount = widget.parsed.amount;
      if (currentAmount <= 0 || match.averageAmount <= 0) return;
      final drift =
          (currentAmount - match.averageAmount).abs() / match.averageAmount;

      if (drift <= _recurringAmountDriftCeiling) {
        if (mounted) setState(() => _recurringMatch = match);
      } else if (drift >= _amountAnomalyFloor &&
          match.confidence >= _anomalyConfidenceFloor) {
        // Anomaly requires a stronger baseline than the recurring
        // chip — a weak pattern with high drift is just noise.
        if (mounted) setState(() => _amountAnomalyMatch = match);
      }
      // else: ambiguous band or weak baseline — surface nothing.
    } catch (_) {
      // Silent — badge is a nice-to-have, not a blocker.
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String _shortRaw(String raw) =>
      raw.length > 200 ? raw.substring(0, 200) : raw;

  Future<void> _resolveInitialCategory() async {
    final categories = await ref.read(categoryRepoProvider).getAll();
    Category? resolved;

    final merchant = widget.parsed.merchant?.trim();
    final type = _isExpense ? 'expense' : 'income';

    // 1. Merchant rule (learned memory) — null-safe lookup
    if (merchant != null && merchant.isNotEmpty) {
      try {
        final rule = await ref.read(merchantRuleRepoProvider).resolve(
              keyword: merchant.toLowerCase(),
              fullText: widget.parsed.rawText,
            );
        if (rule != null) {
          resolved = categories.firstWhereOrNull((c) => c.id == rule.categoryId);
        }
      } catch (_) {}
    }

    // 2. Smart classifier (learned signature → multi-signal scoring)
    if (resolved == null) {
      final detectedName = await SmartCategoryClassifier.instance.classify(
        rawText: widget.parsed.rawText,
        merchant: widget.parsed.merchant,
        merchantSource: widget.parsed.merchantSource,
      );
      if (detectedName != null) {
        resolved = categories.firstWhereOrNull(
          (c) =>
              c.type == type &&
              c.name.toLowerCase() == detectedName.toLowerCase(),
        );
      }
    }

    if (mounted) setState(() => _selectedCategory = resolved);
  }

  // ── Confidence helpers ─────────────────────────────────────────────

  String get _confidenceLabel {
    final c = widget.parsed.confidence;
    if (c >= 0.75) return 'Looks correct';
    if (c >= 0.50) return 'Please check';
    return 'Edit required';
  }

  Color _confidenceColor(ColorScheme cs) {
    final c = widget.parsed.confidence;
    if (c >= 0.75) return Colors.green;
    if (c >= 0.50) return Colors.orange;
    return cs.error;
  }

  String get _confirmButtonLabel {
    if (widget.isFailed) return 'Add anyway';
    final c = widget.parsed.confidence;
    if (c >= 0.75) return 'Confirm';
    if (c >= 0.50) return 'Check & Confirm';
    return 'Save';
  }

  // ── Duplicate check ──────────────────────────────────────────────

  /// Returns true if the user confirmed to proceed with insert.
  ///
  /// Two-stage detection runs through [DuplicateDetector]:
  ///   Stage 1 — instant exact match (signature hash) ⇒ "duplicate"
  ///   Stage 2 — fuzzy similarity (amount + merchant + time + last4)
  ///             above threshold 0.7 ⇒ "similar transaction"
  ///
  /// Repo seeding: before checking, we backfill the detector window with
  /// the last 30 minutes of saved transactions of the same amount. This
  /// catches cases where the in-memory window doesn't yet hold the
  /// earlier insert (e.g. cold start after a save).
  Future<bool> _confirmIfDuplicate(double amount) async {
    try {
      // Seed window from repo: any transaction of the same amount in
      // the ±30 min window. Cheap query, scoped narrowly.
      final repo = TransactionRepo();
      final from = widget.parsed.date.subtract(const Duration(minutes: 30));
      final to = widget.parsed.date.add(const Duration(minutes: 30));
      final recent = await repo.findByAmountAndDateRange(
        amount: amount,
        from: from,
        to: to,
      );
      DuplicateDetector.instance.seedFromRecent(recent);

      // Build the candidate fingerprint from the user's edited fields,
      // not the raw parser output — what the user is about to save IS
      // the comparison subject. rawTextHash comes from the original
      // share/OCR body; normalizedTextHash absorbs minor OCR variance
      // so re-shares of the same screenshot collide even when the
      // bytes differ in whitespace/punctuation.
      final merchant = _merchantController.text.trim();
      final rawText = widget.parsed.rawText.trim();
      final normalizedText =
          rawText.isEmpty ? '' : DuplicateDetector.normalizeText(rawText);
      final candidate = TransactionFingerprint(
        amount: amount,
        signatureHash: DuplicateDetector.buildExactSignature(
          amount: amount,
          merchant: merchant.isEmpty ? null : merchant,
          date: widget.parsed.date,
          last4: widget.parsed.last4,
        ).hashCode,
        merchant: merchant.isEmpty ? null : merchant,
        date: widget.parsed.date,
        last4: widget.parsed.last4,
        method: widget.parsed.method,
        refId: widget.parsed.refId,
        rawTextHash: rawText.isEmpty ? null : rawText.hashCode,
        normalizedTextHash:
            normalizedText.isEmpty ? null : normalizedText.hashCode,
      );

      final result = DuplicateDetector.instance.detect(candidate);
      if (!result.isDuplicate) return true;
      if (!mounted) return true;
      final proceed = await _confirmDuplicateDialog(result, merchant, amount);
      return proceed ?? false;
    } catch (_) {
      // If the check fails, don't block the save — return true.
      return true;
    }
  }

  /// Soft-interrupt dialog. Two tiers:
  ///   exact    — "This looks like a duplicate transaction"
  ///   probable — "Similar transaction found …" with score and the
  ///              matched merchant/amount so the user can sanity-check
  Future<bool?> _confirmDuplicateDialog(
    DuplicateResult result,
    String merchant,
    double amount,
  ) {
    final isExact = result.kind == DuplicateKind.exact;
    final match = result.match;
    final summary = match == null
        ? ''
        : '${AppFormat.currency(match.amount)}'
            '${match.merchant != null ? ', ${match.merchant}' : ''}';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isExact ? 'Duplicate transaction' : 'Similar transaction found'),
        content: Text(
          isExact
              ? 'You already saved a transaction with the same amount, '
                  'merchant and date. Add it again?'
              : 'A similar transaction was saved recently'
                  '${summary.isNotEmpty ? " ($summary)" : ""}. '
                  'Add this one anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save anyway'),
          ),
        ],
      ),
    );
  }

  // ── Save flow ─────────────────────────────────────────────────────

  bool get _canSave {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) return false;
    if (widget.isFailed && !_failedAcknowledged) return false;
    return true;
  }

  Future<void> _save() async {
    if (!_canSave || _saving) return;
    setState(() => _saving = true);

    final amount = double.parse(_amountController.text.trim());
    final merchant = _merchantController.text.trim();
    final type = _isExpense ? 'expense' : 'income';

    // Dedup check — same amount within ±30 minutes is likely a duplicate.
    // Wider than the old SMS window (±10 min) because manual imports often
    // happen well after the actual payment.
    final isDuplicate = await _confirmIfDuplicate(amount);
    if (!isDuplicate) {
      setState(() => _saving = false);
      return; // user chose to cancel
    }

    final txn = Transaction(
      userId: 'offline_user',
      type: type,
      amount: amount,
      date: widget.parsed.date,
      categoryId: _selectedCategory?.id,
      accountId: _selectedAccountId,
      notes: _notesController.text.trim().isEmpty
          ? merchant
          : _notesController.text.trim(),
      source: widget.parsed.source ?? 'share',
      externalRef: widget.parsed.refId,
      tags: const [],
    );

    try {
      // Validation telemetry: record what the user actually saved so we
      // can compute amount/merchant accuracy + correction rate later.
      await ImportValidationLog.instance.recordSave(
        finalAmount: amount,
        finalMerchant: merchant,
      );

      await ref.read(addTransactionProvider)(txn);

      // Remember this fingerprint so the next preview within the
      // window auto-detects a re-share / accidental re-tap. Includes
      // both rawTextHash and normalizedTextHash so re-shares collide
      // on Stage-1 even when bytes differ slightly (whitespace,
      // punctuation, casing).
      final rememberRawText = widget.parsed.rawText.trim();
      final rememberNormText = rememberRawText.isEmpty
          ? ''
          : DuplicateDetector.normalizeText(rememberRawText);
      DuplicateDetector.instance.remember(
        TransactionFingerprint(
          amount: amount,
          signatureHash: DuplicateDetector.buildExactSignature(
            amount: amount,
            merchant: merchant.isEmpty ? null : merchant,
            date: widget.parsed.date,
            last4: widget.parsed.last4,
          ).hashCode,
          merchant: merchant.isEmpty ? null : merchant,
          date: widget.parsed.date,
          last4: widget.parsed.last4,
          method: widget.parsed.method,
          refId: widget.parsed.refId,
          rawTextHash:
              rememberRawText.isEmpty ? null : rememberRawText.hashCode,
          normalizedTextHash:
              rememberNormText.isEmpty ? null : rememberNormText.hashCode,
        ),
      );

      // Learn merchant → category for next time (Riverpod merchant rules)
      if (merchant.isNotEmpty && _selectedCategory != null) {
        try {
          await ref.read(learnMerchantRuleProvider)(
            text: merchant,
            categoryId: _selectedCategory!.id,
            accountId: _selectedAccountId,
          );
        } catch (_) {}
      }

      // Teach the parser this (rawText → merchant) mapping so the next
      // similar-template share auto-fills the merchant before any regex.
      // Highest-priority signal in the resolver.
      if (merchant.isNotEmpty && widget.parsed.rawText.trim().isNotEmpty) {
        try {
          await MerchantMemory.instance.learn(
            widget.parsed.rawText,
            merchant,
          );
        } catch (_) {}
      }

      // Teach the category classifier the (signature → category) mapping
      // so similar shares get the correct category auto-selected next time.
      if (_selectedCategory != null) {
        try {
          await SmartCategoryClassifier.instance.learn(
            rawText: widget.parsed.rawText,
            merchant: merchant.isNotEmpty ? merchant : null,
            category: _selectedCategory!.name,
          );
        } catch (_) {}
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaction saved')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categoriesAsync = ref.watch(categoriesProvider);
    final accountsAsync = ref.watch(accountsProvider);

    // Failed payment short-circuit: single-tap [Ignore] vs [Add anyway].
    // Friction-light pattern — checkbox was overkill for a rare case.
    if (widget.isFailed && !_failedAcknowledged) {
      return _failedChoiceScaffold(cs);
    }

    final amountNotExtracted = widget.parsed.amount <= 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review transaction'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Empty-extraction banner — surfaces silently-empty parses so the
          // user knows the parser couldn't read the share, vs assuming a bug.
          if (amountNotExtracted) ...[
            _emptyExtractionBanner(cs),
            const SizedBox(height: 12),
          ],

          // Confidence pill
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _confidenceColor(cs).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 14, color: _confidenceColor(cs)),
                    const SizedBox(width: 6),
                    Text(
                      '${(widget.parsed.confidence * 100).round()}% • $_confidenceLabel',
                      style: TextStyle(
                        color: _confidenceColor(cs),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Recurring-payment hint. Lights up only when the merchant
          // has a high-confidence pattern in history AND the current
          // amount is within drift tolerance. Pure UX surface — doesn't
          // change the save flow, just reassures the user that their
          // Netflix/rent/salary is recognized.
          if (_recurringMatch != null) ...[
            _recurringChip(cs, _recurringMatch!),
            const SizedBox(height: 10),
          ],

          // Anomaly hint. Same data source as the recurring chip but
          // surfaces the OPPOSITE case: known merchant + history, but
          // the current amount is materially off the expected range.
          // Helps the user catch surprise charges (₹1200 Swiggy when
          // their average is ₹300) before saving.
          if (_amountAnomalyMatch != null) ...[
            _anomalyChip(cs, _amountAnomalyMatch!, widget.parsed.amount),
            const SizedBox(height: 10),
          ],

          // Field-level confidence signals — gives the user a quick
          // mental model of which extracted fields to double-check.
          _fieldSignals(cs),
          const SizedBox(height: 16),

          // Headline amount + direction toggle
          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, label: Text('Expense')),
                            ButtonSegment(value: false, label: Text('Income')),
                          ],
                          selected: {_isExpense},
                          onSelectionChanged: (s) =>
                              setState(() => _isExpense = s.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Amount',
                      prefixText: '₹ ',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _merchantController,
                    decoration: const InputDecoration(
                      labelText: 'Merchant',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Category picker
          categoriesAsync.when(
            data: (cats) => _categoryPicker(cats, cs),
            loading: () => const SizedBox(height: 60),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),

          // Account picker
          accountsAsync.when(
            data: (accs) => _accountPicker(accs, cs),
            loading: () => const SizedBox(height: 60),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),

          // Notes
          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Detected metadata pills (read-only context)
          _detectedRow(cs),
          const SizedBox(height: 12),

          // Raw text snippet
          if (widget.parsed.rawText.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Source: "${_shortRaw(widget.parsed.rawText)}"',
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.4,
                    fontStyle: FontStyle.italic),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Discard'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _canSave && !_saving ? _save : null,
                  child: _saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_confirmButtonLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Handle Ignore on failed-payment screen. Pops back AND shows a brief
  /// confirmation so the user knows the share was acknowledged (not lost).
  void _ignoreFailed() {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    // Show on whatever screen we land back on
    messenger.clearSnackBars();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Ignored — not added'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Single-tap decision for failed payments. Friction-light replacement
  /// for the old checkbox flow. User picks Ignore (back) or Add anyway
  /// (proceed to the full form).
  /// Shown when the parser couldn't extract an amount. Tells the user
  /// what happened (instead of leaving them with a silently empty form)
  /// and what to do next.
  Widget _emptyExtractionBanner(ColorScheme cs) {
    final hasRawText = widget.parsed.rawText.trim().isNotEmpty;
    final source = widget.parsed.source ?? '';
    final reason = !hasRawText
        ? 'I couldn\'t read any text from what you shared.'
        : source.startsWith('share:image')
            ? 'I read the image but couldn\'t find an amount.'
            : 'I couldn\'t find an amount in this text.';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.text_fields_rounded,
                  color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Couldn\'t auto-detect the transaction',
                  style: TextStyle(
                    color: Colors.orange.shade800,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$reason You can fill it in below — Smart Import will remember '
            'the merchant for next time.',
            style: TextStyle(
                color: cs.onSurfaceVariant, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _failedChoiceScaffold(ColorScheme cs) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review transaction')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child:
                  Icon(Icons.warning_amber_rounded, color: cs.error, size: 36),
            ),
            const SizedBox(height: 20),
            Text(
              'This looks like a failed payment',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'No money usually moves on a failed payment. You can ignore '
              'this, or add it manually if you know it succeeded.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: cs.onSurfaceVariant, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _ignoreFailed,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Ignore'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        setState(() => _failedAcknowledged = true),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Add anyway'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryPicker(List<Category> categories, ColorScheme cs) {
    final type = _isExpense ? 'expense' : 'income';
    final filtered = categories.where((c) => c.type == type).toList();
    return AppCard(
      child: ListTile(
        leading: const Icon(Icons.category_outlined),
        title: Text(_selectedCategory?.name ?? 'Choose category'),
        subtitle: const Text('Tap to pick'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final picked = await showModalBottomSheet<Category>(
            context: context,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: filtered
                    .map((c) => ListTile(
                          title: Text(c.name),
                          onTap: () => Navigator.pop(context, c),
                        ))
                    .toList(),
              ),
            ),
          );
          if (picked != null) setState(() => _selectedCategory = picked);
        },
      ),
    );
  }

  Widget _accountPicker(List<BankAccount> accounts, ColorScheme cs) {
    // Empty-state: user has no accounts yet. Skip the picker entirely —
    // account is optional for a transaction. Show a soft hint instead.
    if (accounts.isEmpty) {
      return AppCard(
        child: ListTile(
          leading: const Icon(Icons.account_balance_outlined),
          title: const Text('No account linked'),
          subtitle: Text(
            'Account is optional. You can save without one.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ),
      );
    }

    // Look up explicitly, then fall back to first. Null-safe — no orElse hack.
    final BankAccount? selected = _selectedAccountId == null
        ? accounts.first
        : accounts.firstWhereOrNull((a) => a.id == _selectedAccountId);
    return AppCard(
      child: ListTile(
        leading: const Icon(Icons.account_balance_outlined),
        title: Text(selected?.name ?? 'Choose account'),
        subtitle: const Text('Where the money moved'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
                final picked = await showModalBottomSheet<String?>(
                  context: context,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (_) => SafeArea(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          title: const Text('No account'),
                          onTap: () => Navigator.pop(context, null),
                        ),
                        ...accounts.map((a) => ListTile(
                              title: Text(a.name),
                              subtitle: Text(a.bank),
                              onTap: () => Navigator.pop(context, a.id),
                            )),
                      ],
                    ),
                  ),
                );
                setState(() => _selectedAccountId = picked);
              },
      ),
    );
  }

  /// Per-field confidence signals — small inline indicators showing
  /// which extracted fields look reliable vs. need a second look.
  /// Tied to extraction source (keyword match vs fallback regex), not
  /// just presence — so a guessed merchant doesn't display as confident.
  Widget _fieldSignals(ColorScheme cs) {
    final amountOk = widget.parsed.amount > 0;
    // Merchant is "confident" only when extracted via explicit keyword
    // ("paid to X" / "received from X"). Bare-preposition matches ("to X",
    // "at X") get the warning state.
    final merchantOk = widget.parsed.merchant != null &&
        widget.parsed.merchant!.trim().isNotEmpty &&
        widget.parsed.merchantSource == 'keyword';
    // Type is confident only when a direction keyword was found
    // (debited/paid/credited/received). Defaults are not confident.
    final typeOk = widget.parsed.hasDirectionSignal;

    final items = <_FieldSignal>[
      _FieldSignal('Amount', amountOk),
      _FieldSignal('Merchant', merchantOk),
      _FieldSignal('Type', typeOk),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: items.map((s) => _signalChip(s, cs)).toList(),
    );
  }

  Widget _signalChip(_FieldSignal s, ColorScheme cs) {
    final color = s.ok ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            s.ok ? Icons.check_rounded : Icons.error_outline_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            s.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detectedRow(ColorScheme cs) {
    final chips = <Widget>[];
    if (widget.parsed.amount > 0) {
      chips.add(_chip('₹${AppFormat.currency(widget.parsed.amount)}',
          Icons.payments_outlined, cs));
    }
    if (widget.parsed.method != null) {
      chips.add(_chip(widget.parsed.method!.toUpperCase(),
          Icons.swap_horiz_rounded, cs));
    }
    if (widget.parsed.bankName != null) {
      chips.add(_chip(widget.parsed.bankName!, Icons.account_balance, cs));
    }
    if (widget.parsed.last4 != null) {
      chips.add(_chip('••${widget.parsed.last4}', Icons.credit_card, cs));
    }
    if (widget.parsed.refId != null) {
      chips.add(
          _chip('Ref ${widget.parsed.refId}', Icons.tag_outlined, cs));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _chip(String text, IconData icon, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
        ],
      ),
    );
  }

  /// Soft hint that surfaces when the parsed merchant has a recurring
  /// history. Shows periodicity, average amount, and the next-expected
  /// date so the user has a quick "yes, this is my Netflix" signal —
  /// no action wired, purely an awareness chip.
  ///
  /// The next-date format adapts to periodicity:
  ///   Monthly → "next 28 May"     (calendar day + month)
  ///   Weekly  → "next Tue"        (weekday name)
  ///   Daily   → "tomorrow"        (relative)
  Widget _recurringChip(ColorScheme cs, RecurringPattern p) {
    final periodicity = p.periodicity.label;
    final amount = AppFormat.currency(p.averageAmount);
    final nextLabel = _formatNextExpected(p);
    return Row(
      children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: cs.tertiaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: cs.tertiary.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, size: 14, color: cs.tertiary),
              const SizedBox(width: 6),
              Text(
                '$periodicity $amount · $nextLabel',
                style: TextStyle(
                  color: cs.onTertiaryContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Pick the format that best fits the periodicity. Calendar day for
  /// monthly, weekday name for weekly, relative for daily. Each
  /// answer is the most useful single thing for that cadence.
  String _formatNextExpected(RecurringPattern p) {
    switch (p.periodicity) {
      case RecurringPeriodicity.monthly:
        return 'next ${p.nextExpected.day} ${_monthAbbr[p.nextExpected.month - 1]}';
      case RecurringPeriodicity.weekly:
        return 'next ${_weekdayAbbr[p.nextExpected.weekday - 1]}';
      case RecurringPeriodicity.daily:
        return 'tomorrow';
      case RecurringPeriodicity.irregular:
        return '';
    }
  }

  /// Compact month/weekday names. Inline rather than via intl so we
  /// keep the chip dependency-light — it's a single short variant.
  static const _monthAbbr = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdayAbbr = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  /// Anomaly chip: surfaces when the current amount is significantly
  /// off the merchant's recurring-pattern average. Uses the error
  /// container color to register as a soft warning (not an alarm —
  /// the user might be intentionally making a larger purchase).
  ///
  /// Label tiers reflect signed drift magnitude rather than a flat
  /// ↑/↓ arrow, so the chip reads honestly:
  ///   drift ≥ 1.0   → "Significantly higher · avg ₹X"
  ///   drift ≥ 0.5   → "Higher than usual · avg ₹X"
  ///   drift ≤ -0.7  → "Significantly lower · avg ₹X"
  ///   drift ≤ -0.5  → "Lower than usual · avg ₹X"
  Widget _anomalyChip(
      ColorScheme cs, RecurringPattern p, double currentAmount) {
    final avg = AppFormat.currency(p.averageAmount);
    final drift = (currentAmount - p.averageAmount) / p.averageAmount;
    final label = _anomalyLabel(drift);
    return Row(
      children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: cs.errorContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: cs.error.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: cs.error),
              const SizedBox(width: 6),
              Text(
                '$label · avg $avg',
                style: TextStyle(
                  color: cs.onErrorContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Maps a signed drift ratio to a human-readable severity label.
  /// Tiered so a 1.5x charge ("significantly higher") doesn't read
  /// the same as a 0.6x charge ("higher than usual"). The 0.7 floor
  /// for "significantly lower" mirrors the 1.0 ceiling for
  /// "significantly higher" on the multiplicative scale (1.0 / 1.7
  /// ≈ 0.59 — i.e. paying ~60% less).
  String _anomalyLabel(double drift) {
    if (drift >= 1.0) return 'Significantly higher';
    if (drift >= 0.5) return 'Higher than usual';
    if (drift <= -0.7) return 'Significantly lower';
    if (drift <= -0.5) return 'Lower than usual';
    return 'Unusual amount';
  }
}

class _FieldSignal {
  final String label;
  final bool ok;
  const _FieldSignal(this.label, this.ok);
}
