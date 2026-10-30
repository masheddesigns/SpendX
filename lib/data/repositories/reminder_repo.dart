import 'package:sqflite/sqflite.dart';

import '../../models/reminder_model.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class ReminderRepo {
  final DatabaseExecutor? database;

  ReminderRepo({this.database});

  Future<DatabaseExecutor> get _db async =>
      database ?? await AppDatabase.instance.database;

  Future<List<Reminder>> getAll() async {
    final executor = await _db;
    final results = await executor.query(
      Tables.reminders,
      orderBy: 'created_at DESC',
    );
    return results.map(Reminder.fromMap).toList();
  }

  Future<Reminder?> getById(String id) async {
    final executor = await _db;
    final results = await executor.query(
      Tables.reminders,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) {
      return null;
    }
    return Reminder.fromMap(results.first);
  }

  Future<void> insertGlobalReminder(Map<String, dynamic> reminder) async {
    final executor = await _db;
    await executor.insert(
      Tables.reminders,
      reminder,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsert(Reminder reminder) async {
    await insertGlobalReminder(reminder.toMap());
  }

  Future<int> update(Reminder reminder) async {
    final executor = await _db;
    return executor.update(
      Tables.reminders,
      reminder.toMap(),
      where: 'id = ?',
      whereArgs: [reminder.id],
    );
  }

  Future<void> deleteGlobalReminder(String id) async {
    final executor = await _db;
    await executor.delete(Tables.reminders, where: 'id = ?', whereArgs: [id]);
  }

  DateTime _rollForward(DateTime date, ReminderRecurrence recurrence) {
    switch (recurrence) {
      case ReminderRecurrence.weekly:
        return date.add(const Duration(days: 7));
      case ReminderRecurrence.monthly:
        final nextMonth = date.month == 12 ? 1 : date.month + 1;
        final nextYear = date.month == 12 ? date.year + 1 : date.year;
        final daysInNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
        final day = date.day.clamp(1, daysInNextMonth);
        return DateTime(nextYear, nextMonth, day, date.hour, date.minute);
      case ReminderRecurrence.yearly:
        final nextYear = date.year + 1;
        final daysInMonth = DateTime(nextYear, date.month + 1, 0).day;
        final day = date.day.clamp(1, daysInMonth);
        return DateTime(nextYear, date.month, day, date.hour, date.minute);
      case ReminderRecurrence.none:
        return date;
    }
  }

  /// Automatically marks as done or rolls forward reminders matching a financial expense,
  /// bill payment, or credit card repayment. Prevents double-counting in 14-day commitments.
  Future<int> settleMatching({
    required double amount,
    required DateTime date,
    String? title,
    String? merchant,
    String? notes,
    String? linkedEntityId,
    bool isCreditCardPayment = false,
  }) async {
    final all = await getAll();
    int settledCount = 0;

    final searchTexts = [
      if (title != null && title.isNotEmpty) title.toLowerCase(),
      if (merchant != null && merchant.isNotEmpty) merchant.toLowerCase(),
      if (notes != null && notes.isNotEmpty) notes.toLowerCase(),
    ];

    const stopWords = {
      'the', 'and', 'for', 'with', 'via', 'paid', 'from', 'bill',
      'due', 'autopay', 'mandate', 'upi', 'payment', 'towards',
      'card', 'account', 'bank', 'spent', 'debited', 'credited',
    };

    final searchTokens = searchTexts
        .expand((s) => s.split(RegExp(r'[^a-z0-9]+')))
        .where((t) => t.length >= 3 && !stopWords.contains(t))
        .toSet();

    for (final reminder in all) {
      if (!reminder.isActive || reminder.recordStatus == ReminderRecordStatus.done) {
        continue;
      }
      if (reminder.type == ReminderType.salary) {
        continue;
      }

      bool matches = false;

      // 1. Credit card bill payment matching
      if (isCreditCardPayment && linkedEntityId != null && linkedEntityId.isNotEmpty) {
        if (reminder.linkedEntityId == linkedEntityId ||
            reminder.id == 'credit_due_$linkedEntityId' ||
            reminder.sourceId == linkedEntityId) {
          matches = true;
        }
      }

      // 2. Exact or close amount check (within ₹1.0 for decimal rounding)
      final reminderAmt = reminder.amount;
      final amountMatches = reminderAmt == null || (reminderAmt - amount).abs() <= 1.0;

      // 3. Date window check (+/- 20 days around transaction date)
      final rDate = reminder.dueDate ?? reminder.createdAt;
      final dateMatches = rDate.difference(date).inDays.abs() <= 20;

      // 4. Token / merchant / title match
      if (!matches && amountMatches && dateMatches && searchTokens.isNotEmpty) {
        final rTitle = reminder.title.toLowerCase();
        final rNotes = (reminder.notes ?? '').toLowerCase();
        final rTokens = '$rTitle $rNotes'.split(RegExp(r'[^a-z0-9]+')).toSet();

        final hasTokenMatch = searchTokens.any(
          (t) => rTokens.contains(t) || rTitle.contains(t) || rNotes.contains(t),
        );

        if (hasTokenMatch) {
          matches = true;
        }
      }

      if (matches) {
        settledCount++;
        if (isCreditCardPayment && reminderAmt != null && amount < reminderAmt - 1.0) {
          // Partial credit card payment: reduce remaining due
          final updated = reminder.copyWith(
            amount: reminderAmt - amount,
            lastTriggeredAt: date,
          );
          await update(updated);
        } else if (reminder.recurrencePeriod != ReminderRecurrence.none &&
            reminder.dueDate != null) {
          // Recurring subscription / mandate: roll forward to next billing cycle
          final nextDate = _rollForward(reminder.dueDate!, reminder.recurrencePeriod);
          final updated = reminder.copyWith(
            dueDate: nextDate,
            lastTriggeredAt: date,
            snoozedUntil: null,
            recordStatus: ReminderRecordStatus.pending,
            nextTriggerAt: nextDate,
          );
          await update(updated);
        } else {
          // One-off obligation completed
          final updated = reminder.copyWith(
            recordStatus: ReminderRecordStatus.done,
            isActive: false,
            lastTriggeredAt: date,
            snoozedUntil: null,
          );
          await update(updated);
        }
      }
    }

    return settledCount;
  }
}
