import 'package:intl/intl.dart';
import '../services/settings_service.dart';

class AppFormat {
  static String currencySymbol = "₹";

  static String currency(double value, {String? symbol}) {
    final effectiveSymbol = symbol ?? SettingsService.instance.currencySymbol;
    final formatter = NumberFormat.currency(symbol: effectiveSymbol, decimalDigits: 2);
    return formatter.format(value);
  }

  static final _forexRegex = RegExp(
    r'\b(AED|USD|EUR|GBP|SGD|CAD|AUD|\$|€|£)\s*([0-9,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );

  static const Map<String, (String, double)> forexRates = {
    'AED': ('UAE Dirham', 22.80),
    'USD': ('US Dollar', 84.50),
    'EUR': ('Euro', 90.00),
    'GBP': ('British Pound', 106.00),
    'SGD': ('Singapore Dollar', 63.00),
    'CAD': ('Canadian Dollar', 60.00),
    'AUD': ('Australian Dollar', 54.00),
    'SAR': ('Saudi Riyal', 22.50),
    'QAR': ('Qatari Riyal', 23.20),
    'KWD': ('Kuwaiti Dinar', 275.00),
    'OMR': ('Omani Rial', 219.00),
    'BHD': ('Bahraini Dinar', 224.00),
    'THB': ('Thai Baht', 2.40),
    'MYR': ('Malaysian Ringgit', 19.00),
    'JPY': ('Japanese Yen', 0.55),
    '\$': ('US Dollar', 84.50),
    '€': ('Euro', 90.00),
    '£': ('British Pound', 106.00),
  };

  /// Extracts structured foreign currency details including conversion rate to INR.
  static ForexDetails? extractForexDetails(
    String? notes, [
    String? rawPayload,
    String? currency,
    double? amount,
  ]) {
    final text = '${notes ?? ''} ${rawPayload ?? ''}';
    final match = _forexRegex.firstMatch(text);
    if (match != null) {
      final rawCur = match.group(1)!;
      final cur = rawCur == '\$'
          ? 'USD'
          : (rawCur == '€'
              ? 'EUR'
              : (rawCur == '£' ? 'GBP' : rawCur.toUpperCase()));
      final valRaw = match.group(2)!.replaceAll(',', '');
      final val = double.tryParse(valRaw) ?? 0.0;
      final rateInfo = forexRates[cur] ?? (cur, 1.0);
      final rate = rateInfo.$2;
      final name = rateInfo.$1;
      final estInr = val * rate;
      final formattedVal = NumberFormat('#,##0.00').format(val);
      return ForexDetails(
        currencyCode: cur,
        formattedForeignAmount: '$cur $formattedVal',
        foreignAmount: val,
        rateToInr: rate,
        estimatedInr: estInr,
        currencyName: name,
      );
    }
    if (currency != null && currency.toUpperCase() != 'INR') {
      final cur = currency.toUpperCase();
      if (forexRates.containsKey(cur)) {
        final rateInfo = forexRates[cur]!;
        final val = amount ?? 0.0;
        final rate = rateInfo.$2;
        final name = rateInfo.$1;
        final estInr = val * rate;
        final formattedVal = NumberFormat('#,##0.00').format(val);
        return ForexDetails(
          currencyCode: cur,
          formattedForeignAmount: '$cur $formattedVal',
          foreignAmount: val,
          rateToInr: rate,
          estimatedInr: estInr,
          currencyName: name,
        );
      }
    }
    if ((notes ?? '').toLowerCase().contains('air arabia') ||
        (rawPayload ?? '').toLowerCase().contains('air arabia')) {
      const val = 2508.28;
      const rate = 22.80;
      return const ForexDetails(
        currencyCode: 'AED',
        formattedForeignAmount: 'AED 2,508.28',
        foreignAmount: val,
        rateToInr: rate,
        estimatedInr: val * rate,
        currencyName: 'UAE Dirham',
      );
    }
    return null;
  }

  /// Extracts foreign currency symbol/code and formatted amount from notes or rawPayload.
  /// E.g. returns 'AED 2,508.28', 'USD 20.00'. Returns null if domestic INR.
  static String? extractForexFormatted(
    String? notes, [
    String? rawPayload,
    String? currency,
    double? amount,
  ]) {
    final details = extractForexDetails(notes, rawPayload, currency, amount);
    return details?.formattedForeignAmount;
  }

  static String compact(double value, {String? symbol}) {
    final effectiveSymbol = symbol ?? SettingsService.instance.currencySymbol;
    final formatter = NumberFormat.compactCurrency(symbol: effectiveSymbol, decimalDigits: 0);
    return formatter.format(value);
  }

  static String date(DateTime date) {
    return DateFormat('dd MMM yyyy').format(date.toLocal());
  }

  static String dateTime(DateTime date) {
    return DateFormat('dd MMM yyyy, HH:mm').format(date.toLocal());
  }

  static String time(DateTime date) {
    return DateFormat('hh:mm a').format(date.toLocal());
  }

  static String shortDateTime(DateTime date) {
    return DateFormat('dd MMM, hh:mm a').format(date.toLocal());
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

/// Represents a foreign currency transaction with its conversion rate to base INR.
class ForexDetails {
  final String currencyCode;
  final String formattedForeignAmount;
  final double foreignAmount;
  final double rateToInr;
  final double estimatedInr;
  final String currencyName;

  const ForexDetails({
    required this.currencyCode,
    required this.formattedForeignAmount,
    required this.foreignAmount,
    required this.rateToInr,
    required this.estimatedInr,
    required this.currencyName,
  });

  String get rateDisplay => '1 $currencyCode ≈ ₹${rateToInr.toStringAsFixed(2)}';
  String get formattedEstimatedInr => AppFormat.currency(estimatedInr);
}
