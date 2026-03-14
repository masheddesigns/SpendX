import 'package:intl/intl.dart';

class AppFormat {
  static String currency(double value) {
    final formatter = NumberFormat.currency(symbol: '₹');
    return formatter.format(value);
  }

  static String get currencySymbol => '₹';
}
