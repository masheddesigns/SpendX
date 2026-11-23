# SpendX — Remaining Issues & Action Plan

Consolidated from code audit (`docs/audit_report.md`) and UI/UX audit (`docs/ui_ux_audit.md`), updated to current state (commit `dcdf97a`).

**Current baseline:** `flutter analyze lib/` = 0 issues · `flutter test` = 1,865/1,869 (3 pre-existing isolation failures) · CI = green

---

## P0 — Critical (do before next release)

### 1. Accessibility (Score: 3/10)
**Problem:** 13 `Semantics` widgets for entire app. Screen readers cannot navigate. 112 custom tap targets, only 6 enforce 48px min. Zero `Tooltip` widgets (37 `tooltip:` props).
**What to do:**
- Add `Semantics(label: ..., button: true)` to every `IconButton`, `GestureDetector`, `InkWell`.
- Add `tooltip:` to all icon-only buttons.
- Wrap custom tap targets in `SizedBox(width: 48, height: 48)` or set `minimumSize: Size(48,48)`.
- Run with TalkBack/VoiceOver to verify.

### 2. Form Validation (Score: 3/10)
**Problem:** Only 8 `validator:` usages. Most inputs (add expense, onboarding, settings) accept invalid/empty data.
**What to do:**
- Add `validator` to every `TextFormField` in `add_expense_screen.dart`, `onboarding_screen.dart`, `add_bank_account_screen.dart`, `add_goal_screen.dart`.
- Disable submit button until form is valid (`FormState.isValid`).
- Add input formatters for amounts (currency masking).

### 3. Theme Migration (Score: 5/10)
**Problem:** 1,218 hardcoded `Color(0x…)` + 657 `Colors.xxx`. Adaptive tokens exist (`context.textPrimary`, `AppColors.textPrimaryOf`) but screens still use dark-only `AppColors` aliases and hardcoded colors.
**What to do:**
- Migrate screen-by-screen: replace `AppColors.primaryText` → `context.textPrimary`, `const Color(0xFF...)` → `Theme.of(context).colorScheme.xxx`.
- Start with high-traffic screens: home dashboard, add expense, transaction detail, account list.
- Use find-and-replace per file, verify in both light/dark mode.

### 4. Layout Safety (Score: 4/10)
**Problem:** 576 `Row(` vs 282 `Expanded(`. Only 78 `TextOverflow`. 5 `LayoutBuilder`. Long text overflows on narrow devices.
**What to do:**
- Add `Expanded`/`Flexible` to Row children that can grow.
- Add `overflow: TextOverflow.ellipsis` + `maxLines: 1` to all dynamic text (merchant names, notes, account names).
- Add `LayoutBuilder` for responsive breakpoints on dashboard cards.

---

## P1 — Important (next sprint)

### 5. Shared State Widgets
**Problem:** No `LoadingView`, `EmptyState`, or `ErrorView`. 30 ad-hoc spinners, 24 empty-state strings.
**What to do:** Create 3 shared widgets in `lib/shared/widgets/`. Replace ad-hoc implementations across screens.

### 6. Touch Target Enforcement
**Problem:** 112 custom tap targets, 6 min-size constraints.
**What to do:** Audit `GestureDetector`/`InkWell` usages. Wrap in `SizedBox(48,48)` or set `minimumSize`.

### 7. Pull-to-Refresh
**Problem:** Only 14 `RefreshIndicator` for ~60 scrollable screens.
**What to do:** Add `RefreshIndicator` to all scrollable lists (transactions, accounts, goals, reports).

### 8. Gemini AI — remaining
**Problem:** User can now set key via Settings, but no validation that key works. No fallback UI when key is missing.
**What to do:** Add a "Test connection" button in settings. Show a banner in AI chat when no key is configured.

### 9. Remaining 3 test failures (test-isolation)
**Problem:** `c10_security_hardening_test` (backup snapshot filename), `c12_p1_startup_encryption_test` (DB gate lifecycle), `milestone_4_5b_step5_test` (temp dir cleanup).
**What to do:** These are flaky/environmental. Investigate individually — likely test ordering or shared state. Not production bugs.

---

## P2 — Nice to have

### 10. Hardcoded Colors Cleanup
**Problem:** 1,218 `Color(0x)` + 657 `Colors.xxx`.
**What to do:** Migrate to `ColorScheme` after theme migration (P0-3). Use `Theme.of(context).colorScheme.primary` etc.

### 11. Empty State Illustrations
**Problem:** Empty states are text-only.
**What to do:** Add SVG illustrations to empty states (assets already has logo.svg).

### 12. Reduced Motion Support
**Problem:** No `MediaQuery.disableAnimations` check.
**What to do:** Wrap animations in `if (!MediaQuery.of(context).disableAnimations)`.

### 13. Deep Linking
**Problem:** No route table. `singleTask` launchMode but no intent filters for deep links.
**What to do:** Add `go_router` or named routes with deep link support.

### 14. Onboarding Refactor
**Problem:** 1,180-line monolithic screen.
**What to do:** Split into step widgets. Extract step indicator.

---

## Already Fixed (for reference)

| Area | Before | After |
|---|---|---|
| Test failures | 583 | 3 |
| Analyze issues | 219 | 0 |
| CI status | Red (every push) | Green |
| Schema drift (currency, source_record_id) | Broken | Fixed |
| SMS parser (SBI, Jupiter, cashback) | 16 failures | 0 |
| Semantics widgets | 2 | 13 |
| TextOverflow | 66 | 78 |
| Validators | 6 | 8 |
| Theme tokens | Dark-only | Adaptive resolvers + context extension |
| Primary FAB | None | Added with semantics |
| Gemini AI in release | Silently dead | User-configurable via Settings |
| Backup/restore version checks | Hardcoded 24 | Updated to 26 |

---

## Suggested order of attack

1. **Week 1:** Accessibility pass (P0-1) — highest impact for Play Store review
2. **Week 2:** Form validation (P0-2) + Layout safety (P0-4)
3. **Week 3:** Theme migration (P0-3) — screen by screen
4. **Week 4:** Shared state widgets (P1-5) + touch targets (P1-6)
5. **Ongoing:** Pull-to-refresh, deep linking, onboarding refactor

---

*Generated after full audit + remediation cycle at commit `dcdf97a`.*