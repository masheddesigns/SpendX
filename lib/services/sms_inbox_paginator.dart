import 'dart:async';

/// One decoded native inbox page.
class SmsInboxPage {
  final List<dynamic> messages;
  final bool hasMore;
  final int? nextDate;
  final int? nextId;

  const SmsInboxPage({
    required this.messages,
    required this.hasMore,
    this.nextDate,
    this.nextId,
  });

  factory SmsInboxPage.fromMap(Map<dynamic, dynamic>? map) {
    final raw = map?['messages'];
    final next = map?['nextCursor'];
    return SmsInboxPage(
      messages: raw is List ? List<dynamic>.from(raw) : const [],
      hasMore: map?['hasMore'] == true,
      nextDate: next is Map ? (next['date'] as num?)?.toInt() : null,
      nextId: next is Map ? (next['id'] as num?)?.toInt() : null,
    );
  }
}

/// Shared cursor-pagination loop for the native SMS inbox.
///
/// The native side sorts by `(date DESC, _id DESC)` and returns the last
/// returned tuple as the next cursor, so identical timestamps cannot be skipped
/// or duplicated. If a page fails (process death, provider timeout), the
/// messages already received are returned and the error is reported; callers
/// can retry safely because ingestion is fingerprint-based.
class SmsInboxPaginator {
  SmsInboxPaginator._();

  static const int defaultPageSize = 300;
  static const int defaultMaxPages = 200;

  static Future<List<dynamic>> fetchAll({
    required Future<Map<dynamic, dynamic>?> Function(
      int? beforeDate,
      int? beforeId,
    ) fetchPage,
    int maxPages = defaultMaxPages,
    void Function(Object error, int pagesFetched)? onPageError,
    bool Function(int fetchedCount)? shouldStop,
  }) async {
    final all = <dynamic>[];
    int? beforeDate;
    int? beforeId;
    var pages = 0;
    var hasMore = true;

    while (hasMore && pages < maxPages) {
      if (shouldStop != null && shouldStop(all.length)) break;

      SmsInboxPage page;
      try {
        final raw = await fetchPage(beforeDate, beforeId)
            .timeout(const Duration(seconds: 15));
        page = SmsInboxPage.fromMap(raw);
      } catch (e) {
        onPageError?.call(e, pages);
        break;
      }

      all.addAll(page.messages);
      hasMore = page.hasMore;
      beforeDate = page.nextDate;
      beforeId = page.nextId;
      pages++;

      if (hasMore && (beforeDate == null || beforeId == null)) {
        onPageError?.call(
          StateError('Native inbox page did not return a next cursor'),
          pages,
        );
        break;
      }
    }
    return all;
  }
}
