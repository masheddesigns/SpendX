import 'category_service.dart';

class AutoCategorizationService {
  AutoCategorizationService._(this.categoryService);

  final CategoryService categoryService;

  static final instance =
      AutoCategorizationService._(CategoryService.instance);

  static final Map<String, String> keywordMap = {

    "fuel": "Fuel",
    "petrol": "Fuel",
    "diesel": "Fuel",
    "gas": "Fuel",
    "shell": "Fuel",
    "hpcl": "Fuel",
    "bpcl": "Fuel",
    "uber": "Transport",
    "ola": "Transport",
    "bus": "Transport",
    "metro": "Transport",
    "rapido": "Transport",
    "zomato": "Food",
    "swiggy": "Food",
    "restaurant": "Food",
    "dinner": "Food",
    "lunch": "Food",
    "salary": "Salary",
    "bonus": "Salary",
    "rent": "Rent",
    "emi": "EMI",
    "loan": "Loan",
    "electricity": "Bills",
    "water": "Bills",
    "internet": "Bills",
    "wifi": "Bills",
    "phone": "Bills",
    "mobile": "Bills",
  };

  static Future<String?> detectCategoryName(String text) async {
    final lower = text.toLowerCase();

    for (final entry in keywordMap.entries) {
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  static Future<String?> detectCategoryId(String text, {String type = 'expense'}) async {
    final name = await detectCategoryName(text);
    if (name != null) {
      final category = await CategoryService().getOrCreate(name, type: type);
      return category.id;
    }
    return null;
  }
}
