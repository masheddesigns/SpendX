# SpendX — UI/UX Todo List

Current score: **5/10**. Target: **8/10**.  
Last updated: after commit `0b3a054` + uncommitted remediation pass.

---

## 1. Accessibility (Score: 4/10 → target 8/10)

### What's done
- 26 `Semantics` widgets, 63 `tooltip:` props, 5 `Tooltip` widgets
- Primary FAB has `Semantics(button: true, label: 'Add Transaction')`

### What to do
- [ ] Add `Semantics(label: ...)` to every `IconButton`, `GestureDetector`, `InkWell` (currently 112 custom tap targets, most unlabeled)
- [ ] Add `tooltip:` to all icon-only buttons in app bars and toolbars
- [ ] Enforce `minimumSize: Size(48, 48)` on all 112 custom tap targets (currently 10)
- [ ] Add `semanticLabel` to `Image` and `SvgPicture` widgets (logo, icons)
- [ ] Test with TalkBack (Android) and VoiceOver (iOS)
- [ ] Add `MediaQuery.disableAnimations` check before running animations

**Files to touch:** all `lib/screens/**/*.dart`, `lib/features/**/*.dart`, `lib/shared/widgets/**/*.dart`

---

## 2. Theming / Dark Mode (Score: 6/10 → target 8/10)

### What's done
- Adaptive token resolvers: `AppColors.textPrimaryOf()`, `textSecondaryOf()`, `surfaceOf()`, `borderOf()`
- `SpendXThemeContext` extension: `context.textPrimary`, `context.isDark`, `context.surfaceColor`, etc.
- 1,165 hardcoded `Color(0x)` (down from 1,218)

### What to do
- [ ] Migrate `AppColors.primaryText` (dark-only alias) → `context.textPrimary` in all 4 files that use it
- [ ] Replace hardcoded `Color(0xFF...)` with `Theme.of(context).colorScheme.xxx` or `context.xxx`
- [ ] Replace `Colors.red/blue/green/etc.` with semantic tokens (`AppColors.danger`, `AppColors.success`)
- [ ] Remove `isDark ? AppColors.x : const Color(...)` ternaries — use context extension instead
- [ ] Audit `AppShadows` (dark-tinted colors) — use theme-aware shadows
- [ ] Test both light and dark mode on every screen

**Priority files (most hardcoded colors):**
- `lib/screens/bank/account_list_screen.dart` (2,542 lines)
- `lib/screens/transaction_detail_screen.dart` (1,855 lines)
- `lib/screens/expense/add_expense_screen.dart` (1,231 lines)
- `lib/screens/reports/reports_screen.dart` (1,682 lines)

---

## 3. Responsiveness (Score: 4/10 → target 7/10)

### What's done
- TextOverflow 66→78, Expanded 278→282, maxLines 62→74
- 54 SafeArea usages

### What to do
- [ ] Add `Expanded`/`Flexible` to all `Row` children that can grow (currently ~294 unguarded Rows)
- [ ] Add `overflow: TextOverflow.ellipsis` + `maxLines: 1` to all dynamic text (merchant names, account names, notes)
- [ ] Add `LayoutBuilder` for responsive breakpoints on dashboard cards and lists
- [ ] Test on small screens (320px width) and tablets (768px+)
- [ ] Replace non-lazy `ListView(children:)` with `ListView.builder` where lists can be long (14 vs 20)

**Files to touch:** all screens with `Row(` and `Text(` widgets

---

## 4. Forms & Validation (Score: 3/10 → target 7/10)

### What's done
- 13 `validator:` usages (up from 6)
- `app_amount_field.dart` improved

### What to do
- [ ] Add `validator` to every `TextFormField` in:
  - `add_expense_screen.dart` (amount, notes, category)
  - `onboarding_screen.dart` / onboarding steps (currency, amounts)
  - `add_bank_account_screen.dart` (account name, number, balance)
  - `add_goal_screen.dart` (goal name, target amount)
  - `add_credit_card_screen.dart` (card name, limit, due day)
  - Settings screens (API key, thresholds)
- [ ] Disable submit button until form is valid
- [ ] Add input formatters for amounts (currency masking, decimal precision)
- [ ] Add real-time validation feedback (red border + error text)

---

## 5. Loading / Empty / Error States (Score: 4/10 → target 7/10)

### What's done
- `EmptyStateWidget` created (`lib/shared/widgets/empty_state_widget.dart`)
- `LoadingStateWidget` created (`lib/shared/widgets/loading_state_widget.dart`)
- `SpendXEmptyState` + `SpendXStates` in glass widgets
- 44 skeleton loader usages
- 1 SVG illustration (`assets/illustrations/empty_finances.svg`)

### What to do
- [ ] Replace ad-hoc empty states (24 strings) with `EmptyStateWidget` + illustration
- [ ] Replace ad-hoc spinners (30) with `LoadingStateWidget` or skeleton loaders
- [ ] Create shared `ErrorView` widget for error states
- [ ] Add empty state illustrations for: no transactions, no accounts, no goals, no budgets
- [ ] Ensure every async screen has all 3 states (loading, empty, error)

---

## 6. Touch Targets (Score: 4/10 → target 7/10)

### What's done
- 10 `minimumSize` usages (up from 6)
- Primary FAB with 48px touch target

### What to do
- [ ] Audit all 69 `GestureDetector` + 43 `InkWell` usages
- [ ] Enforce `minSize: Size(48, 48)` or wrap in `SizedBox(48, 48)`
- [ ] Check icon buttons in app bars, list tiles, cards
- [ ] Test with "Show layout bounds" in Flutter DevTools

---

## 7. Navigation & Flow (Score: 6/10 → target 7/10)

### What's done
- Onboarding split into 5 step widgets
- Primary FAB on home screen
- Search icon in app bar (replaced add button)

### What to do
- [ ] Add deep linking support (named routes or `go_router`)
- [ ] Add back-button handling on all screens
- [ ] Add swipe-to-go-back gesture on iOS
- [ ] Add route transitions (fade/slide) for consistency

---

## 8. Motion & Animation (Score: 5/10 → target 6/10)

### What to do
- [ ] Add `MediaQuery.disableAnimations` check before animations
- [ ] Add swipe affordance hints for `flutter_slidable` (currently no visual hint)
- [ ] Ensure `app_motion.dart` is used consistently (not ad-hoc durations)
- [ ] Add reduced-motion fallbacks

---

## 9. Typography & Spacing (Score: 6/10 → target 7/10)

### What to do
- [ ] Replace inline `TextStyle(fontSize: ...)` with `AppTextStyles.xxx`
- [ ] Replace hardcoded `EdgeInsets.all(24)` with `AppSpacing.xxx`
- [ ] Ensure consistent font weights across similar elements

---

## Priority Order

### Phase 1 (1-2 days) — High impact, low risk
1. Accessibility: Semantics + tooltips on all icon buttons
2. Touch targets: 48px min on all interactive widgets
3. Form validation: add validators to add-expense, onboarding, settings

### Phase 2 (3-5 days) — Medium impact
4. Theme migration: replace `AppColors` dark aliases with context extension
5. Layout safety: Expanded/Flexible + TextOverflow on all screens
6. Shared state widgets: replace ad-hoc loading/empty/error

### Phase 3 (1-2 weeks) — Polish
7. Hardcoded color cleanup (screen by screen)
8. Deep linking + route transitions
9. Onboarding polish + illustrations
10. Reduced motion + haptic feedback

---

## Quick Wins (can do in 1 hour each)
- [ ] Add `tooltip:` to all `IconButton` in app bars
- [ ] Add `Semantics(label:)` to FAB and primary actions
- [ ] Replace `Colors.red` → `AppColors.danger`, `Colors.green` → `AppColors.success`
- [ ] Add `overflow: TextOverflow.ellipsis` to all `Text` with dynamic content
- [ ] Add `maxLines: 1` to list tile titles

---

*Generated from UI/UX audit at commit `dcdf97a`. Full audit in `docs/ui_ux_audit.md`.*