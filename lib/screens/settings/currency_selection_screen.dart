import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/settings_service.dart';

class CurrencySelectionScreen extends StatelessWidget {
  const CurrencySelectionScreen({super.key});

  static const List<Map<String, String>> _currencies = [
    {'code': 'USD', 'symbol': '\$', 'name': 'US Dollar'},
    {'code': 'INR', 'symbol': '₹', 'name': 'Indian Rupee'},
    {'code': 'EUR', 'symbol': '€', 'name': 'Euro'},
    {'code': 'GBP', 'symbol': '£', 'name': 'British Pound'},
    {'code': 'JPY', 'symbol': '¥', 'name': 'Japanese Yen'},
    {'code': 'AUD', 'symbol': 'A\$', 'name': 'Australian Dollar'},
    {'code': 'CAD', 'symbol': 'C\$', 'name': 'Canadian Dollar'},
    {'code': 'CHF', 'symbol': 'CHF', 'name': 'Swiss Franc'},
    {'code': 'CNY', 'symbol': '¥', 'name': 'Chinese Yuan'},
    // GCC
    {'code': 'SAR', 'symbol': 'SR', 'name': 'Saudi Riyal'},
    {'code': 'AED', 'symbol': 'د.إ', 'name': 'UAE Dirham'},
    {'code': 'QAR', 'symbol': 'QR', 'name': 'Qatari Riyal'},
    {'code': 'KWD', 'symbol': 'KD', 'name': 'Kuwaiti Dinar'},
    {'code': 'OMR', 'symbol': 'RO', 'name': 'Omani Rial'},
    {'code': 'BHD', 'symbol': 'BD', 'name': 'Bahraini Dinar'},
    // Asia
    {'code': 'SGD', 'symbol': 'S\$', 'name': 'Singapore Dollar'},
    {'code': 'MYR', 'symbol': 'RM', 'name': 'Malaysian Ringgit'},
    {'code': 'THB', 'symbol': '฿', 'name': 'Thai Baht'},
    {'code': 'IDR', 'symbol': 'Rp', 'name': 'Indonesian Rupiah'},
    {'code': 'PHP', 'symbol': '₱', 'name': 'Philippine Peso'},
    {'code': 'KRW', 'symbol': '₩', 'name': 'South Korean Won'},
    {'code': 'PKR', 'symbol': '₨', 'name': 'Pakistani Rupee'},
    {'code': 'BDT', 'symbol': '৳', 'name': 'Bangladeshi Taka'},
    // Europe
    {'code': 'RUB', 'symbol': '₽', 'name': 'Russian Ruble'},
    {'code': 'TRY', 'symbol': '₺', 'name': 'Turkish Lira'},
    {'code': 'SEK', 'symbol': 'kr', 'name': 'Swedish Krona'},
    {'code': 'NOK', 'symbol': 'kr', 'name': 'Norwegian Krone'},
    {'code': 'DKK', 'symbol': 'kr', 'name': 'Danish Krone'},
    // Americas
    {'code': 'BRL', 'symbol': 'R\$', 'name': 'Brazilian Real'},
    {'code': 'MXN', 'symbol': '\$', 'name': 'Mexican Peso'},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Display Currency'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Consumer<SettingsService>(
          builder: (context, settings, _) {
            final currentCurrency = settings.primaryCurrency;
            
            return ListView.builder(
              itemCount: _currencies.length,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (context, index) {
                final currency = _currencies[index];
                final isSelected = currentCurrency == currency['symbol'] || currentCurrency == currency['code'];
                
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                        : Theme.of(context).colorScheme.surfaceContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                      width: isSelected ? 2.0 : 1.0,
                    ),
                    boxShadow: [
                      if (isSelected) 
                        BoxShadow(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                    ],
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(
                        currency['symbol']!,
                        style: TextStyle(
                          color: isSelected ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          fontSize: isSelected ? 15 : 14,
                        ),
                      ),
                    ),
                    title: Text(
                      currency['name']!,
                      style: TextStyle(
                        color: isSelected ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      currency['code']!,
                      style: TextStyle(
                        color: isSelected
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 24)
                        : Icon(Icons.radio_button_unchecked, color: Theme.of(context).colorScheme.outlineVariant, size: 22),
                    onTap: () {
                      settings.setPrimaryCurrency(currency['code']!);
                      Navigator.pop(context);
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
