# SpendX 2.0 — Milestone A: Legacy Vehicle Subsystem Removal Report

**Status**: COMPLETED & VERIFIED  
**Date**: October 3, 2026  
**Phase**: Milestone A (Pre-Migration Surgical Cleanup)  
**Target Milestone Next**: Milestone B (Migration v24: Double-Entry Canonical Ledger)

---

## 1. Executive Summary

Milestone A has surgically and completely eliminated the obsolete legacy Vehicle domain from the SpendX codebase. All vehicle screens, widgets, providers, state notifiers, calculation engines, reminder services, repositories, and models have been removed.

Critical financial invariants and product boundaries were strictly preserved:
1. **Ordinary Fuel & Transport Expenses**: Preserved intact. Users can log and import fuel expenses under `Transport:Fuel` or category `Fuel`/`Transport` without any requirement for vehicle entities, odometer readings, or tank capacities.
2. **Double-Entry Ledger & Financial Invariants**: Preserved intact. Ledger transactions journal ordinary fuel expenses cleanly, maintaining exact balance parity.
3. **Database Safeties**: In accordance with database safety constraints, no existing tables were dropped during this phase. SQLite table creation definitions in `tables.dart` and `schema_validator.dart` were preserved so existing database migrations and initial schema setups do not fail at runtime. Table dropping is scheduled strictly for Milestone B (Migration v24).
4. **Monetary Storage Clarification**: Corrected terminology in `docs/spendx2/` from "unsigned 64-bit integers" to "signed 64-bit SQLite INTEGER values representing minor currency units, with domain-level CHECK constraints where values must be non-negative".

---

## 2. Inventory of Deleted Files

The entire `lib/features/vehicles/` directory and standalone vehicle repositories/models were deleted cleanly:

### A. Screens & Widgets (`lib/features/vehicles/screens/` & `widgets/`)
- `lib/features/vehicles/screens/add_fuel_screen.dart`
- `lib/features/vehicles/screens/add_reminder_screen.dart`
- `lib/features/vehicles/screens/add_vehicle_entry_screen.dart`
- `lib/features/vehicles/screens/add_vehicle_expense_screen.dart`
- `lib/features/vehicles/screens/add_vehicle_screen.dart`
- `lib/features/vehicles/widgets/activity_timeline.dart`
- `lib/features/vehicles/widgets/cost_summary_card.dart`
- `lib/features/vehicles/widgets/fuel_summary_card.dart`
- `lib/features/vehicles/widgets/reminders_section.dart`
- `lib/features/vehicles/widgets/vehicle_header.dart`

### B. Providers & State Notifiers (`lib/features/vehicles/providers/`)
- `lib/features/vehicles/providers/vehicle_providers.dart`

### C. Services (`lib/features/vehicles/services/`)
- `lib/features/vehicles/services/fuel_intelligence_service.dart`
- `lib/features/vehicles/services/vehicle_reminder_service.dart`
- `lib/features/vehicles/services/vehicle_service.dart`

### D. Repositories (`lib/data/repositories/`)
- `lib/data/repositories/vehicle_repo.dart`
- `lib/data/repositories/vehicle_reminder_repo.dart`

### E. Models (`lib/models/`)
- `lib/models/vehicle.dart` (contained `Vehicle` and `FuelLog`)
- `lib/models/vehicle_reminder.dart` (contained `VehicleReminder`)

---

## 3. Inventory of Modified Files & Severed Dependencies

| File | Modifications Made |
|---|---|
| `lib/models/transaction.dart` | Removed `vehicleId`, `isVehicleExpense`, and `fuelLogId` properties, constructor parameters, and from `toMap()`, `fromMap()`, and `copyWith()`. Decoupled transactions from the vehicle subsystem. |
| `lib/models/reminder_model.dart` | Removed `dueOdometer` property, constructor parameters, and serialization logic. Removed `ReminderSourceType.vehicle`. |
| `lib/features/alerts/data/app_alert.dart` | Removed `AlertType.vehicleService`. Mapped generic maintenance/service reminders directly to `AlertType.subscriptionDue`. |
| `lib/features/alerts/data/alert_service.dart` | Removed dead `ReminderSourceType.vehicle` case. |
| `lib/screens/notifications_inbox_screen.dart` | Removed `AlertType.vehicleService` branch, vehicle snackbar, and vehicle car icon. |
| `lib/screens/onboarding_screen.dart` | Removed `await SettingsService.instance.setEnableVehicles(true)`. |
| `lib/services/settings_service.dart` | Removed `_enableVehiclesKey`, `enableVehicles` getter, `setEnableVehicles(bool)`, and removed vehicle toggle from sync whitelist (`getSyncedSettings` and `applySyncedSettings`). |
| `lib/services/database_helper.dart` | Removed imports of `vehicle.dart` and `vehicle_repo.dart`. Removed deprecated adapter methods: `clearVehicles`, `recalculateVehicleStats`, `getFuelLogById`, `insertFuelLog`, `getVehicleById`, `getAllVehicles`, `insertVehicle`, `deleteVehicle`, `getFuelLogsForVehicle`, `getTransactionsForVehicle`, `deleteFuelLog`. |
| `lib/data/repositories/transaction_repo.dart` | Removed dead method `getVehicleLinkedExpenses()`. |
| `lib/data/repositories/maintenance_repo.dart` | Removed `clearVehicles()` method. |
| `lib/services/notification_service_v2.dart` | Removed vehicle reminder pause block, removed `'vehicle'` payload route, updated comments, and changed notification reminder icon from car to generic build icon. |
| `lib/services/import_service.dart` | Removed imports of `vehicle_repo.dart` and `vehicle.dart`, removed `_vehicleRepo` field/constructor argument, removed vehicle-specific fuel log preview/save methods (`prepareFuelImportPreview`, `saveFuelImportRows`) and `FuelImportRow`. Generic CSV import preserved intact. |
| `lib/services/backup_file_service.dart` | Cleaned backup JSON documentation comment to remove vehicle array reference. |
| `lib/services/backup_service.dart` | Removed `'vehicles'`, `'fuel_logs'`, `'vehicle_reminders'` from `allTableKeys`. |
| `lib/screens/import_screen.dart` | Cleaned inline comment removing vehicle mention. |
| `docs/spendx2/34_FINAL_PRODUCT_DECISION_LOCK.md` | Corrected SQLite monetary storage terminology to signed 64-bit integer minor currency units with non-negative check constraints. |
| `docs/spendx2/01_FINANCIAL_DOMAIN_MODEL.md` | Clarified storage representation as signed 64-bit SQLite INTEGER values representing minor currency units with non-negative check constraints. |

---

## 4. Proof That Ordinary Fuel Expenses Survive

To guarantee that ordinary transportation and fuel expenses are not broken, a dedicated verification test suite was added in [`test/ordinary_fuel_expense_test.dart`](file:///Users/sivek/Documents/SpendX/test/ordinary_fuel_expense_test.dart):
1. **Creation & Ingestion**: Verifies that a user can record an expense with category `Fuel` or `Transport` without any vehicle ID, odometer reading, or vehicle entity.
2. **Storage**: Verifies that `Transaction` persists cleanly to `transactions` table with zero vehicle foreign key dependencies.
3. **Double-Entry Journaling**: Verifies that `FinancialTransactionService.createExpense` journals an `expense` entry to `ledger_transactions` and decrements account balance with mathematical accuracy.
4. **Keyword Ingestion Compatibility**: Verified that SMS/import keyword classification in `lib/core/utils/category_classifier.dart` and `lib/services/smart_importer.dart` correctly identifies fuel and transport transactions.

Both test cases in `test/ordinary_fuel_expense_test.dart` pass with 0 errors.

---

## 5. Verification Output

### A. Static Analysis (`flutter analyze`)
```text
Analyzing SpendX...
38 issues found. (0 errors, 0 warnings, 38 info)
(All 38 info issues are pre-existing print statements in live_sms_service and test file underscore naming conventions).
```
**Result**: 0 errors, 0 warnings.

### B. Test Suite Execution (`flutter test`)
```text
00:13 +116: All tests passed!
```
- Total test files: 7 suites
- Total tests executed: 116 tests
- Passed: 116 / 116 (100%)
- Failed: 0
- Skipped: 1 (optional live real-data backfill gate requiring external environment variable)

---

## 6. Readiness for Milestone B (Migration v24)

The SpendX codebase is now completely free of legacy vehicle subsystem dependencies.
- Zero vehicle entities, widgets, or models remain.
- Zero compilation errors exist.
- All 116 tests pass cleanly.
- The project is officially **READY FOR MILESTONE B (Migration v24: Double-Entry Canonical Ledger Schema & Ingestion Gate)**.
