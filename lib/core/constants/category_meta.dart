import 'package:flutter/material.dart';

class CategoryMeta {
  final IconData icon;
  final Color color;

  const CategoryMeta(this.icon, this.color);
}

class CategoryMetaMap {
  static const Map<String, CategoryMeta> expense = {
    'Food': CategoryMeta(Icons.lunch_dining_rounded, Color(0xFFE53935)),
    'Transport': CategoryMeta(
      Icons.directions_car_filled_rounded,
      Color(0xFF1E88E5),
    ),
    'Groceries': CategoryMeta(
      Icons.local_grocery_store_rounded,
      Color(0xFF43A047),
    ),
    'Bills': CategoryMeta(Icons.receipt_long_rounded, Color(0xFFF4511E)),
    'Rent': CategoryMeta(Icons.apartment_rounded, Color(0xFF6D4C41)),
    'Shopping': CategoryMeta(Icons.shopping_bag_rounded, Color(0xFF8E24AA)),
    'Health': CategoryMeta(Icons.health_and_safety_rounded, Color(0xFFD81B60)),
    'Entertainment': CategoryMeta(Icons.theaters_rounded, Color(0xFF3949AB)),
    'Education': CategoryMeta(Icons.school_rounded, Color(0xFF00897B)),
    'Travel': CategoryMeta(Icons.flight_takeoff_rounded, Color(0xFF00ACC1)),
    'Subscriptions': CategoryMeta(
      Icons.subscriptions_rounded,
      Color(0xFF7CB342),
    ),
    'Others': CategoryMeta(Icons.category_rounded, Color(0xFF757575)),
  };

  static const Map<String, CategoryMeta> income = {
    'Salary': CategoryMeta(
      Icons.account_balance_wallet_rounded,
      Color(0xFF2E7D32),
    ),
    'Freelance': CategoryMeta(Icons.work_rounded, Color(0xFF00897B)),
    'Business': CategoryMeta(Icons.business_center_rounded, Color(0xFF6A1B9A)),
    'Investment': CategoryMeta(Icons.trending_up_rounded, Color(0xFF1565C0)),
    'Gift': CategoryMeta(Icons.card_giftcard_rounded, Color(0xFFC2185B)),
    'Refund': CategoryMeta(Icons.replay_rounded, Color(0xFFEF6C00)),
    'Other Income': CategoryMeta(Icons.payments_rounded, Color(0xFF2E7D32)),
  };

  static CategoryMeta resolve(String name, String type) {
    final map = type == 'income' ? income : expense;
    return map[name] ?? defaultForType(type);
  }

  static CategoryMeta defaultForType(String type) {
    if (type == 'income') {
      return const CategoryMeta(Icons.payments_rounded, Color(0xFF2E7D32));
    }
    return const CategoryMeta(Icons.category_rounded, Color(0xFF757575));
  }

  static String iconKey(String name, String type) {
    final meta = resolve(name, type);
    if (meta.icon == Icons.lunch_dining_rounded) return 'restaurant';
    if (meta.icon == Icons.directions_car_filled_rounded) {
      return 'directions_car';
    }
    if (meta.icon == Icons.local_grocery_store_rounded ||
        meta.icon == Icons.shopping_bag_rounded) {
      return 'shopping_bag';
    }
    if (meta.icon == Icons.receipt_long_rounded) return 'bolt';
    if (meta.icon == Icons.apartment_rounded) return 'home';
    if (meta.icon == Icons.health_and_safety_rounded) {
      return 'health_and_safety';
    }
    if (meta.icon == Icons.theaters_rounded) return 'movie';
    if (meta.icon == Icons.account_balance_wallet_rounded ||
        meta.icon == Icons.work_rounded ||
        meta.icon == Icons.business_center_rounded ||
        meta.icon == Icons.trending_up_rounded ||
        meta.icon == Icons.card_giftcard_rounded ||
        meta.icon == Icons.replay_rounded ||
        meta.icon == Icons.payments_rounded ||
        meta.icon == Icons.school_rounded ||
        meta.icon == Icons.flight_takeoff_rounded ||
        meta.icon == Icons.subscriptions_rounded) {
      return 'payments';
    }
    return 'category';
  }

  static String colorHex(String name, String type) {
    final value = resolve(
      name,
      type,
    ).color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();
    return '#$value';
  }
}
