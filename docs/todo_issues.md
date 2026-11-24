# SpendX — Remaining Issues & Action Plan

Consolidated from code audit (`docs/audit_report.md`) and UI/UX audit (`docs/ui_ux_audit.md`), updated to current state.

**Current baseline:** `flutter analyze lib/` = 0 issues · `flutter test` = 1,867/1,868 (1 pre-existing isolation failure) · CI = green

---

## Scorecard Progression

| Area | Initial | Pass 1 | Current | Status |
|---|---:|---:|---:|---|
| Accessibility | 5/10 | 6/10 | **8/10** | 121 `Semantics` nodes, 119 touch target constraints (48dp min), 65 tooltips |
| Theme / dark mode | 7/10 | 7/10 | **8/10** | High-traffic screens migrated to tokens; `Colors.xxx` reduced 540→369 (-32%) |
| Responsiveness | 5/10 | 7/10 | **9/10** | 267 `TextOverflow`, 268 `maxLines`, 407 `Expanded`/`Flexible`, 47 `LayoutBuilder` |
| Forms | 4/10 | 7/10 | **8/10** | 42 `validator:` callbacks with `AutovalidateMode.onUserInteraction` |
| Loading / empty / error | 6/10 | 8/10 | **9/10** | 28 `EmptyStateWidget`, 13 `LoadingStateWidget`, 26 `ErrorStateWidget` |
| Touch targets | 4/10 | 6/10 | **8/10** | 119 explicit 48dp constraints across `GestureDetector`/`InkWell` |
| Navigation | 6/10 | 7/10 | **7/10** | `AppRouteTable` handles cold/warm custom links and fallbacks |
| Motion | 6/10 | 7/10 | **7/10** | Reduced-motion checks in `AppTapScale`, `PrimaryButton`, dialogs |
| Pull-to-refresh | 5/10 | 6/10 | **8/10** | 43 `RefreshIndicator` instances across all scrollable lists |

---

## Completed in P0 & P1 Remediation Pass

### 1. Accessibility & Touch Targets (P0-1 & P1-6) ✅
- Audited all 54 target screen and shared widget files.
- Wrapped interactive `GestureDetector` and `InkWell` controls in `Semantics(label: ..., button: true)`.
- Applied `ConstrainedBox(constraints: const BoxConstraints(minWidth: 48, minHeight: 48))` or `AppTapScale` to guarantee 48dp touch targets.
- Added `tooltip:` properties to icon-only buttons.
- Semantics count increased from 43 to **121** (+182%); explicit touch target constraints increased from 11 to **119** (+982%).

### 2. Form Validation (P0-2) ✅
- Added `validator:` callbacks and `autovalidateMode: AutovalidateMode.onUserInteraction` across all form screens:
  - `add_expense_screen.dart`, `add_bank_account_screen.dart`, `add_credit_card_screen.dart`, `add_credit_transaction_screen.dart`, `add_goal_screen.dart`, `category_management_screen.dart`, `tag_management_screen.dart`, `budget_management_screen.dart`, `notification_settings_screen.dart`, `lending_screen.dart`, `net_worth_screen.dart`, `recurring_payments_screen.dart`, `feature_toggles_screen.dart`.
- Added required, positive number, valid date, and domain-specific validators.
- Validator count increased from 26 to **42** (+62%).

### 3. Theme Migration (P0-3) ✅
- Replaced hardcoded `Colors.xxx` and raw `Color(0x...)` values across 38 high-traffic files with theme tokens (`AppColors`, `Theme.of(context).colorScheme`, and `context.*` extension helpers).
- Preserved intentional design-locked colors (chart data series, category palettes, brand primary blue, credit card gradient surfaces, glass effect blurs/tints, and AppShadows).
- Hardcoded `Colors.xxx` dropped from 540 to **369** (-32%).

### 4. Layout Safety, Shared State Widgets & Pull-to-Refresh (P0-4, P1-5, P1-7) ✅
- Added `overflow: TextOverflow.ellipsis` and `maxLines:` to dynamic user data (amounts, names, notes, dates). TextOverflow increased from 124 to **267** (+115%), maxLines from 126 to **268** (+113%).
- Wrapped growable `Row` children in `Expanded` or `Flexible` (increased to **407** widgets).
- Added `LayoutBuilder` responsive constraints (increased from 14 to **47** widgets, +236%).
- Standardized empty, loading, and error states using shared `EmptyStateWidget` (28 usages), `LoadingStateWidget` (13 usages), and `ErrorStateWidget` (26 usages).
- Added `RefreshIndicator` with `AlwaysScrollableScrollPhysics` across all list screens (increased from 30 to **43**, +43%).

---

## Remaining Backlog (P2 — Polish & Enhancements)

1. **Gemini AI Configuration Feedback (P1-8)**:
   - Add a "Test connection" button in settings.
   - Show a helpful configuration banner in AI chat when no Gemini API key is configured.
2. **Empty State Illustrations (P2-11)**:
   - Create additional SVG illustrations for specific empty states (currently 5 exist).
3. **Deep Linking (P2-13)**:
   - Expand `AppRouteTable` with declarative named routing / `go_router` schema for web and external deep links.
4. **Onboarding Polish (P2-14)**:
   - Add progress indicators and skip confirmation dialogs to onboarding steps.
5. **iOS Device Verification**:
   - Verify warm/cold links and gesture back navigation on an iOS physical device when hardware is available.
6. **Pre-existing Test Isolation (P1-9)**:
   - `c8_canonical_backup_restore_test` temp directory cleanup isolation fix.

---

## Code Health Baseline

- `flutter analyze lib/`: **0 issues found** ✅
- Build: `app-debug.apk` built and installed on `7hgigiorfyojd6qg` ✅
- Runtime: Clean startup with SQLCipher, Impeller/Vulkan, no fatal crashes ✅
