# SpendX 2.0 — C15 UI/UX Redesign Specification & Discovery

**Status**: SPECIFICATION ONLY / ARCHITECTURALLY LOCKED / NO RUNTIME CODE CHANGES  
**Target Milestone**: C15 Design Foundation & Complete Visual Specification  
**Baseline Commit**: `48e5ede111538982e3b22a987d00874e8626e37b`  

---

## Executive Summary & Architectural Invariant

SpendX 2.0 has successfully closed all foundational engineering phases:
- **Ledger & Accounting**: Double-entry canonical ledger (`EconomicEvent` → `Posting`), strict balance triggers, debit/credit parity.
- **Persistence & Security**: SQLCipher FFI encryption, biometric/Keystore key lifecycle, Android 16 runtime compatibility.
- **Intelligence & Pipelines**: High-volume SMS ingestion pipeline (17,739 messages scanned in 36ms, 724 transactions imported atomically), deterministic forecast engine, Safe-to-Spend domain calculator.

The application core is robust and production-qualified, but the presentation layer remains fragmented, displaying legacy patterns, duplicated component trees, inconsistent styling tokens, and an indirect information architecture.

### Hard Architectural Boundary (LOCKED)
The following subsystems are **STRICTLY LOCKED** and must not be altered during UI/UX work:
1. Canonical `EconomicEvent` → `Posting` data model and SQL triggers.
2. Canonical repositories (`CanonicalFinancialQueryRepository`, `LedgerRepo`, etc.).
3. `FinancialTransactionService` semantics and transaction isolation.
4. Database schema (v24), migrations, and SQLCipher key management.
5. Safe-to-Spend mathematical domain model (`SafeToSpendCalculation`).
6. SMS scanning, parsing, deduplication, and staging pipelines.
7. Backup/Restore cryptographic verification engine.
8. State management contracts (Riverpod providers consuming canonical data).

The UI redesign is strictly a presentation-layer evolution: consuming canonical providers and presenting financial truth with clarity, density, speed, and elegance.

---

## 1. Current UI Audit

A complete audit of `lib/screens/`, `lib/features/`, `lib/widgets/`, and `lib/theme/` reveals the following inventory:

### 1.1 Screen Inventory (68 Screens Total)
| Functional Area | Current Screens | Primary Purpose |
| :--- | :--- | :--- |
| **Shell & Entry** | `SplashScreen`, `OnboardingScreen`, `HomeScreen` | App startup, walkthrough, 5-tab shell |
| **Home & Dashboard** | `HomeDashboard`, `SummarySection`, `SystemStatusStrip`, `WrappedStoryBubbles` | Primary balance and summary display |
| **Transactions** | `TransactionListScreen`, `TransactionDetailScreen`, `SearchFilterScreen`, `AddExpenseScreen` | Transaction browsing, filtering, CRUD |
| **Accounts & Cards** | `AccountListScreen`, `AddBankAccountScreen`, `CreditCardScreen`, `AddCreditCardScreen`, `AddCreditTransactionScreen`, `PayCreditCardScreen`, `CreditEmiDetailScreen`, `EmiDetailScreen`, `CreditHistoryScreen` | Bank accounts, credit cards, EMI schedules |
| **Liabilities & Loans**| `LoansScreen`, `AddLoanScreen`, `LoanDetailScreen`, `LendingScreen`, `LendingReportScreen` | Personal loans, mortgages, peer lending |
| **Tools & Navigation**| `FinancialToolsScreen` (Cash Flow & Wealth sections) | 2x2 grid launcher screens |
| **Planning & Goals** | `PlanTab`, `GoalsScreen`, `AddGoalScreen`, `GoalDetailScreen`, `BudgetManagementScreen` | Savings goals, category budgets |
| **Insights & Reports** | `ReportsScreen`, `MonthlyReportScreen`, `NetWorthScreen`, `NetWorthReportScreen`, `InsightsTab`, `InsightsActivityScreen`, `FinancialHealthScreen`, `FinancialHealthHubScreen` | Analytical reports, net worth trends, health score |
| **Intelligence & SMS** | `AiChatScreen`, `ReviewQueueScreen`, `SmartImportScreen`, `SmsImportScreen`, `ImportPreviewScreen`, `ImportProcessingScreen`, `NotificationsInboxScreen` | AI assistant, review candidates, SMS parser |
| **Settings & Admin** | `MoreScreen`, `ProfileHubScreen`, `ProfileSettingsScreen`, `DataManagementScreen`, `BackupHubScreen`, `DatabaseToolsScreen`, `FeatureTogglesScreen`, `CategoryManagementScreen`, `TagManagementScreen`, `CurrencySelectionScreen`, `IncomeSalaryScreen`, `NotificationSettingsScreen`, `NotificationHelpScreen`, `DataHealthScreen`, `UsageAnalyticsScreen`, `DebugHubScreen`, `RetentionMetricsScreen`, `AboutScreen`, `FeedbackScreen`, `PrivacyPolicyScreen`, `ProgressRewardsScreen`, `GamificationDetailScreen` | System settings, backup, categories, debug |
| **Specialized** | `SalaryScreen`, `ManageCompanyScreen`, `MonthDetailScreen`, `WrappedScreen` | Salary slip ledger, yearly wrapped |

### 1.2 Component Duplication & Fragmentation
The audit identified severe component divergence between `lib/widgets/` and `lib/shared/widgets/`:
1. **App Bars**: `lib/widgets/spendx_app_bar.dart` vs `lib/shared/widgets/spendx_app_bar.dart` vs `lib/shared/widgets/app_bar.dart`.
2. **Buttons**: `lib/widgets/app_button.dart` vs `lib/widgets/common/primary_action_button.dart` vs `lib/shared/widgets/primary_button.dart`.
3. **Empty States**: `lib/widgets/empty_state.dart` vs `lib/shared/widgets/empty_state_widget.dart` vs `lib/widgets/common/spendx_empty_state.dart`.
4. **Dialogs**: `lib/widgets/custom_dialog.dart` vs `lib/shared/widgets/app_dialog.dart` vs `lib/shared/widgets/app_confirm_dialog.dart`.
5. **Snackbars**: `lib/widgets/custom_snackbar.dart` vs `lib/shared/widgets/custom_snackbar.dart`.
6. **Themes**: `lib/theme/app_theme.dart` vs `lib/shared/theme/app_theme.dart`.

---

## 2. Problems Identified in Current UI

1. **Broken Information Hierarchy on Home**:
   - The Home screen leads with `Total Balance` (`-₹85,643.67`) without contextualizing liquid cash versus debt.
   - The core financial engine's primary decision metric, **Safe-to-Spend** (`SafeToSpendCalculation`), is completely absent from the Home screen.
   - Users cannot see their upcoming 14-day commitments, goal earmarks, or liquidity shortfall at a glance.
2. **Navigational "Launcher Maze"**:
   - The primary bottom bar contains `Home`, `Accounts`, `Cash Flow`, `Wealth`, and `More`.
   - `Cash Flow` and `Wealth` tabs do not present actionable financial views; they are intermediary menus containing 2x2 grids of buttons.
   - The most common financial task—browsing and searching transactions—lacks a primary tab and is buried behind a small "View All" button.
   - Budgets are hidden inside `Settings` → `Budget Management`.
3. **Inconsistent Transaction Creation**:
   - `AddExpenseScreen` is a 768-line monolithic form that attempts to handle Expense, Income, and Transfer with dynamic mode switching.
   - The amount input field lacks large numeric keypad focus, slowing down quick one-handed entries.
   - Transfers and credit card payments feel like separate apps rather than first-class ledger workflows.
4. **Visual Ambiguity of Review Candidates**:
   - SMS-imported review candidates are displayed with similar styling to finalized transactions, creating user confusion regarding whether an event has been posted to the ledger.
5. **Aesthetic Inconsistencies**:
   - Excessive reliance on generic rounded cards (16px and 24px corner radii) that reduce data density.
   - Overuse of colorful story bubbles (`WrappedStoryBubbles`) pushing actionable financial metrics below the fold.
   - Light theme suffers from unrefined contrast: pure white backgrounds (`#FFFFFF`) with thin borders (`#E5E7EB`) produce a washed-out appearance on high-DPI OLED screens.

---

## 3. SpendX 2.0 Design Principles

SpendX 2.0 follows a rigorous, productivity-first design philosophy:

1. **Financial Decision Dominance**:
   - Lead with *what the user can safely do today* (Safe-to-Spend), not vanity net worth or unadjusted bank totals.
2. **High Information Density with Breathing Room**:
   - Compact vertical footprints, crisp typographic tabular figures, disciplined padding (12px / 16px), and tight component gaps (6px / 8px).
3. **Dark-First, High-Precision Visuals**:
   - True dark canvas (`#0A0C10`), elevated functional tiers (`#12151D`, `#191D28`), crisp hairline dividers (`#222736`), and subdued neutral text.
4. **Zero Ambiguity in Accounting Semantics**:
   - Positive/Inflow is emerald green (`#10B981`).
   - Negative/Outflow is crimson red (`#F43F5E`).
   - Transfers & Journal adjustments are neutral slate (`#64748B`).
   - Pending review candidates are signaled with amber badges (`#F59E0B`) and dashed borders to denote unposted status.
5. **One-Handed Operational Speed**:
   - Primary interactive triggers, keypads, and sheet actions reside within the bottom 60% of the screen.

---

## 4. SpendX 2.0 Design Tokens

### 4.1 Color System

#### Dark Palette (Primary Target)
| Token Name | Hex Code | Purpose |
| :--- | :--- | :--- |
| `color.bg.canvas` | `#0A0C10` | Base screen canvas background |
| `color.surface.base` | `#12151D` | Standard cards, list items, modal background |
| `color.surface.elevated` | `#191D28` | Popovers, active cards, highlighted containers |
| `color.surface.interactive` | `#232938` | Chip fills, search bars, text input fields |
| `color.border.subtle` | `#1E2330` | Hairline dividers between list rows |
| `color.border.strong` | `#2C3347` | Input field borders, active card borders |
| `color.brand.primary` | `#3B82F6` | Primary CTAs, active tab icons, brand accents |
| `color.brand.primaryMuted`| `#1D3A6B` | Primary selection container, pill backgrounds |
| `color.semantic.income` | `#10B981` | Income, account deposits, positive balances |
| `color.semantic.expense` | `#F43F5E` | Expenses, debit transactions, liabilities |
| `color.semantic.transfer`| `#64748B` | Inter-account transfers, neutral balancing |
| `color.semantic.warning` | `#F59E0B` | Review candidates, budget warnings, alerts |
| `color.semantic.shortfall`| `#E11D48` | Liquidity deficits, safe-to-spend shortfall |
| `color.text.primary` | `#F8FAFC` | Main balance, headings, primary labels |
| `color.text.secondary` | `#94A3B8` | Subtitles, timestamps, category tags |
| `color.text.muted` | `#64748B` | Helper text, disabled states, unselected icons|

#### Light Palette
| Token Name | Hex Code | Purpose |
| :--- | :--- | :--- |
| `color.bg.canvas` | `#F1F5F9` | Slightly cool off-white canvas |
| `color.surface.base` | `#FFFFFF` | Crisp white cards and containers |
| `color.surface.elevated` | `#F8FAFC` | Section highlights, elevated sheets |
| `color.surface.interactive` | `#E2E8F0` | Input backgrounds, chips |
| `color.border.subtle` | `#E2E8F0` | Row separators |
| `color.border.strong` | `#CBD5E1` | Card outlines, input borders |
| `color.brand.primary` | `#2563EB` | Primary blue buttons and active states |
| `color.brand.primaryMuted`| `#DBEAFE` | Subtle blue containers |
| `color.semantic.income` | `#059669` | Inflows, positive values |
| `color.semantic.expense` | `#E11D48` | Outflows, expenses |
| `color.semantic.transfer`| `#475569` | Transfers, neutral indicators |
| `color.semantic.warning` | `#D97706` | Alerts, review required |
| `color.text.primary` | `#0F172A` | Primary text |
| `color.text.secondary` | `#475569` | Secondary text |
| `color.text.muted` | `#94A3B8` | Subtle text and placeholders |

---

### 4.2 Typography System

SpendX 2.0 uses system native fonts (`SF Pro` on iOS/macOS, `Roboto` / `Inter` on Android) with strict tabular figures for numbers.

| Token | Size | Weight | Line Height | Letter Spacing | Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `type.display.hero` | 36px | 700 Bold | 44px | -1.0px | Safe-to-Spend primary hero number |
| `type.heading.large`| 24px | 700 Bold | 32px | -0.5px | Screen titles, Net Worth hero |
| `type.heading.medium`| 18px | 600 SemiBold| 24px | -0.3px | Section headers, card titles |
| `type.heading.small`| 15px | 600 SemiBold| 20px | -0.2px | List item headers, account names |
| `type.body.large` | 15px | 400 Regular | 22px | 0.0px | Transaction notes, dialog bodies |
| `type.body.medium`| 13px | 400 Regular | 18px | 0.0px | Secondary descriptions, timestamps |
| `type.caption` | 11px | 500 Medium | 14px | +0.2px | Category tags, status pills, labels |
| `type.numeric.data` | 15px | 600 SemiBold| 20px | -0.2px | Transaction amounts, table columns |
| `type.numeric.keypad`| 28px | 500 Medium | 34px | 0.0px | One-handed amount entry keypad |

---

### 4.3 Spacing, Radius, and Elevation

#### Spacing Scale
- `space.2`: 2px (Hairline offset)
- `space.4`: 4px (Icon-to-text gap)
- `space.8`: 8px (Inner component gap, chip padding)
- `space.12`: 12px (Card list gap, tight horizontal padding)
- `space.16`: 16px (Standard screen gutter, card inner padding)
- `space.24`: 24px (Section separation)
- `space.32`: 32px (Major group separation)

#### Corner Radii
- `radius.xs`: 4px (Badges, mini status pills)
- `radius.sm`: 8px (Text inputs, category chips)
- `radius.md`: 12px (Cards, list tiles, buttons)
- `radius.lg`: 16px (Bottom sheets, dialogue modals)
- `radius.pill`: 999px (Floating pills, capsule filters)

#### Elevation Rules
- SpendX 2.0 is **flat-first**: no fuzzy drop shadows on cards. Separation is achieved through surface tone contrast (`#12151D` on `#0A0C10`) and 1px hairline borders (`#1E2330`).
- Elevation (subtle ambient shadow) is allowed **only** on:
  1. Sticky bottom action bar (`elevation: 4`, shadow color `Colors.black54`)
  2. Floating Action Button (`elevation: 3`)
  3. Modal bottom sheets (`elevation: 8`)

---

## 5. Information Architecture & Navigation

The 5-tab structure replaces intermediate "tool launcher" menus with immediate, high-frequency financial workflows:

```
┌────────────────────────────────────────────────────────────────────────┐
│                          SpendX 2.0 Shell                              │
├─────────────┬─────────────┬──────────────┬──────────────┬──────────────┤
│ 1. Home     │ 2. Activity │ 3. Accounts  │ 4. Planning  │ 5. More      │
│ (Decision)  │ (Ledger)    │ (Positions)  │ (Forward)    │ (System)     │
└─────────────┴─────────────┴──────────────┴──────────────┴──────────────┘
```

### Tab Responsibilities

1. **Tab 1: Home (Decision Center)**
   - Hero: Safe-to-Spend card (floored allowance, horizon, shortfall deficit warning).
   - Liquidity Strip: Total Liquid Cash vs Known Commitments (14 days).
   - Review Alert Bar: Staged SMS/candidate badge (`X transactions awaiting review`).
   - Action Hub: One-tap Quick Add row (Expense, Income, Transfer).
   - Recent Transactions: Top 5 entries with direct drill-down.
2. **Tab 2: Activity (The Canonical Ledger Journal)**
   - Complete historical feed of all transactions.
   - Filter bar: Date presets (30d, 90d, Year, Custom), Accounts, Categories, Types (Expense/Income/Transfer).
   - Instant Search: Search by merchant, notes, amount, or tag.
   - Distinct row typography and visual flags for transfers and refunds.
3. **Tab 3: Accounts (Financial Position)**
   - Header: Net Worth & Liquid Available Cash.
   - Grouped sections:
     - Liquid Accounts (Checking, Savings, Cash Wallets)
     - Credit Cards (Outstanding vs Limit, billing cycle status)
     - Debt & Loans (Principal outstanding, next EMI date)
     - Dedicated Assets / Earmarks
   - Tap to view account ledger and reconcile balance.
4. **Tab 4: Planning (Forward-Looking Financials)**
   - Segmented control: `Budgets` | `Goals` | `Upcoming & Bills`.
   - **Budgets**: Category spending caps (read-only overlays against canonical postings).
   - **Goals**: Virtual earmarks with progress bars.
   - **Upcoming**: 14-day and 30-day recurring payment expectations.
5. **Tab 5: More (Intelligence & Management)**
   - Intelligence: AI Assistant (`AiChatScreen`), Spending Insights, Anomaly Alerts.
   - Imports: SMS Import, Smart Import, Review Queue.
   - Reports: Overview, Monthly Breakdown, Cash Flow Trends, Lending.
   - System: Backup & Restore, Data Health, Security & Pin, Settings.

---

## 6. Screen-by-Screen Redesign Specifications

### 6.1 Home Screen (`HomeDashboard`)
- **Primary Hero: `SafeToSpendCard`**
  - Displays `safeToSpend` in `type.display.hero` (e.g., `₹24,350`).
  - Subtitle: `Safe to spend over next 14 days`.
  - When `hasShortfall == true`: card background transitions to dark crimson tint (`#2A1215`), border to `#E11D48`, displaying `Deficit: -₹5,400` with advice to pause discretionary purchases.
  - Tapping opens the **Liquidity Breakdown Sheet** showing: `Liquid Cash` (`₹45,000`) minus `Goal Earmarks` (`₹10,000`) minus `14d Commitments` (`₹10,650`).
- **Review Queue Notification Bar**:
  - Visible only when `pendingReviewCount > 0`.
  - Compact amber banner: `⚠️ 7 new SMS transactions ready for approval` → Tapping opens `ReviewQueueScreen`.
- **Quick Actions Row**:
  - 3 compact tonal buttons: `+ Expense`, `+ Income`, `⇄ Transfer`.
- **Recent Feed**:
  - Shows last 5 posted transactions with category icon, merchant/notes, account name, and amount.

### 6.2 Transaction Experience (`AddExpenseScreen` & Entry Sheets)
- **One-Handed Amount Keypad**:
  - Large numeric display at top (`type.display.hero`), pre-focused.
  - Type toggle capsule: `[ Expense | Income | Transfer ]`.
- **Context Selectors (Horizontal Chips)**:
  - Account Chip: Quick selector modal with balance preview.
  - Category Chip: Grid selector with recent/frequently used categories first.
  - Date Chip: Defaults to `Today`, tap to pick date.
- **Save Trigger**:
  - Large full-width bottom button: `Save ₹450 Expense`.
- **Transfers**:
  - Selecting `Transfer` replaces Category with `From Account` → `To Account`.

### 6.3 Accounts & Net Worth (`AccountListScreen`)
- **Liquid Cash Banner**:
  - Clear banner separating **Liquid Spendable Cash** from **Net Worth**.
  - Explicit visual rule: `Credit Card limits are NOT cash`.
- **Account Cards**:
  - Bank Account: Bank name, masked account number (`••8434`), live balance.
  - Credit Card: Card name, outstanding balance (`-₹28,172`), available credit (`₹71,828 / ₹100,000`), utilization bar (turns amber > 30%, red > 70%).
  - Loan: Current principal outstanding, monthly EMI, interest rate.

### 6.4 Review Queue (`ReviewQueueScreen`)
- **Staging vs Truth Distinction**:
  - Prominent header explaining: `These transactions were detected from SMS and have NOT been posted to your ledger. Review and approve to commit.`
- **Candidate Card**:
  - Merchant / Sender tag.
  - Amount and detected bank account.
  - Smart Category prediction chip (editable inline).
  - Two primary actions: `[ Reject / Dismiss ]` (text button) and `[ Approve & Post ]` (filled button).

### 6.5 Reports & Intelligence (`ReportsScreen`)
- **Interactive Segmented Tabs**: `Overview` | `Spending` | `Cash Flow` | `Net Worth`.
- **Chart Rules**:
  - High-density bar/line charts using `fl_chart`.
  - Grid lines: Subtle `#1E2330`.
  - No decorative gradients inside charts; solid lines and distinct semantic fills.
  - Tooltips display exact date and currency values.

---

## 7. Reusable Component Inventory

To ensure maintainability, all duplicated widgets are consolidated into a single unified directory: `lib/shared/widgets/`:

| Component Name | File Path | Description & Props |
| :--- | :--- | :--- |
| `AppScaffold` | `lib/shared/widgets/app_scaffold.dart` | Shell wrapper with consistent background, safe area, and status bar styling |
| `AppTopBar` | `lib/shared/widgets/app_top_bar.dart` | Unified navigation app bar with back navigation and optional action icons |
| `SafeToSpendCard` | `lib/shared/widgets/safe_to_spend_card.dart`| Decision hero card displaying Safe-to-Spend or shortfall warning |
| `FinancialMetric`| `lib/shared/widgets/financial_metric.dart`| Metric component displaying label, formatted currency, and delta pill |
| `TransactionTile`| `lib/shared/widgets/transaction_tile.dart`| High-density list tile with category icon, merchant, account, and amount |
| `AccountCard` | `lib/shared/widgets/account_card.dart` | Account summary tile with balance, utilization bar, and type badge |
| `AmountKeypad` | `lib/shared/widgets/amount_keypad.dart` | High-speed numeric input keypad for one-handed entry |
| `CategoryPill` | `lib/shared/widgets/category_pill.dart` | Compact chip displaying category icon and title |
| `ReviewBanner` | `lib/shared/widgets/review_banner.dart` | Staged review warning banner with counter badge |
| `EmptyState` | `lib/shared/widgets/empty_state.dart` | Standardized empty placeholder with vector icon and action button |
| `ErrorState` | `lib/shared/widgets/error_state.dart` | Standardized error message with retry trigger |
| `ConfirmDialog` | `lib/shared/widgets/confirm_dialog.dart` | Modal dialog for destructive or financial confirmation |
| `FilterCapsule` | `lib/shared/widgets/filter_capsule.dart`| Horizontal scrollable filter pill with selected/unselected states |

---

## 8. State Presentation & Interaction Rules

### 8.1 Loading, Error, and Empty States
1. **No Indefinite Spinners**:
   - Initial page loads use shimmer skeleton loaders matching exact card layout (`SkeletonLoader`).
   - Action buttons (e.g., Save, Import) display an inline progress indicator inside the button without disabling UI interactivity.
2. **Empty States**:
   - Must guide the user with a single actionable step (e.g., `No transactions in October → + Add Transaction`).
3. **Error Handling**:
   - Network / background failures must show non-blocking toast notifications (`AppSnackbar`).
   - Database / critical errors render full-screen `ErrorState` with an explicit `[ Retry ]` button.

### 8.2 Interaction & Accessibility Rules
1. **Touch Targets**: All interactive elements maintain a minimum touch target of `48 x 48 dp`.
2. **Haptic Feedback**:
   - `HapticFeedback.lightImpact()` on tab switches, category selections, keypad taps.
   - `HapticFeedback.mediumImpact()` on transaction commit / approval.
   - `HapticFeedback.heavyImpact()` on destructive deletion.
3. **Contrast Ratio**:
   - Primary text (`#F8FAFC`) on dark canvas (`#0A0C10`): Contrast ratio > 15:1 (exceeds WCAG AAA).
   - Secondary text (`#94A3B8`) on dark canvas: Contrast ratio > 7:1 (exceeds WCAG AAA).
4. **Reduced Motion**:
   - Respect `MediaQuery.of(context).disableAnimations`. When enabled, transition durations collapse to `Duration.zero`.

---

## 9. Phased Implementation Roadmap

To maintain engineering stability, the redesign will be implemented in sequential, verifiable phases:

- **C15-A — Design System Foundation**:
  - Unify `lib/theme/app_theme.dart` with new dark/light tokens, typography, and spacing.
  - Consolidate common widgets (`lib/shared/widgets/`).
- **C15-B — Navigation & Application Shell**:
  - Restructure `HomeScreen` to the 5-tab architecture (`Home`, `Activity`, `Accounts`, `Planning`, `More`).
- **C15-C — Home Dashboard**:
  - Implement `SafeToSpendCard`, Liquidity Breakdown, Review Banner, and Quick Action row.
- **C15-D — Transaction Experience**:
  - Redesign `AddExpenseScreen` (numeric keypad, one-handed flows) and `TransactionListScreen`.
- **C15-E — Accounts & Liabilities**:
  - Redesign `AccountListScreen`, Credit Card utilization views, and Loan schedules.
- **C15-F — Planning (Budgets & Goals)**:
  - Implement the unified Planning tab (read-only budget overlays and virtual goal earmarks).
- **C15-G — Reports & Intelligence**:
  - Refresh charts and analytics in `ReportsScreen`.
- **C15-H — Settings & System Screens**:
  - Clean up settings hubs, backup screens, and about/feedback views.
- **C15-I — Accessibility & Final Polish**:
  - Audit contrast, touch targets, screen readers, and haptic feedback.

---

## 10. File Scope Matrix

### Files to be Modified / Created in Future Implementation Phases
- `lib/theme/app_theme.dart` (Token consolidation)
- `lib/theme/app_spacing.dart` (Spacing scale)
- `lib/theme/app_motion.dart` (Motion curves)
- `lib/shared/widgets/*` (Consolidated reusable component inventory)
- `lib/features/home/screens/home_screen.dart` (5-tab shell)
- `lib/features/home/screens/home_dashboard.dart` (Decision-first dashboard)
- `lib/features/home/widgets/summary_section.dart` (Safe-to-Spend hero)
- `lib/screens/home/transactions_screen.dart` (Activity journal)
- `lib/screens/expense/add_expense_screen.dart` (One-handed entry)
- `lib/screens/bank/account_list_screen.dart` (Position-focused accounts)
- `lib/screens/plan/plan_tab.dart` (Planning tab)
- `lib/screens/reports_screen.dart` (Decision reports)
- `lib/screens/more/more_screen.dart` (System menu)

### Files Strictly Untouched (LOCKED)
- `lib/data/core/*` (`AppDatabase`, `SpendXDatabaseFactory`, `Tables`, schema triggers)
- `lib/data/repositories/*` (`CanonicalFinancialQueryRepository`, `LedgerRepo`, etc.)
- `lib/data/security/*` (`DatabaseKeyManager`, encryption migration)
- `lib/domain/finance/*` (`Money`, `SafeToSpendCalculation`, `EventSemantics`)
- `lib/services/financial_transaction_service.dart`
- `lib/services/live_sms_service.dart`
- `lib/services/sms_import_service.dart`
- `lib/services/backup_service.dart`
- `lib/services/canonical_forecast_engine.dart`
- `android/*`, `ios/*`, `macos/*` (Native platform code)

---

## Verification & Qualification Gate

```
[✓] Current UI audited across 68 screens and all widget directories
[✓] Design tokens, typography, and dark/light color systems established
[✓] Information architecture restructured to 5 primary decision areas
[✓] Safe-to-Spend confirmed as primary Home dashboard hero
[✓] Component duplication identified for consolidation
[✓] Architectural boundaries strictly locked and respected
[✓] Vehicle scope removed from active C15 design and implementation
[✓] Zero runtime code modified during discovery
```

**C15 Discovery = PASS / CLOSED — Corrected**
