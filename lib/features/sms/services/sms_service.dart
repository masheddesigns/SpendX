import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/parsed_sms.dart';
import 'sms_parser.dart';

List<ParsedSms> parseSmsMessages(List<dynamic> rawMessages) {
  final parsed = <ParsedSms>[];
  for (final item in rawMessages) {
    if (item is! Map) continue;
    final sender = (item['sender'] as String?) ?? '';
    final body = (item['body'] as String?) ?? '';
    final date = (item['date'] as int?) ?? 0;

    final sms = SmsParser.parse(
      sender: sender,
      body: body,
      timestampMillis: date,
    );

    if (sms != null) {
      parsed.add(sms);
    }
  }
  return parsed;
}

class SmsService {
  static const MethodChannel _channel = MethodChannel('spend_x/sms');

  Future<List<ParsedSms>> fetchRecent({
    int limit = 4000,
    Duration lookback = const Duration(days: 180),
  }) async {
    final sinceMillis = DateTime.now()
        .subtract(lookback)
        .millisecondsSinceEpoch;
    final result = await _channel.invokeListMethod<dynamic>('fetchRecent', {
      'limit': limit,
      'sinceMillis': sinceMillis,
    });

    if (result == null || result.isEmpty) {
      return const [];
    }

    final rawCount = result.length;
    
    // Parse in isolate
    final parsed = await compute(parseSmsMessages, result);

    // Helpful stabilization log to confirm the parser isn't dropping everything.
    // We intentionally keep this debug-only style signal concise.
    // ignore: avoid_print
    print('📨 SMS fetched raw: $rawCount, parsed: ${parsed.length}');

    return parsed;
  }
}
