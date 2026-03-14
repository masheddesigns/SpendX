import '../models/recurring_template.dart';
import '../models/transaction.dart' as spx;
import 'database_helper.dart';

class RecurringEngine {
  RecurringEngine._();

  static Future<void> checkAndGenerate() async {
    final templates = await DatabaseHelper.instance.getAllRecurringTemplates();
    final now = DateTime.now();

    for (var t in templates) {
      if (!t.isActive) continue;

      DateTime currentCheckDate = t.lastGeneratedDate ?? t.startDate;
      bool updated = false;

      // If it has never been generated, and startDate is in the past/today, generate to catch up.
      // But we must start the loop carefully
      if (t.lastGeneratedDate == null) {
        if (t.startDate.isBefore(now) || t.startDate.isAtSameMomentAs(now)) {
          await _generateTransaction(t, t.startDate);
          currentCheckDate = t.startDate;
          updated = true;
        } else {
          // Starts in the future, ignore for now
          continue;
        }
      }

      // Now loop forward according to frequency until we pass 'now' or 'endDate'
      while (true) {
        final nextDate = _calculateNextDate(currentCheckDate, t.frequency);
        
        // If the next calculated date is strictly after now, we stop generating.
        // We only generate if the due date has arrived (or passed).
        // Since we don't care about time of day for recurring triggers, we can compare days.
        if (nextDate.isAfter(now)) {
          break;
        }

        if (t.endDate != null && nextDate.isAfter(t.endDate!)) {
          // Reached end date, deactivate template
          await DatabaseHelper.instance.updateRecurringTemplate(t.copyWith(isActive: false));
          break;
        }

        // Generate transaction for this date
        await _generateTransaction(t, nextDate);
        currentCheckDate = nextDate;
        updated = true;
      }

      if (updated) {
        // Save the latest generated date
        await DatabaseHelper.instance.updateRecurringTemplate(
          t.copyWith(lastGeneratedDate: currentCheckDate),
        );
      }
    }
  }

  static Future<void> _generateTransaction(RecurringTemplate t, DateTime date) async {
    final txn = spx.Transaction(
      userId: t.userId,
      type: t.type,
      categoryId: t.categoryId,
      amount: t.amount,
      date: date,
      tags: [], // Could add a recurring tag if we wanted
      source: 'recurring',
      notes: 'Auto-generated from recurring template: ${t.name}',
      relatedEntityId: t.id,
    );
    await DatabaseHelper.instance.insertTransaction(txn);
  }

  static DateTime _calculateNextDate(DateTime from, String frequency) {
    switch (frequency) {
      case 'daily':
        return from.add(const Duration(days: 1));
      case 'weekly':
        return from.add(const Duration(days: 7));
      case 'monthly':
        // Safe month addition (handling Jan 31 -> Feb 28 issues roughly)
        final nextMonth = from.month == 12 ? 1 : from.month + 1;
        final nextYear = from.month == 12 ? from.year + 1 : from.year;
        final nextDaysInMonth = _daysInMonth(nextYear, nextMonth);
        final nextDay = from.day > nextDaysInMonth ? nextDaysInMonth : from.day;
        return DateTime(nextYear, nextMonth, nextDay, from.hour, from.minute);
      case 'yearly':
        final isLeapYearObj = _isLeapYear(from.year + 1);
        final nextDay = (from.month == 2 && from.day == 29 && !isLeapYearObj) ? 28 : from.day;
        return DateTime(from.year + 1, from.month, nextDay, from.hour, from.minute);
      default:
        return from.add(const Duration(days: 30));
    }
  }

  static int _daysInMonth(int year, int month) {
    if (month == 2) return _isLeapYear(year) ? 29 : 28;
    const days = [31, -1, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return days[month - 1];
  }

  static bool _isLeapYear(int year) {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
  }
}
