// DEPRECATED — This screen used the old SalaryService directly.
// Income & Salary is now handled by:
//   - ManageCompanyScreen (company CRUD)
//   - SalaryScreen (dashboard)
// Both use salaryLedgerProvider (Riverpod).
//
// This file is kept as a redirect for any lingering references.

import 'package:flutter/material.dart';
import '../../features/salary/screens/manage_company_screen.dart';

class IncomeSalaryScreen extends StatelessWidget {
  const IncomeSalaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Redirect to the new screen
    return const ManageCompanyScreen();
  }
}
