import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// A single classification rule.
///
/// Scoring:
///   - merchant alias hit: +0.6 (strongest)
///   - keyword hit:        +0.3
///   - multiple hits:      sum, capped at 1.0
class CategoryRule {
  final String category;
  final List<String> merchantPatterns;
  final List<String> keywords;
  final double weight;

  const CategoryRule({
    required this.category,
    this.merchantPatterns = const [],
    this.keywords = const [],
    this.weight = 1.0,
  });
}

/// Multi-signal deterministic category classifier with learning layer.
///
/// Strategy:
///   1. Look up learned (signature → category) memory — strongest
///   2. Score each [CategoryRule] against (merchant, normalized text)
///   3. Return highest score, or null if everything scored zero
///
/// Pure rule-based — no ML, no network. User corrections compound via
/// [learn]. Designed to be sub-5ms after JIT warm-up.
class SmartCategoryClassifier {
  SmartCategoryClassifier._();
  static final instance = SmartCategoryClassifier._();

  /// Highest-precision rules (start small; grow with usage data).
  /// Order doesn't matter — we score all and pick the max.
  static final List<CategoryRule> _rules = [
    // ── Expense ────────────────────────────────────────────────
    CategoryRule(
      category: 'Food',
      merchantPatterns: [
        'swiggy', 'zomato', 'dominos', 'kfc', 'mcdonald', 'starbucks',
        'haldiram', 'barbeque nation', 'chaayos', 'subway', 'pizza hut',
        'ccd', 'chicking',
      ],
      keywords: [
        'food', 'order', 'restaurant', 'cafe', 'biryani', 'pizza',
        'burger', 'dosa', 'idli', 'thali', 'lunch', 'dinner',
        'breakfast', 'meal', 'parcel', 'takeaway', 'snack',
      ],
    ),
    CategoryRule(
      category: 'Groceries',
      merchantPatterns: [
        'blinkit', 'zepto', 'instamart', 'bigbasket', 'dmart', 'jiomart',
        'spencers', 'reliance fresh', 'country delight', 'amul',
      ],
      keywords: [
        'grocery', 'groceries', 'supermarket', 'kirana', 'vegetables',
        'fruits', 'milk', 'eggs', 'rice', 'atta', 'provisions',
      ],
    ),
    CategoryRule(
      category: 'Transport',
      merchantPatterns: [
        'uber', 'ola', 'rapido', 'irctc', 'redbus', 'metro',
      ],
      keywords: [
        'ride', 'trip', 'cab', 'taxi', 'auto', 'rickshaw', 'fuel',
        'petrol', 'diesel', 'parking', 'toll', 'fastag', 'metro',
        'bus', 'train', 'commute', 'ticket',
      ],
    ),
    CategoryRule(
      category: 'Shopping',
      merchantPatterns: [
        'amazon', 'flipkart', 'myntra', 'meesho', 'ajio', 'nykaa',
        'tata cliq', 'snapdeal', 'croma', 'reliance digital',
      ],
      keywords: [
        'shopping', 'order', 'purchase', 'apparel', 'clothes', 'shoes',
        'electronics', 'gadget', 'accessories',
      ],
    ),
    CategoryRule(
      category: 'Bills',
      keywords: [
        'electricity', 'water', 'gas', 'bill', 'recharge', 'broadband',
        'wifi', 'internet', 'postpaid', 'prepaid', 'dth', 'mobile bill',
        'phone bill', 'landline', 'mseb', 'bescom', 'tneb',
      ],
    ),
    CategoryRule(
      category: 'Subscriptions',
      merchantPatterns: [
        'netflix', 'spotify', 'hotstar', 'youtube', 'prime', 'sonyliv',
        'zee5', 'jiocinema', 'apple', 'icloud', 'chatgpt', 'notion',
      ],
      keywords: ['subscription', 'membership', 'renewal', 'premium'],
    ),
    CategoryRule(
      category: 'Entertainment',
      merchantPatterns: [
        'bookmyshow', 'pvr', 'inox',
      ],
      keywords: [
        'movie', 'cinema', 'concert', 'event', 'ticket', 'gaming',
        'pub', 'bar', 'club',
      ],
    ),
    CategoryRule(
      category: 'Travel',
      merchantPatterns: [
        'makemytrip', 'goibibo', 'cleartrip', 'yatra', 'ixigo',
        'oyo', 'airbnb', 'indigo', 'spicejet', 'vistara', 'air india',
      ],
      keywords: [
        'flight', 'hotel', 'booking', 'vacation', 'holiday', 'trip',
        'tour', 'visa', 'resort',
      ],
    ),
    CategoryRule(
      category: 'Health',
      merchantPatterns: [
        'apollo', 'medplus', 'netmeds', 'pharmeasy', '1mg', 'practo',
        'tata health',
      ],
      keywords: [
        'pharmacy', 'medicine', 'doctor', 'hospital', 'clinic', 'lab',
        'medical', 'health', 'gym', 'fitness',
      ],
    ),
    CategoryRule(
      category: 'Rent',
      keywords: [
        'rent', 'house rent', 'flat rent', 'pg', 'hostel', 'maintenance',
        'society', 'landlord', 'lease',
      ],
    ),

    // ── Income ─────────────────────────────────────────────────
    CategoryRule(
      category: 'Salary',
      keywords: [
        'salary', 'payroll', 'monthly salary', 'pay credit', 'wage',
        'stipend', 'compensation', 'ctc',
      ],
    ),
    CategoryRule(
      category: 'Refund',
      keywords: [
        'refund', 'reversal', 'cashback', 'reimbursement',
      ],
    ),
    CategoryRule(
      category: 'Investment',
      merchantPatterns: ['zerodha', 'groww', 'kuvera', 'smallcase'],
      keywords: [
        'dividend', 'interest', 'mutual fund', 'sip', 'fd maturity',
      ],
    ),
  ];

  // ── Learning layer ──────────────────────────────────────────────

  static const _kKey = 'category_memory_v1';
  static const _maxEntries = 200;
  static const _signatureTokenCount = 12;

  Map<String, _LearnedCategory>? _cache;

  /// Signature = first 12 normalized text tokens + `|merchant`.
  /// Including merchant prevents collision when two screenshots share
  /// boilerplate ("Paid from CC ...") but differ in payee.
  String _buildSignature(String rawText, String? merchant) {
    final normalized = rawText
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final base = normalized
        .split(' ')
        .where((t) => t.length >= 3)
        .take(_signatureTokenCount)
        .join(' ');
    final m = merchant?.trim().toLowerCase() ?? '';
    if (base.isEmpty && m.isEmpty) return '';
    return m.isEmpty ? base : '$base|$m';
  }

  /// Look up a learned category. Returns null if no match.
  Future<String?> checkLearned({
    required String rawText,
    String? merchant,
  }) async {
    final sig = _buildSignature(rawText, merchant);
    if (sig.isEmpty) return null;
    final cache = await _load();
    return cache[sig]?.category;
  }

  /// Persist a (rawText/merchant → category) mapping after user confirms.
  Future<void> learn({
    required String rawText,
    String? merchant,
    required String category,
  }) async {
    if (category.trim().isEmpty) return;
    final sig = _buildSignature(rawText, merchant);
    if (sig.isEmpty) return;
    try {
      final cache = await _load();
      final existing = cache[sig];
      cache[sig] = _LearnedCategory(
        signature: sig,
        category: category,
        frequency: (existing?.category == category)
            ? existing!.frequency + 1
            : 1,
        updatedAt: DateTime.now(),
      );
      // FIFO eviction
      if (cache.length > _maxEntries) {
        final entries = cache.entries.toList()
          ..sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));
        final toRemove = entries.length - _maxEntries;
        for (var i = 0; i < toRemove; i++) {
          cache.remove(entries[i].key);
        }
      }
      await _persist(cache);
    } catch (e) {
      debugPrint('[SmartCategoryClassifier] learn failed: $e');
    }
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
    _cache = null;
  }

  Future<int> count() async => (await _load()).length;

  Future<Map<String, _LearnedCategory>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null) {
      _cache = <String, _LearnedCategory>{};
      return _cache!;
    }
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final loaded = decoded.map(
        (k, v) =>
            MapEntry(k, _LearnedCategory.fromMap(v as Map<String, dynamic>)),
      );
      // Frequency decay — entries not touched in >30 days lose 1 frequency
      // each load. Prevents long-stale mappings from dominating forever.
      // Entries that decay below 1 are dropped on the next persist.
      final now = DateTime.now();
      final decayed = <String, _LearnedCategory>{};
      loaded.forEach((k, v) {
        if (v.frequency > 5 &&
            now.difference(v.updatedAt).inDays > 30) {
          decayed[k] = v.copyWith(frequency: v.frequency - 1);
        } else {
          decayed[k] = v;
        }
      });
      _cache = decayed;
      return _cache!;
    } catch (e) {
      debugPrint('[SmartCategoryClassifier] load failed: $e');
      _cache = <String, _LearnedCategory>{};
      return _cache!;
    }
  }

  Future<void> _persist(Map<String, _LearnedCategory> cache) async {
    _cache = cache;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey,
        jsonEncode(cache.map((k, v) => MapEntry(k, v.toMap()))));
  }

  // ── Rule-based scoring ──────────────────────────────────────────

  /// Tier breaks ties when two rules score equally. Bills/Food/Transport
  /// are essentials and should win over Shopping when signals overlap
  /// (e.g. "Amazon Pay electricity bill" → Bills, not Shopping).
  static const Map<String, int> _categoryPriority = {
    'Bills': 3,
    'Rent': 3,
    'Health': 3,
    'Food': 3,
    'Groceries': 3,
    'Transport': 3,
    'Salary': 3,
    'Refund': 3,
    'Investment': 3,
    'Subscriptions': 2,
    'Shopping': 2,
    'Travel': 2,
    'Entertainment': 2,
  };

  /// Score every rule and return the winner. Caller normalizes text once.
  ///
  /// [normalized] should be lowercased and stripped — no need to re-normalize.
  /// [merchantLower] — pass `merchant?.toLowerCase()` once, not per-rule.
  /// [merchantSource] — when 'learned' or 'body_strong' AND we get a merchant
  ///                    hit on a rule, that rule wins outright (dominance
  ///                    rule). Prevents keyword noise like "electricity"
  ///                    from overriding a strong "Amazon" merchant signal.
  String? classifyRulesOnly({
    required String normalized,
    String? merchantLower,
    String? merchantSource,
  }) {
    if (normalized.isEmpty && (merchantLower ?? '').isEmpty) return null;

    final isMerchantStrong = merchantSource == 'learned' ||
        merchantSource == 'body_strong';

    String? winner;
    double winnerScore = 0;
    for (final rule in _rules) {
      double score = 0;
      bool merchantHit = false;
      // Merchant signal — strongest
      if (merchantLower != null && merchantLower.isNotEmpty) {
        for (final m in rule.merchantPatterns) {
          if (merchantLower.contains(m)) {
            score += 0.6;
            merchantHit = true;
            break; // one hit per rule is enough
          }
        }
      }
      // Keyword signal
      for (final k in rule.keywords) {
        if (normalized.contains(k)) {
          score += 0.3;
          break; // diminishing returns past one hit
        }
      }
      score *= rule.weight;

      // Dominance rule: if we have a strong merchant identity AND this rule
      // matched that merchant by alias, return immediately. Don't let a
      // mismatched keyword in the body override.
      if (isMerchantStrong && merchantHit) {
        return rule.category;
      }

      if (score > winnerScore) {
        winnerScore = score;
        winner = rule.category;
      } else if (score == winnerScore && winner != null && score > 0) {
        // Tie-break by priority tier
        final aP = _categoryPriority[winner] ?? 1;
        final bP = _categoryPriority[rule.category] ?? 1;
        if (bP > aP) winner = rule.category;
      }
    }
    return winner;
  }

  /// Full classification pipeline: learning → rule-based scoring.
  /// Returns null if neither produced a winner.
  Future<String?> classify({
    required String rawText,
    String? merchant,
    String? merchantSource,
  }) async {
    final learned =
        await checkLearned(rawText: rawText, merchant: merchant);
    if (learned != null) return learned;
    final normalized = rawText
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return classifyRulesOnly(
      normalized: normalized,
      merchantLower: merchant?.toLowerCase(),
      merchantSource: merchantSource,
    );
  }
}

class _LearnedCategory {
  final String signature;
  final String category;
  final int frequency;
  final DateTime updatedAt;

  const _LearnedCategory({
    required this.signature,
    required this.category,
    required this.frequency,
    required this.updatedAt,
  });

  _LearnedCategory copyWith({
    String? signature,
    String? category,
    int? frequency,
    DateTime? updatedAt,
  }) =>
      _LearnedCategory(
        signature: signature ?? this.signature,
        category: category ?? this.category,
        frequency: frequency ?? this.frequency,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'signature': signature,
        'category': category,
        'frequency': frequency,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory _LearnedCategory.fromMap(Map<String, dynamic> m) =>
      _LearnedCategory(
        signature: m['signature'] as String,
        category: m['category'] as String,
        frequency: (m['frequency'] as num?)?.toInt() ?? 1,
        updatedAt: DateTime.parse(m['updatedAt'] as String),
      );
}
