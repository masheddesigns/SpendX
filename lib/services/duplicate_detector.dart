import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/review_item.dart';
import '../models/transaction.dart';

/// Outcome of a duplicate check. The UI decides how to present each tier.
///
/// `none`     → save without prompting
/// `exact`    → show "This looks like a duplicate" (instant decision)
/// `probable` → show "Similar transaction found …" with the score so the
///              user has the context to override (e.g. two ₹500 Zomato
///              orders 12 minutes apart can be legitimate)
enum DuplicateKind { none, exact, probable }

class DuplicateResult {
  final DuplicateKind kind;
  final double score; // 0..1, only meaningful for probable
  final TransactionFingerprint? match;

  const DuplicateResult._(this.kind, this.score, this.match);

  factory DuplicateResult.none() =>
      const DuplicateResult._(DuplicateKind.none, 0, null);
  factory DuplicateResult.exact(TransactionFingerprint match) =>
      DuplicateResult._(DuplicateKind.exact, 1.0, match);
  factory DuplicateResult.probable(
          TransactionFingerprint match, double score) =>
      DuplicateResult._(DuplicateKind.probable, score, match);

  bool get isDuplicate => kind != DuplicateKind.none;
}

/// Compact representation of a transaction for fast comparison.
///
/// Stores only the dimensions that matter for dedup. Three precomputed
/// hashes drive Stage-1 lookups in increasing tolerance order:
///   * [signatureHash]      — identity (amount/merchant/date/last4)
///   * [rawTextHash]        — exact OCR/share-text bytes
///   * [normalizedTextHash] — OCR text after lowercasing, whitespace
///                            collapse, and non-alphanumeric strip
///
/// The normalized hash catches the same screenshot processed under
/// slightly different OCR conditions (extra whitespace, punctuation
/// noise, casing flicker) — strictly more forgiving than the raw hash
/// while still being O(1) on lookup.
class TransactionFingerprint {
  final double amount;
  final String? merchant;
  final DateTime? date;
  final String? last4;
  final String? method;
  final String? refId;
  final int signatureHash;

  /// Hash of the original share/OCR text. Null for fingerprints built
  /// from persisted transactions (we don't store rawText in the DB),
  /// in which case Stage-1 falls back to [signatureHash] only.
  final int? rawTextHash;

  /// Hash of the rawText after lowercasing, whitespace collapse, and
  /// non-alphanumeric strip. Catches OCR variance that breaks
  /// [rawTextHash] equality (extra punctuation, casing, spacing).
  final int? normalizedTextHash;

  TransactionFingerprint({
    required this.amount,
    required this.signatureHash,
    this.merchant,
    this.date,
    this.last4,
    this.method,
    this.refId,
    this.rawTextHash,
    this.normalizedTextHash,
  });

  /// Build from the parser's [ParsedTransaction]. Used to fingerprint a
  /// candidate BEFORE save so the duplicate check can run during preview.
  factory TransactionFingerprint.fromParsed(ParsedTransaction tx) {
    final raw = tx.rawText.trim();
    final normalized =
        raw.isEmpty ? null : DuplicateDetector.normalizeText(raw);
    return TransactionFingerprint(
      amount: tx.amount,
      signatureHash: DuplicateDetector.buildExactSignature(
        amount: tx.amount,
        merchant: tx.merchant,
        date: tx.date,
        last4: tx.last4,
      ).hashCode,
      merchant: tx.merchant,
      date: tx.date,
      last4: tx.last4,
      method: tx.method,
      refId: tx.refId,
      rawTextHash: raw.isEmpty ? null : raw.hashCode,
      normalizedTextHash:
          normalized == null || normalized.isEmpty ? null : normalized.hashCode,
    );
  }

  /// Build from a persisted [Transaction]. Used both to seed the cache
  /// from repo lookups and to fingerprint just-saved transactions for
  /// the in-memory window.
  factory TransactionFingerprint.fromTransaction(Transaction tx) {
    // Notes is the only place we have a merchant signal post-save —
    // merchant gets written into notes by the import flow.
    final merchant = tx.notes.trim().isEmpty ? null : tx.notes.trim();
    return TransactionFingerprint(
      amount: tx.amount,
      signatureHash: DuplicateDetector.buildExactSignature(
        amount: tx.amount,
        merchant: merchant,
        date: tx.date,
        last4: null,
      ).hashCode,
      merchant: merchant,
      date: tx.date,
      refId: tx.externalRef,
    );
  }
}

/// Two-stage duplicate detection:
///   Stage 1 — exact-signature hash lookup, O(1)
///   Stage 2 — fuzzy similarity scan over a sliding window, O(n) with n
///             bounded at [_windowSize]
///
/// The detector is intentionally in-memory only. Most duplicates happen
/// within seconds of each other (re-share, double-tap, accidental retry)
/// so a recent-fingerprint window catches the overwhelming majority of
/// cases at zero cost. Older history is covered by an outer repo lookup
/// the caller is free to layer on top — this service stays fast and pure.
class DuplicateDetector {
  DuplicateDetector._();
  static final instance = DuplicateDetector._();

  /// Maximum recent transactions kept in memory. 200 covers ~weeks of
  /// activity for typical users without bloating heap.
  static const _windowSize = 200;

  /// Stage-1 lookup TTL. Past this age, hash-based exact matches are
  /// treated as stale — the candidate falls through to fuzzy Stage-2
  /// instead. Prevents accidental "exact" collisions on reused
  /// screenshots / similar text shared hours apart that aren't
  /// actually the same transaction. 15 minutes covers the share-flow
  /// repeat window comfortably without holding hashes long enough to
  /// collide with unrelated future shares.
  static const _stage1Ttl = Duration(minutes: 15);

  /// Per-detection log-sampling rate. detect() runs once per save
  /// attempt and at one log per branch can produce a steady trickle
  /// during heavy import sessions; sampling at 20% keeps the signal
  /// visible without flooding the debug console. Release builds drop
  /// debugPrint anyway, so this only affects local development.
  static final Random _logSampler = Random();
  static const double _logSampleRate = 0.2;
  static bool get _logThisCall => _logSampler.nextDouble() < _logSampleRate;

  /// Scoring threshold above which a candidate is treated as a probable
  /// duplicate. 0.7 means: amount-match (0.4) + either (merchant 0.3 +
  /// time 0.2) OR (merchant 0.3 + last4 0.1 + time 0.2). Tuned so that
  /// "same amount within 10 min" alone (0.4 + 0.2 = 0.6) does NOT
  /// trigger — we require a merchant or last4 corroborating signal too.
  static const double duplicateThreshold = 0.7;

  /// Time window for the time-proximity signal (Stage 2). Wider windows
  /// produce more false positives; 10 minutes is the sweet spot for
  /// share-flow timing.
  static const Duration _timeProximity = Duration(minutes: 10);

  // ── Window state ────────────────────────────────────────────────
  // List for ordered FIFO eviction; four maps for O(1) Stage-1
  // lookups in increasing tolerance order:
  //   _byRefId          — UTR/UPI reference (decisive when present)
  //   _bySignature      — identity (amount/merchant/date/last4)
  //   _byRawText        — exact share/OCR bytes
  //   _byNormalizedText — OCR after lowercasing/whitespace/punct strip
  // Window entries wrap the fingerprint with the timestamp it was
  // remembered, so detect() can apply [_stage1Ttl] without mutating
  // the fingerprint type.
  final List<_WindowEntry> _window = [];
  final Map<int, _WindowEntry> _bySignature = {};
  final Map<int, _WindowEntry> _byRawText = {};
  final Map<int, _WindowEntry> _byNormalizedText = {};
  final Map<String, _WindowEntry> _byRefId = {};

  /// Stage 1 + Stage 2 in one call. Pure read — does NOT add the
  /// candidate to the window. Caller invokes [remember] only after the
  /// user confirms save.
  DuplicateResult detect(TransactionFingerprint fp) {
    final now = DateTime.now();

    // Stage 0 — refId match. UTR / UPI references are usually unique
    // per real transaction; a hit is decisive. BUT some payment rails
    // truncate or mask refs (last-N digits, daily-recycling counters)
    // so we add a temporal guard: if the matching entry's date is
    // more than 24 hours from the candidate's date, the refId is
    // almost certainly being reused — fall through to other checks
    // rather than declaring an exact match across days.
    if (fp.refId != null && fp.refId!.isNotEmpty) {
      final byRef = _byRefId[fp.refId];
      if (byRef != null && _refIdTemporalMatch(fp, byRef.fp)) {
        if (_logThisCall) debugPrint('[Duplicate][Exact][RefId]');
        return DuplicateResult.exact(byRef.fp);
      }
    }

    // Stage 1a — exact OCR/share-text re-share. Cheapest, strongest
    // signal for "same screenshot twice" because it bypasses any
    // parsing variance.
    if (fp.rawTextHash != null) {
      final byRaw = _freshOrNull(_byRawText[fp.rawTextHash], now);
      if (byRaw != null) {
        if (_logThisCall) debugPrint('[Duplicate][Exact][RawText]');
        return DuplicateResult.exact(byRaw.fp);
      }
    }

    // Stage 1b — normalized OCR text re-share. Catches the same
    // screenshot processed with slightly different OCR (whitespace,
    // punctuation, casing).
    if (fp.normalizedTextHash != null) {
      final byNorm =
          _freshOrNull(_byNormalizedText[fp.normalizedTextHash], now);
      if (byNorm != null) {
        if (_logThisCall) debugPrint('[Duplicate][Exact][NormalizedText]');
        return DuplicateResult.exact(byNorm.fp);
      }
    }

    // Stage 1c — identity-hash match
    final exact = _freshOrNull(_bySignature[fp.signatureHash], now);
    if (exact != null) {
      if (_logThisCall) debugPrint('[Duplicate][Exact][Signature]');
      return DuplicateResult.exact(exact.fp);
    }

    // Stage 2 — fuzzy similarity. Walks the entire window regardless
    // of TTL so older entries can still surface as probable matches —
    // they just won't claim "exact" status.
    TransactionFingerprint? best;
    double bestScore = 0;
    for (final entry in _window) {
      final score = _similarity(fp, entry.fp);
      if (score > bestScore) {
        bestScore = score;
        best = entry.fp;
      }
    }
    if (best != null && bestScore >= duplicateThreshold) {
      if (_logThisCall) {
        debugPrint('[Duplicate][Probable][Fuzzy] score=${bestScore.toStringAsFixed(2)}');
      }
      return DuplicateResult.probable(best, bestScore);
    }
    return DuplicateResult.none();
  }

  /// Returns the entry only if it's within the Stage-1 TTL. Stale
  /// entries fall through to fuzzy Stage-2 matching, which factors in
  /// time proximity directly via the similarity score.
  _WindowEntry? _freshOrNull(_WindowEntry? entry, DateTime now) {
    if (entry == null) return null;
    if (now.difference(entry.addedAt) > _stage1Ttl) return null;
    return entry;
  }

  /// True when two refId-matching fingerprints look like the same
  /// transaction — i.e. their stored dates are within 24 hours of
  /// each other. Outside that window, a refId collision is almost
  /// certainly a reused/recycled identifier and we should NOT
  /// short-circuit. Conservative default: if either date is missing,
  /// trust the refId match (common case where parsed candidates lack
  /// a date and a same-session re-share legitimately collides).
  static const _refIdTemporalWindow = Duration(hours: 24);
  bool _refIdTemporalMatch(
      TransactionFingerprint candidate, TransactionFingerprint stored) {
    if (candidate.date == null || stored.date == null) return true;
    final gap = candidate.date!.difference(stored.date!).abs();
    return gap <= _refIdTemporalWindow;
  }

  /// Add a confirmed-saved fingerprint to the window. FIFO eviction at
  /// [_windowSize]. Each entry is stamped with the current time so
  /// [_stage1Ttl] can age it out of hash lookups without removing it
  /// from fuzzy matching.
  void remember(TransactionFingerprint fp) {
    if (_bySignature.containsKey(fp.signatureHash)) return;
    final entry = _WindowEntry(fp: fp, addedAt: DateTime.now());
    _window.add(entry);
    _bySignature[fp.signatureHash] = entry;
    if (fp.rawTextHash != null) _byRawText[fp.rawTextHash!] = entry;
    if (fp.normalizedTextHash != null) {
      _byNormalizedText[fp.normalizedTextHash!] = entry;
    }
    if (fp.refId != null && fp.refId!.isNotEmpty) {
      _byRefId[fp.refId!] = entry;
    }
    if (_window.length > _windowSize) {
      final dropped = _window.removeAt(0);
      final droppedFp = dropped.fp;
      // Only drop from the maps if no later entry reuses the same key.
      // Defensive — collisions are vanishingly unlikely but cheap to guard.
      if (_bySignature[droppedFp.signatureHash] == dropped) {
        _bySignature.remove(droppedFp.signatureHash);
      }
      if (droppedFp.rawTextHash != null &&
          _byRawText[droppedFp.rawTextHash!] == dropped) {
        _byRawText.remove(droppedFp.rawTextHash!);
      }
      if (droppedFp.normalizedTextHash != null &&
          _byNormalizedText[droppedFp.normalizedTextHash!] == dropped) {
        _byNormalizedText.remove(droppedFp.normalizedTextHash!);
      }
      if (droppedFp.refId != null &&
          droppedFp.refId!.isNotEmpty &&
          _byRefId[droppedFp.refId!] == dropped) {
        _byRefId.remove(droppedFp.refId!);
      }
    }
  }

  /// Backfill the window from recent persisted transactions. Caller
  /// should invoke this once at app start / first preview so users who
  /// re-share a payment from yesterday still get a duplicate prompt.
  void seedFromRecent(Iterable<Transaction> recent) {
    for (final t in recent) {
      remember(TransactionFingerprint.fromTransaction(t));
    }
  }

  /// Test/data-wipe hook.
  void reset() {
    _window.clear();
    _bySignature.clear();
    _byRawText.clear();
    _byNormalizedText.clear();
    _byRefId.clear();
  }

  int get size => _window.length;

  // ── Signature ───────────────────────────────────────────────────

  /// Build the canonical exact-match string. Pipe-delimited, lowercased
  /// merchant, full-ISO date. The hash of THIS string is the Stage-1
  /// signature key.
  ///
  /// **Date granularity is intentionally full ISO timestamp**, NOT a
  /// truncated day. ₹500 Zomato today and ₹500 Zomato tomorrow MUST
  /// produce different signatures even if every other field matches —
  /// otherwise legitimate same-merchant same-amount transactions on
  /// different days would falsely collide on Stage 1c. This is a
  /// silent but critical correctness boundary; do not "round" the
  /// date here.
  ///
  /// Components:
  ///   amount   → 2-decimal stable representation
  ///   merchant → lowercased + trimmed (or empty)
  ///   date     → full ISO timestamp
  ///   last4    → optional disambiguator
  static String buildExactSignature({
    required double amount,
    String? merchant,
    DateTime? date,
    String? last4,
  }) {
    return [
      amount.toStringAsFixed(2),
      merchant?.toLowerCase().trim() ?? '',
      date?.toIso8601String() ?? '',
      last4 ?? '',
    ].join('|');
  }

  /// Normalize OCR/share text for the looser Stage-1 hash. Same shape
  /// as [MerchantNormalizer.normalizeForMatch] but kept local to avoid
  /// a cross-package dependency: lowercase, strip non-alphanumeric,
  /// collapse whitespace. Two screenshots whose only differences are
  /// noise tokens / punctuation / casing produce identical hashes.
  static String normalizeText(String text) {
    return text
        .toLowerCase()
        .replaceAll(_normalizeStripRe, ' ')
        .replaceAll(_normalizeWsRe, ' ')
        .trim();
  }

  static final RegExp _normalizeStripRe = RegExp(r'[^a-z0-9 ]');
  static final RegExp _normalizeWsRe = RegExp(r'\s+');

  // ── Similarity ──────────────────────────────────────────────────

  /// Weighted similarity, returns 0..1.
  ///   amount       +0.40  strongest single signal
  ///   merchant ✓   +0.30  token overlap match
  ///   merchant ✗   −0.20  both present but no overlap (different
  ///                       payments under similar amounts/times)
  ///   time ≤10min  +0.20  share-flow proximity
  ///   last4        +0.10  when both have it and equal
  ///   refId match  +0.20  near-certain duplicate evidence (UTR/UPI)
  /// Capped at 1.0 / floored at 0.0.
  static double _similarity(
      TransactionFingerprint a, TransactionFingerprint b) {
    double score = 0;

    // Amount — relative tolerance handles ₹999 vs ₹1000 OCR rounding
    // without permitting wildly different amounts to match.
    if (_isAmountNear(a.amount, b.amount)) score += 0.4;

    // Merchant — bidirectional. Strong overlap adds; explicit
    // mismatch (both present, no token overlap) subtracts. The
    // penalty is what stops "Amazon" and "Amazon Pay Later" from
    // collapsing when amount + time + last4 happen to align.
    final aM = a.merchant?.trim() ?? '';
    final bM = b.merchant?.trim() ?? '';
    if (aM.isNotEmpty && bM.isNotEmpty) {
      if (_similarText(aM, bM)) {
        score += 0.3;
      } else {
        score -= 0.2;
      }
    }

    // Time proximity
    if (a.date != null && b.date != null) {
      final diff = a.date!.difference(b.date!).inMinutes.abs();
      if (diff <= _timeProximity.inMinutes) score += 0.2;

      // Same-minute batch penalty: two transactions for the same
      // merchant + amount that landed within ±1 minute and have NO
      // refId to disambiguate are almost always a split-payment or
      // batch-charge — not a re-share. Penalize so they don't get
      // flagged as duplicates and trigger a "this looks like a
      // duplicate" prompt the user has to dismiss every time.
      final bothNoRefId = (a.refId == null || a.refId!.isEmpty) &&
          (b.refId == null || b.refId!.isEmpty);
      if (diff <= 1 && bothNoRefId) {
        score -= 0.2;
      }
    }

    // Last4 — when both present and equal
    if (a.last4 != null &&
        a.last4!.isNotEmpty &&
        a.last4 == b.last4) {
      score += 0.1;
    }

    // RefId boost — if both have a reference and they match, this is
    // about as close to "definitely same transaction" as a heuristic gets.
    if (a.refId != null &&
        a.refId!.isNotEmpty &&
        a.refId == b.refId) {
      score += 0.2;
    }

    if (score > 1) score = 1;
    if (score < 0) score = 0;
    return score;
  }

  /// True when [a] and [b] are functionally the same amount,
  /// accommodating both OCR rounding (paise drift, ₹999↔₹1000 slips)
  /// and currency truncation. Either an absolute gap of ≤₹1 OR a
  /// relative gap of <1% qualifies — whichever is more forgiving for
  /// the ticket size in question.
  static bool _isAmountNear(double a, double b) {
    final diff = (a - b).abs();
    if (diff <= 1.0) return true;
    final base = a.abs() > b.abs() ? a.abs() : b.abs();
    if (base == 0) return false;
    return diff / base < 0.01;
  }

  /// Cheap fuzzy text equality — exact match, prefix containment, or
  /// shared significant token. Avoids Levenshtein because the latency
  /// budget is small and we have plenty of corroborating signals.
  static bool _similarText(String a, String b) {
    final aN = a.toLowerCase().trim();
    final bN = b.toLowerCase().trim();
    if (aN.isEmpty || bN.isEmpty) return false;
    if (aN == bN) return true;
    // Substring containment (one merchant name is a prefix/expansion of
    // the other, e.g. "Zomato" vs "Zomato Limited").
    if (aN.length >= 4 && bN.length >= 4) {
      if (aN.contains(bN) || bN.contains(aN)) return true;
    }
    // Token overlap on tokens of length ≥ 4 — rejects "Red Bus"/"Red Tape"
    // false positives (the only shared token is "red", length 3).
    final aTokens = aN.split(RegExp(r'\s+')).where((t) => t.length >= 4).toSet();
    if (aTokens.isEmpty) return false;
    final bTokens = bN.split(RegExp(r'\s+')).where((t) => t.length >= 4).toSet();
    return aTokens.intersection(bTokens).isNotEmpty;
  }
}

/// Window entry: pairs a fingerprint with when we recorded it. Used
/// internally so [DuplicateDetector] can apply [_stage1Ttl] without
/// mutating [TransactionFingerprint] (which the caller constructs).
class _WindowEntry {
  final TransactionFingerprint fp;
  final DateTime addedAt;
  const _WindowEntry({required this.fp, required this.addedAt});
}
