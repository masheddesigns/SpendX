import 'package:flutter/material.dart';

class CategoryIconPicker extends StatelessWidget {
  final String selectedIcon;
  final Function(String) onIconSelected;

  const CategoryIconPicker({
    super.key,
    required this.selectedIcon,
    required this.onIconSelected,
  });

  static const List<String> defaultIcons = [
    'lunch_dining',
    'directions_car',
    'local_grocery_store',
    'receipt_long',
    'apartment',
    'shopping_bag',
    'health_and_safety',
    'theaters',
    'school',
    'flight_takeoff',
    'subscriptions',
    'payments',
    'account_balance_wallet',
    'work',
    'business_center',
    'trending_up',
    'card_giftcard',
    'replay',
    'savings',
    'account_balance',
    'local_cafe',
    'medical_services',
    'sports_esports',
    'phone_iphone',
    'wifi',
    'home_repair_service',
    'pets',
    'celebration',
    'shopping_cart',
    'category',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Pick an Icon',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.grey,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 200,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: 0.3),
            ),
          ),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: defaultIcons.length,
            itemBuilder: (context, index) {
              final icon = defaultIcons[index];
              final isSelected = selectedIcon == icon;
              return GestureDetector(
                onTap: () => onIconSelected(icon),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    _iconForKey(icon),
                    size: 22,
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  IconData _iconForKey(String key) {
    switch (key) {
      case 'lunch_dining':
        return Icons.lunch_dining_rounded;
      case 'directions_car':
        return Icons.directions_car_filled_rounded;
      case 'local_grocery_store':
        return Icons.local_grocery_store_rounded;
      case 'receipt_long':
        return Icons.receipt_long_rounded;
      case 'apartment':
        return Icons.apartment_rounded;
      case 'shopping_bag':
        return Icons.shopping_bag_rounded;
      case 'health_and_safety':
        return Icons.health_and_safety_rounded;
      case 'theaters':
        return Icons.theaters_rounded;
      case 'school':
        return Icons.school_rounded;
      case 'flight_takeoff':
        return Icons.flight_takeoff_rounded;
      case 'subscriptions':
        return Icons.subscriptions_rounded;
      case 'payments':
        return Icons.payments_rounded;
      case 'account_balance_wallet':
        return Icons.account_balance_wallet_rounded;
      case 'work':
        return Icons.work_rounded;
      case 'business_center':
        return Icons.business_center_rounded;
      case 'trending_up':
        return Icons.trending_up_rounded;
      case 'card_giftcard':
        return Icons.card_giftcard_rounded;
      case 'replay':
        return Icons.replay_rounded;
      case 'savings':
        return Icons.savings_rounded;
      case 'account_balance':
        return Icons.account_balance_rounded;
      case 'local_cafe':
        return Icons.local_cafe_rounded;
      case 'medical_services':
        return Icons.medical_services_rounded;
      case 'sports_esports':
        return Icons.sports_esports_rounded;
      case 'phone_iphone':
        return Icons.phone_iphone_rounded;
      case 'wifi':
        return Icons.wifi_rounded;
      case 'home_repair_service':
        return Icons.home_repair_service_rounded;
      case 'pets':
        return Icons.pets_rounded;
      case 'celebration':
        return Icons.celebration_rounded;
      case 'shopping_cart':
        return Icons.shopping_cart_rounded;
      default:
        return Icons.category_rounded;
    }
  }
}
