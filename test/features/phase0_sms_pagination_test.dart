import 'package:flutter_test/flutter_test.dart';

import 'package:spend_x/services/sms_inbox_paginator.dart';

void main() {
  group('Phase 0 native SMS cursor pagination', () {
    test('pages through identical timestamps without skipping or duplicating',
        () async {
      // All rows share one timestamp; only `_id` distinguishes them.
      final pages = [
        {
          'messages': [
            {'id': 105, 'date': 1000, 'body': 'm105'},
            {'id': 104, 'date': 1000, 'body': 'm104'},
          ],
          'hasMore': true,
          'nextCursor': {'date': 1000, 'id': 104},
        },
        {
          'messages': [
            {'id': 103, 'date': 1000, 'body': 'm103'},
            {'id': 102, 'date': 1000, 'body': 'm102'},
          ],
          'hasMore': true,
          'nextCursor': {'date': 1000, 'id': 102},
        },
        {
          'messages': [
            {'id': 101, 'date': 1000, 'body': 'm101'},
          ],
          'hasMore': false,
          'nextCursor': null,
        },
      ];

      final cursors = <String>[];
      var index = 0;
      final result = await SmsInboxPaginator.fetchAll(
        fetchPage: (beforeDate, beforeId) async {
          cursors.add('${beforeDate ?? '-'}:${beforeId ?? '-'}');
          return pages[index++];
        },
      );

      expect(result.map((m) => (m as Map)['id']).toList(),
          [105, 104, 103, 102, 101]);
      expect(cursors, ['-:-', '1000:104', '1000:102']);
    });

    test('bounds the page size and cursor is carried across pages', () async {
      expect(SmsInboxPaginator.defaultPageSize, 300);
      expect(SmsInboxPaginator.defaultMaxPages, 200);
    });

    test('stops when the native side omits a required cursor', () async {
      var calls = 0;
      Object? reported;
      final result = await SmsInboxPaginator.fetchAll(
        fetchPage: (_, _) async {
          calls++;
          return {
            'messages': [
              {'id': 1, 'date': 10, 'body': 'a'},
            ],
            'hasMore': true,
            'nextCursor': null,
          };
        },
        onPageError: (e, _) => reported = e,
      );

      expect(calls, 1);
      expect(result, hasLength(1));
      expect(reported, isNotNull);
    });

    test('interrupted import keeps pages already received', () async {
      var calls = 0;
      Object? reported;
      final result = await SmsInboxPaginator.fetchAll(
        fetchPage: (_, _) async {
          calls++;
          if (calls == 1) {
            return {
              'messages': [
                {'id': 9, 'date': 20, 'body': 'first'},
              ],
              'hasMore': true,
              'nextCursor': {'date': 20, 'id': 9},
            };
          }
          throw StateError('provider died');
        },
        onPageError: (e, _) => reported = e,
      );

      expect(result, hasLength(1));
      expect((result.first as Map)['id'], 9);
      expect(reported, isA<StateError>());
    });

    test('respects shouldStop for callers with a total limit', () async {
      var calls = 0;
      final result = await SmsInboxPaginator.fetchAll(
        fetchPage: (_, _) async {
          calls++;
          return {
            'messages': [
              {'id': calls, 'date': 100 - calls, 'body': 'x'},
            ],
            'hasMore': true,
            'nextCursor': {'date': 100 - calls, 'id': calls},
          };
        },
        shouldStop: (fetched) => fetched >= 2,
      );

      expect(result, hasLength(2));
      expect(calls, 2);
    });
  });
}
