import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/review_queue/providers/review_providers.dart';
import '../../models/review_item.dart';
import '../../services/retention_events.dart';
import '../../services/retention_service.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../shared/widgets/error_state_widget.dart';
import '../../utils/app_format.dart';

class ReviewQueueScreen extends ConsumerStatefulWidget {
  const ReviewQueueScreen({super.key});

  @override
  ConsumerState<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends ConsumerState<ReviewQueueScreen> {
  final Set<String> _selected = {};
  bool get _isSelectionMode => _selected.isNotEmpty;

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _selectAll(List<ReviewItem> items) {
    setState(() => _selected.addAll(items.map((e) => e.id)));
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final queueAsync = ref.watch(reviewQueueProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              )
            : null,
        title: Text(_isSelectionMode
            ? '${_selected.length} selected'
            : 'Review Queue'),
        actions: [
          queueAsync.when(
            data: (items) {
              if (_isSelectionMode) {
                return Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.select_all),
                      tooltip: 'Select all',
                      onPressed: () => _selectAll(items),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: 'Approve selected',
                      onPressed: () => _bulkApproveSelected(items),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Reject selected',
                      onPressed: () => _bulkRejectSelected(items),
                    ),
                  ],
                );
              }
              return items.length > 1
                  ? PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'approve_all') {
                          _confirmBulkApprove(context, ref, items.length);
                        } else if (value == 'reject_all') {
                          _confirmRejectAll(context, ref, items.length);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'approve_all', child: Text('Approve All')),
                        PopupMenuItem(
                            value: 'reject_all', child: Text('Reject All')),
                      ],
                    )
                  : const SizedBox.shrink();
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: queueAsync.when(
        loading: () => const SkeletonLoader.transactions(),
        error: (error, _) => ErrorStateWidget(
          error: error,
          onRetry: () => ref.invalidate(reviewQueueProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyStateWidget(
              icon: Icons.check_circle_outline_rounded,
              title: 'All clear!',
              description: 'No transactions to review.',
            );
          }

          // Detect smart batch suggestions: same merchant appearing 2+ times
          final smartSuggestion = _detectSmartGroup(items);

          return Column(
            children: [
              if (!_isSelectionMode)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  color: cs.surfaceContainerHigh,
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${items.length} transaction${items.length == 1 ? '' : 's'} need your review. '
                          'Long-press to select multiple.',
                          style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              if (smartSuggestion != null && !_isSelectionMode)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: cs.primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          size: 18, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${smartSuggestion.count} similar ${smartSuggestion.merchant} transactions found',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selected.addAll(smartSuggestion.ids);
                          });
                        },
                        child: const Text('Select all',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _ReviewCard(
                      item: item,
                      isSelected: _selected.contains(item.id),
                      isSelectionMode: _isSelectionMode,
                      onSelect: () => _toggleSelect(item.id),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Detect groups of similar items (same normalized merchant, 2+ occurrences).
  _SmartGroup? _detectSmartGroup(List<ReviewItem> items) {
    final byMerchant = <String, List<ReviewItem>>{};
    for (final item in items) {
      final m = item.parsed.merchant?.toLowerCase().trim();
      if (m == null || m.isEmpty) continue;
      byMerchant.putIfAbsent(m, () => []).add(item);
    }
    final candidates = byMerchant.entries
        .where((e) => e.value.length >= 2)
        .toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    if (candidates.isEmpty) return null;
    final top = candidates.first;
    return _SmartGroup(
      merchant: top.value.first.parsed.merchant!,
      count: top.value.length,
      ids: top.value.map((i) => i.id).toList(),
    );
  }

  Future<void> _bulkApproveSelected(List<ReviewItem> items) async {
    final selected = items.where((i) => _selected.contains(i.id)).toList();
    if (selected.isEmpty) return;
    final approve = ref.read(approveReviewProvider);
    for (final item in selected) {
      await approve(item);
      RetentionEvents.instance.log(RetentionEvent.reviewItemApproved);
    }
    if (mounted) {
      RetentionService.rewardAction(
        context: context,
        points: selected.length * 3,
        message: '${selected.length} approved — keeping you on track',
      );
    }
    _clearSelection();
  }

  Future<void> _bulkRejectSelected(List<ReviewItem> items) async {
    final selected = items.where((i) => _selected.contains(i.id)).toList();
    if (selected.isEmpty) return;
    final reject = ref.read(rejectReviewProvider);
    for (final item in selected) {
      await reject(item.id);
      RetentionEvents.instance.log(RetentionEvent.reviewItemRejected);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selected.length} rejected')),
      );
    }
    _clearSelection();
  }

  Future<void> _confirmBulkApprove(
      BuildContext context, WidgetRef ref, int count) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve All?'),
        content:
            Text('Auto-insert $count transactions with detected settings?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve All')),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(bulkApproveReviewProvider)();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count transactions approved')),
        );
      }
    }
  }

  Future<void> _confirmRejectAll(
      BuildContext context, WidgetRef ref, int count) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject All?'),
        content: Text('Discard $count pending transactions?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reject All')),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(rejectAllReviewProvider)();
    }
  }
}

class _ReviewCard extends ConsumerStatefulWidget {
  final ReviewItem item;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onSelect;

  const _ReviewCard({
    required this.item,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onSelect,
  });

  @override
  ConsumerState<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends ConsumerState<_ReviewCard> {
  bool _showWhyDetected = false;

  @override
  void initState() {
    super.initState();
    // Observation: review item shown — only when truly on screen.
    // Defer to post-frame so we know the widget has been laid out, then
    // verify it's within the viewport before logging.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isOnScreen(context)) {
        RetentionEvents.instance.log(
          RetentionEvent.reviewItemShown,
          dedupeKey: widget.item.id,
        );
      }
    });
  }

  /// True if this card's render box overlaps the screen viewport.
  /// Guards against ListView pre-building offscreen items.
  bool _isOnScreen(BuildContext ctx) {
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached) return false;
    final size = MediaQueryData.fromView(View.of(ctx)).size;
    final topLeft = box.localToGlobal(Offset.zero);
    final cardHeight = box.size.height;
    // Visible if any part of the card overlaps the screen vertically
    return topLeft.dy + cardHeight > 0 && topLeft.dy < size.height;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final parsed = item.parsed;
    final cs = Theme.of(context).colorScheme;
    final isExpense = !parsed.isCredit;
    final amountColor = isExpense ? cs.error : Colors.green;

    final confidencePct = (item.confidence * 100).round();
    final (confLabel, confColor) = _confidenceInfo(item.confidence, cs);
    final reasonLabel = _reviewReason(item);
    final kindLabel = _methodLabel(parsed.method);

    return Card(
      color: widget.isSelected
          ? cs.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        onTap: widget.isSelectionMode ? widget.onSelect : null,
        onLongPress: widget.onSelect,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.isSelectionMode)
                Row(
                  children: [
                    Icon(
                      widget.isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: widget.isSelected ? cs.primary : cs.outline,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.isSelected ? 'Selected' : 'Tap to select',
                      style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              if (widget.isSelectionMode) const SizedBox(height: 8),

              // Why this is here (trust signal) — clickable
              GestureDetector(
                onTap: () => setState(() => _showWhyDetected = !_showWhyDetected),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.help_outline,
                          size: 13, color: Colors.amber),
                      const SizedBox(width: 4),
                      Text(reasonLabel,
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.amber,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 4),
                      Icon(
                          _showWhyDetected
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 14,
                          color: Colors.amber),
                    ],
                  ),
                ),
              ),

              // Why detected — explainability panel
              if (_showWhyDetected)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _explanationPoints(parsed)
                        .map((p) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text('• ',
                                      style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                          fontSize: 11)),
                                  Expanded(
                                    child: Text(p,
                                        style: TextStyle(
                                            color: cs.onSurfaceVariant,
                                            fontSize: 11,
                                            height: 1.4)),
                                  ),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ),

              // Amount + type badge + confidence
              Row(
                children: [
                  Icon(
                      isExpense
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      color: amountColor,
                      size: 20),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${isExpense ? "-" : "+"} ${AppFormat.currency(parsed.amount)}',
                      style: TextStyle(
                          color: amountColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 18),
                    ),
                  ),
                  if (kindLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(kindLabel,
                          style: TextStyle(
                              fontSize: 9,
                              color: cs.primary,
                              fontWeight: FontWeight.w600)),
                    ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: confColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$confidencePct% $confLabel',
                        style: TextStyle(
                            color: confColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              if (parsed.merchant != null && parsed.merchant!.isNotEmpty)
                _fieldRow(context, Icons.store, 'Merchant', parsed.merchant!),
              if (parsed.bankName != null)
                _fieldRow(context, Icons.account_balance, 'Bank',
                    parsed.bankName!),
              if (parsed.last4 != null)
                _fieldRow(context, Icons.credit_card, 'Account',
                    '••••${parsed.last4}'),
              _fieldRow(context, Icons.calendar_today, 'Date',
                  AppFormat.date(parsed.date)),

              const SizedBox(height: 8),

              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  parsed.rawText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: cs.onSurfaceVariant, fontSize: 11, height: 1.4),
                ),
              ),

              const SizedBox(height: 12),

              // Quick-fix chips for common rejection reasons
              if (!widget.isSelectionMode)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _quickChip(context, 'Recharge', Icons.phone_iphone,
                        () => _rejectWithReason('recharge')),
                    _quickChip(context, 'Promotion', Icons.campaign,
                        () => _rejectWithReason('promotion')),
                    _quickChip(context, 'OTP', Icons.lock,
                        () => _rejectWithReason('otp')),
                    _quickChip(context, 'Other', Icons.close,
                        () => _rejectWithReason('other')),
                  ],
                ),
              if (!widget.isSelectionMode) const SizedBox(height: 12),

              // Actions
              if (!widget.isSelectionMode)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          ref.read(rejectReviewProvider)(item.id);
                          RetentionEvents.instance
                              .log(RetentionEvent.reviewItemRejected);
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('Reject'),
                        style:
                            OutlinedButton.styleFrom(foregroundColor: cs.error),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () async {
                          await ref.read(approveReviewProvider)(item);
                          RetentionEvents.instance
                              .log(RetentionEvent.reviewItemApproved);
                          if (context.mounted) {
                            RetentionService.rewardAction(
                              context: context,
                              points: 3,
                              message:
                                  'Approved — system learned a new pattern',
                              hint: item.parsed.merchant,
                            );
                          }
                        },
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Approve'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _rejectWithReason(String reason) async {
    ref.read(rejectReviewProvider)(widget.item.id);
    RetentionEvents.instance.log(RetentionEvent.reviewItemRejected);
    // Persist learned-filter count for visibility
    final prefs = await SharedPreferences.getInstance();
    final key = 'learned_filter_$reason';
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + 1);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✓ Learned: $reason messages → ignore'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _quickChip(
      BuildContext context, String label, IconData icon, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(icon, size: 14, color: cs.onSurfaceVariant),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }

  Widget _fieldRow(
      BuildContext context, IconData icon, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          SizedBox(
            width: 65,
            child: Text(label,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  (String, Color) _confidenceInfo(double conf, ColorScheme cs) {
    if (conf >= 0.70) return ('High', Colors.green);
    if (conf >= 0.50) return ('Medium', Colors.orange);
    return ('Low', cs.error);
  }

  String _reviewReason(ReviewItem item) {
    if (item.confidence < 0.50) return 'Very low confidence — needs verification';
    if (item.confidence < 0.70) return 'Medium confidence — please verify';
    if (item.parsed.merchant == null) return 'Merchant not detected';
    if (item.parsed.last4 == null) return 'Account not identified';
    return 'Flagged for review';
  }

  /// Plain-English explanation. Reads like trust signals, not debug output.
  List<String> _explanationPoints(ParsedTransaction parsed) {
    final points = <String>[];
    points.add(parsed.isCredit
        ? 'This looks like money you received'
        : 'This looks like money you paid');
    points.add('I found ${AppFormat.currency(parsed.amount)}');
    if (parsed.merchant != null && parsed.merchant!.isNotEmpty) {
      points.add('It looks like ${parsed.merchant}');
    } else {
      points.add('I couldn\'t tell who this was paid to');
    }
    if (parsed.bankName != null) {
      points.add('Bank: ${parsed.bankName}');
    }
    if (parsed.last4 != null) {
      points.add('Account ending in ${parsed.last4}');
    }
    final pct = (parsed.confidence * 100).toStringAsFixed(0);
    points.add('I\'m $pct% sure — that\'s why I asked you to confirm');
    return points;
  }

  String? _methodLabel(String? method) {
    if (method == null) return null;
    return switch (method.toLowerCase()) {
      'upi' => 'UPI',
      'card' => 'Card',
      'bank' => 'Bank',
      'cash' => 'Cash',
      _ => null,
    };
  }
}


class _SmartGroup {
  final String merchant;
  final int count;
  final List<String> ids;
  const _SmartGroup({
    required this.merchant,
    required this.count,
    required this.ids,
  });
}
