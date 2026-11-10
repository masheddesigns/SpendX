import 'package:sqflite/sqflite.dart';

import '../../models/credit_card.dart';
import '../../models/reminder_model.dart';
import '../core/app_database.dart';
import '../core/database_access_gate.dart';
import '../core/tables.dart';
import 'credit_repo.dart';

class ReminderRepo {
  final DatabaseExecutor? database;

  ReminderRepo({this.database});

  Future<DatabaseExecutor> get _db async =>
      database != null
          ? DatabaseAccessGate.instance.wrapExecutor(database!)
          : await AppDatabase.instance.database;

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

  /// Manually marks a reminder/bill as completed and settled.
  Future<void> markReminderPaid(String id) async {
    final executor = await _db;
    final r = await getById(id);
    if (r == null) return;

    if (r.recurrencePeriod != ReminderRecurrence.none && r.dueDate != null) {
      final nextDue = _rollForward(r.dueDate!, r.recurrencePeriod);
      await executor.update(
        Tables.reminders,
        {
          'date': nextDue.toIso8601String(),
          'is_completed': 0,
          'record_status': ReminderRecordStatus.pending.name,
          'last_triggered_at': DateTime.now().toIso8601String(),
          'snoozed_until': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } else {
      await executor.update(
        Tables.reminders,
        {
          'is_completed': 1,
          'record_status': ReminderRecordStatus.done.name,
          'last_triggered_at': DateTime.now().toIso8601String(),
          'is_active': 0,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
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
    bool isIncome = false,
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
        if (!isIncome) continue;
      } else {
        if (isIncome) continue;
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

  /// Automatically reconciles pending reminders against existing transactions in SQLite.
  /// If an expense, credit payment, or transfer matching a reminder is already recorded
  /// within +/- 25 days of the reminder's due date, marks the reminder as completed/done.
  Future<int> reconcileWithExistingTransactions({DatabaseExecutor? executor}) async {
    final db = executor ?? await _db;
    final allReminders = await getAll();
    final pendingReminders = allReminders.where(
      (r) =>
          r.isActive &&
          r.recordStatus != ReminderRecordStatus.done &&
          r.type != ReminderType.salary,
    ).toList();

    if (pendingReminders.isEmpty) return 0;

    int reconciledCount = 0;
    List<CreditCard> cards = [];
    try {
      cards = await CreditRepo(executor: db).getAll();
    } catch (_) {}

    for (final reminder in pendingReminders) {
      final rAmt = reminder.amount;
      if (rAmt == null || rAmt <= 0) continue;
      final rDate = reminder.dueDate ?? reminder.createdAt;
      final now = DateTime.now();
      final isPastDue = rDate.isBefore(now);
      final minDate = rDate.subtract(const Duration(days: 25)).toIso8601String();
      final maxDate = rDate.add(const Duration(days: 25)).toIso8601String();

      final isCc = reminder.type == ReminderType.credit ||
          reminder.title.toLowerCase().contains('credit card') ||
          (reminder.linkedEntityId != null && reminder.linkedEntityId!.isNotEmpty);

      bool matched = false;

      // 1. Credit card derived balance / statement reconciliation
      if (isCc && cards.isNotEmpty) {
        CreditCard? matchedCard;
        if (reminder.linkedEntityId != null && reminder.linkedEntityId!.isNotEmpty) {
          matchedCard = cards.where((c) => c.id == reminder.linkedEntityId).firstOrNull;
        }
        if (matchedCard == null) {
          final tLower = reminder.title.toLowerCase();
          matchedCard = cards.where((c) {
            final bLower = c.bank.toLowerCase();
            final nLower = c.name.toLowerCase();
            return (bLower.isNotEmpty && tLower.contains(bLower)) ||
                (nLower.isNotEmpty && tLower.contains(nLower));
          }).firstOrNull;
        }

        if (matchedCard != null) {
          if (matchedCard.lastStatementBalance <= 0.01 ||
              matchedCard.outstanding <= 0.01 ||
              (isPastDue && matchedCard.outstanding < rAmt)) {
            matched = true;
          }
        }
      }

      // 2. Query canonical V24 postings & economic events
      if (!matched) {
        try {
          final minPaise = ((rAmt - 1.0) * 100).round();
          final maxPaise = ((rAmt + 1.0) * 100).round();
          final v24Rows = await db.rawQuery('''
            SELECT e.id, e.description, e.timestamp, e.event_type, e.notes,
                   (p.amount_minor_units / 100.0) AS amount, p.account_id
            FROM ${TablesV24.postings} p
            JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
            WHERE e.lifecycle_status = 'posted'
              AND p.amount_minor_units BETWEEN ? AND ?
              AND e.timestamp BETWEEN ? AND ?;
          ''', [minPaise, maxPaise, minDate, maxDate]);

          for (final row in v24Rows) {
            final desc = ((row['description'] as String?) ?? '').toLowerCase();
            final notes = ((row['notes'] as String?) ?? '').toLowerCase();
            final fullText = '$desc $notes';
            final evType = row['event_type'] as String? ?? '';

            if (isCc) {
              final isCcEvent = evType == 'liability_settlement' ||
                  fullText.contains('credit') ||
                  fullText.contains('card') ||
                  fullText.contains('bill') ||
                  fullText.contains('hdfc') ||
                  fullText.contains('sbi') ||
                  fullText.contains('icici') ||
                  fullText.contains('axis') ||
                  fullText.contains('onecard');
              if (isCcEvent) {
                matched = true;
                break;
              }
            } else {
              final rTitle = reminder.title.toLowerCase();
              final cleanTokens = rTitle
                  .replaceAll(
                    RegExp(
                      r'\b(subscription|bill|due|premium|autopay|mandate|stocks|health|renewal)\b',
                    ),
                    '',
                  )
                  .split(RegExp(r'[^a-z0-9]+'))
                  .where((t) => t.length >= 3)
                  .toSet();
              final hasToken = cleanTokens.any((t) => fullText.contains(t));
              if (hasToken) {
                matched = true;
                break;
              }
            }
          }
        } catch (_) {}
      }

      // 3. Fallback: Query legacy transactions table
      if (!matched) {
        try {
          final rows = await db.rawQuery('''
            SELECT id, amount, type, source, notes, related_entity_id, external_ref, date
            FROM ${Tables.transactions}
            WHERE is_deleted = 0
              AND amount BETWEEN ? AND ?
              AND date BETWEEN ? AND ?;
          ''', [rAmt - 1.0, rAmt + 1.0, minDate, maxDate]);

          for (final tx in rows) {
            final txType = tx['type'] as String? ?? '';
            final txSource = tx['source'] as String? ?? '';
            final notes = (tx['notes'] as String? ?? '').toLowerCase();
            final relatedId = tx['related_entity_id'] as String?;

            if (isCc) {
              final isPaymentType =
                  txType == 'credit_payment' || txSource == 'credit_card_payment';
              final matchesEntity = reminder.linkedEntityId != null &&
                  reminder.linkedEntityId!.isNotEmpty &&
                  (relatedId == reminder.linkedEntityId ||
                      notes.contains(reminder.linkedEntityId!));
              final rTitle = reminder.title.toLowerCase();
              final matchesTitle = notes.contains('credit') ||
                  notes.contains('card') ||
                  notes.contains('pay') ||
                  notes.contains('bill') ||
                  (rTitle.contains('hdfc') && notes.contains('hdfc')) ||
                  (rTitle.contains('sbi') && notes.contains('sbi')) ||
                  (rTitle.contains('icici') && notes.contains('icici')) ||
                  (rTitle.contains('axis') && notes.contains('axis')) ||
                  (rTitle.contains('onecard') && notes.contains('onecard'));

              if (isPaymentType ||
                  matchesEntity ||
                  (matchesTitle && (txType == 'expense' || txType == 'transfer'))) {
                matched = true;
                break;
              }
            } else {
              final rTitle = reminder.title.toLowerCase();
              final cleanTokens = rTitle
                  .replaceAll(
                    RegExp(
                      r'\b(subscription|bill|due|premium|autopay|mandate|stocks|health|renewal)\b',
                    ),
                    '',
                  )
                  .split(RegExp(r'[^a-z0-9]+'))
                  .where((t) => t.length >= 3)
                  .toSet();
              final hasToken = cleanTokens.any((t) => notes.contains(t));
              if (hasToken && (txType == 'expense' || txType == 'transfer')) {
                matched = true;
                break;
              }
            }
          }
        } catch (_) {}
      }

      // 4. Overdue grace expiration: If past due date is older than 14 days (half-month),
      // it either cleared in a prior billing cycle or expired. Unpaid bills within 14 days
      // remain active & overdue so user can resolve or mark as paid.
      final isOverdueExpired = !matched &&
          isPastDue &&
          rDate.isBefore(now.subtract(const Duration(days: 14)));

      if (matched || isOverdueExpired) {
        reconciledCount++;
        if (reminder.recurrencePeriod == ReminderRecurrence.monthly) {
          final currentDue = reminder.dueDate ?? reminder.createdAt;
          final nextDue = DateTime(
            currentDue.year,
            currentDue.month + 1,
            currentDue.day,
            currentDue.hour,
            currentDue.minute,
          );
          await db.rawUpdate('''
            UPDATE ${Tables.reminders}
            SET date = ?, is_completed = 0, record_status = ?, last_triggered_at = ?
            WHERE id = ?;
          ''', [
            nextDue.toIso8601String(),
            ReminderRecordStatus.pending.name,
            DateTime.now().toIso8601String(),
            reminder.id,
          ]);
        } else {
          await db.rawUpdate('''
            UPDATE ${Tables.reminders}
            SET is_completed = 1, record_status = ?, last_triggered_at = ?
            WHERE id = ?;
          ''', [
            ReminderRecordStatus.done.name,
            DateTime.now().toIso8601String(),
            reminder.id,
          ]);
        }
      }
    }

    return reconciledCount;
  }
}
