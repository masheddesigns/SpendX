import 'package:intl/intl.dart';
import '../services/settings_service.dart';

class AppFormat {
  static String currencySymbol = "₹";

  static String currency(double value, {String? symbol}) {
    final effectiveSymbol = symbol ?? SettingsService.instance.currencySymbol;
    final formatter = NumberFormat.currency(symbol: effectiveSymbol, decimalDigits: 2);
    return formatter.format(value);
  }

  static String date(DateTime date) {
    return DateFormat('dd MMM yyyy').format(date);
  }

  static String dateTime(DateTime date) {
    return DateFormat('dd MMM yyyy, HH:mm').format(date);
  }

  static String ledgerTypeLabel(String type) {
    switch (type) {
      case 'expense': return 'Expense';
      case 'income': return 'Income';
      case 'credit_purchase': return 'Credit Purchase';
      case 'credit_payment': return 'Credit Payment';
      case 'emi_installment': return 'EMI Installment';
      case 'loan_disbursement': return 'Loan Disbursement';
      case 'loan_payment': return 'Loan Payment';
      case 'lending_given': return 'Lending Given';
      case 'lending_received': return 'Lending Received';
      case 'fuel_expense': return 'Fuel Expense';
      case 'processing_fee': return 'Processing Fee';
      case 'interest_charge': return 'Interest Charge';
      case 'refund': return 'Refund';
      default: return type[0].toUpperCase() + type.substring(1).replaceAll('_', ' ');
    }
  }

  static String mapError(Object error) {
    if (error.toString().contains("DatabaseException")) {
      return "Unable to save data. Please try again.";
    }
    return "Something went wrong. Please try again.";
  }
}
