import os

files_to_replace = {
    'lib/screens/auth_screen.dart': [
        (
            "        ScaffoldMessenger.of(context).showSnackBar(\n          SnackBar(content: Text('Google Login Failed: $e')),\n        );",
            "        CustomSnackBar.show(context, message: 'Google Login Failed: $e', isError: true);"
        ),
        (
            "import 'home_screen.dart';",
            "import 'home_screen.dart';\nimport '../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/home_screen.dart': [
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        SnackBar(content: Text('Failed to parse: ${extractedData['error']}')),\n      );",
            "      CustomSnackBar.show(context, message: 'Failed to parse: ${extractedData['error']}', isError: true);"
        ),
        (
            "import 'dart:io'; // Added",
            "import 'dart:io';\nimport '../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/credit_card_screen.dart': [
        (
            "                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Credit card payment recorded successfully'), backgroundColor: Colors.green));",
            "                CustomSnackBar.show(context, message: 'Credit card payment recorded successfully');"
        ),
        (
            "import '../theme/app_theme.dart';",
            "import '../theme/app_theme.dart';\nimport '../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/profile_hub_screen.dart': [
        (
            "                        ScaffoldMessenger.of(context).showSnackBar(\n                          const SnackBar(content: Text('Failed to sync. Please try again.')),\n                        );",
            "                        CustomSnackBar.show(context, message: 'Failed to sync. Please try again.', isError: true);"
        ),
        (
            "                          ScaffoldMessenger.of(context).showSnackBar(\n                            const SnackBar(content: Text('Sync completed successfully!')),\n                          );",
            "                          CustomSnackBar.show(context, message: 'Sync completed successfully!');"
        ),
        (
            "import '../theme/app_theme.dart';",
            "import '../theme/app_theme.dart';\nimport '../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/vehicles/add_fuel_screen.dart': [
        (
            "       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a vehicle')));",
            "       CustomSnackBar.show(context, message: 'Please select a vehicle', isError: true);"
        ),
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        const SnackBar(content: Text('Please fill all required fields correctly')),\n      );",
            "      CustomSnackBar.show(context, message: 'Please fill all required fields correctly', isError: true);"
        ),
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        const SnackBar(content: Text('Fuel log saved successfully')),\n      );",
            "      CustomSnackBar.show(context, message: 'Fuel log saved successfully');"
        ),
        (
            "import '../../services/database_helper.dart';",
            "import '../../services/database_helper.dart';\nimport '../../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/credit_card/emi_detail_screen.dart': [
        (
            "      ScaffoldMessenger.of(context).showSnackBar(SnackBar(\n        content: Text('Successfully recorded EMI payment for ${DateFormat('MMM yyyy').format(installment.dueDate)}'),\n      ));",
            "      CustomSnackBar.show(context, message: 'Successfully recorded EMI payment for ${DateFormat('MMM yyyy').format(installment.dueDate)}');"
        ),
        (
            "import '../../services/database_helper.dart';",
            "import '../../services/database_helper.dart';\nimport '../../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/expense/add_expense_screen.dart': [
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        const SnackBar(content: Text('Please enter an amount and select a category')),\n      );",
            "      CustomSnackBar.show(context, message: 'Please enter an amount and select a category', isError: true);"
        ),
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        const SnackBar(content: Text('Failed to save transaction')),\n      );",
            "      CustomSnackBar.show(context, message: 'Failed to save transaction', isError: true);"
        ),
        (
            "    ScaffoldMessenger.of(context).showSnackBar(\n      const SnackBar(content: Row(children: [\n        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),\n        SizedBox(width: 12),\n        Text('Reading receipt with AI...'),\n      ]), duration: Duration(seconds: 10)),\n    );",
            "    CustomSnackBar.show(context, message: 'Reading receipt with AI...');"
        ),
        (
            "      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read receipt: ${result['error']}'), backgroundColor: Colors.red));",
            "      CustomSnackBar.show(context, message: 'Could not read receipt: ${result['error']}', isError: true);"
        ),
        (
            "    ScaffoldMessenger.of(context).showSnackBar(\n      const SnackBar(content: Text('✓ Receipt scanned! Please verify the details.'), backgroundColor: Colors.green),\n    );",
            "    CustomSnackBar.show(context, message: '✓ Receipt scanned! Please verify the details.');"
        ),
        (
            "import '../../services/gemini_service.dart';",
            "import '../../services/gemini_service.dart';\nimport '../../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/settings/budget_management_screen.dart': [
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        const SnackBar(content: Text('Please select a category and enter a valid limit')),\n      );",
            "      CustomSnackBar.show(context, message: 'Please select a category and enter a valid limit', isError: true);"
        ),
        (
            "import '../../theme/app_theme.dart';",
            "import '../../theme/app_theme.dart';\nimport '../../widgets/custom_snackbar.dart';"
        )
    ],
    'lib/screens/settings/notification_settings_screen.dart': [
        (
            "      ScaffoldMessenger.of(context).showSnackBar(\n        const SnackBar(content: Text('Could not find app settings. Please open settings manually.')),\n      );",
            "      CustomSnackBar.show(context, message: 'Could not find app settings. Please open settings manually.', isError: true);"
        ),
        (
            "import '../../theme/app_theme.dart';",
            "import '../../theme/app_theme.dart';\nimport '../../widgets/custom_snackbar.dart';"
        )
    ]
}

base_dir = '/Users/sivek/Documents/SpendX'

for relative_path, replacements in files_to_replace.items():
    full_path = os.path.join(base_dir, relative_path)
    if os.path.exists(full_path):
        with open(full_path, 'r') as f:
            content = f.read()
        
        for search, replace in replacements:
            if search in content:
                content = content.replace(search, replace)
            else:
                print(f"FAILED TO FIND MATCH IN {relative_path}:\n{search}\n")
        
        with open(full_path, 'w') as f:
            f.write(content)
        print(f"Updated {relative_path}")
print("Done")
