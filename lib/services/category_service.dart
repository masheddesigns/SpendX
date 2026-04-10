import '../data/repositories/category_repo.dart';
import 'data_change_bus.dart';
import 'package:uuid/uuid.dart';
import '../models/category.dart';

class CategoryService {
  final CategoryRepo categoryRepo;

  CategoryService._({required this.categoryRepo});

  static final instance = CategoryService._(categoryRepo: CategoryRepo());
  factory CategoryService() => instance;

  Future<Category> getOrCreate(String name, {String type = 'expense'}) async {
    final existing = await categoryRepo.getByName(name, type: type);
    if (existing != null) return existing;

    // Create new category if not found
    final newCategory = Category(
      id: const Uuid().v4(),
      userId: 'offline_user',
      name: name,
      icon: _getIconFor(name),
      color: '#${_getColorFor(name).toRadixString(16).padLeft(8, '0')}',
      type: type,
    );

    await categoryRepo.insert(newCategory);
    DataChangeBus.instance.notify();

    return newCategory;
  }

  Future<Category?> getByName(String name, {String? type}) async {
    return await categoryRepo.getByName(name, type: type);
  }

  String _getIconFor(String name) {
    switch (name.toLowerCase()) {
      case 'fuel':
        return 'local_gas_station';
      case 'food':
        return 'restaurant';
      case 'transport':
        return 'directions_bus';
      case 'salary':
        return 'payments';
      case 'rent':
        return 'home';
      case 'bills':
        return 'receipt';
      case 'emi':
        return 'credit_score';
      case 'loan':
        return 'account_balance';
      case 'maintenance':
        return 'build';
      case 'service':
        return 'plumbing';
      case 'insurance':
        return 'verified_user';
      case 'parking':
        return 'local_parking';
      default:
        return 'category';
    }
  }

  int _getColorFor(String name) {
    switch (name.toLowerCase()) {
      case 'fuel':
        return 0xFFFFA000; // Orange
      case 'food':
        return 0xFFF44336; // Red
      case 'transport':
        return 0xFF2196F3; // Blue
      case 'salary':
        return 0xFF4CAF50; // Green
      case 'rent':
        return 0xFF9C27B0; // Purple
      case 'bills':
        return 0xFF607D8B; // Blue Grey
      case 'maintenance':
        return 0xFF795548; // Brown
      case 'insurance':
        return 0xFF00BCD4; // Cyan
      default:
        return 0xFF9E9E9E; // Grey
    }
  }
}
