# SpendX — Harsh UI/UX Audit

**Scope:** All Flutter UI code (`lib/screens`, `lib/features`, `lib/shared`, `lib/widgets`, `lib/theme`).  
**Method:** Static code analysis + pattern detection across 392 Dart files. No visual runtime inspection (web build not exercised).

---

## 1. Accessibility — FAILING

| Finding | Evidence | Severity |
|---|---|---|
| Only **2 `Semantics` widgets** in the entire app | `grep -rn "Semantics(" lib` → 2 | **CRITICAL** |
| Only **36 `semanticLabel`/`tooltip`** across 392 files | grep → 36 | **CRITICAL** |
| **0 `Tooltip` widgets** | grep → 0 | **HIGH** |
| 112 custom tap targets (`GestureDetector` 69 + `InkWell` 43) but only **6 `minimumSize`** constraints | grep counts | **HIGH** |
| Custom icon buttons likely < 48×48 px touch targets | no minSize enforcement | **HIGH** |
| Screen readers cannot navigate or announce content | 2 Semantics for entire app | **CRITICAL** |

**Root cause:** Accessibility was never a requirement. The app is visually driven only. VoiceOver/TalkBack users cannot use SpendX.

**Fix:** Add `Semantics`/`semanticLabel` to every interactive widget, enforce `minimumSize: Size(48,48)` on all tap targets, add `Tooltip` to icon-only buttons.

---

## 2. Theming & Dark Mode — FRAGILE

| Finding | Evidence | Severity |
|---|---|---|
| **1,218 hardcoded `Color(0x…)`** + **656 `Colors.xxx`** in `lib/` | grep counts | **HIGH** |
| `AppColors` aliases to **dark-only** text colors (`primaryText = darkTextPrimary`) | `lib/theme/app_theme.dart` ~line 206 | **HIGH** |
| Light-mode screens using `AppColors.primaryText` get near-white text on light bg | 3 direct usages + many implicit | **HIGH** |
| Developers work around with `isDark ? AppColors.x : const Color(...)` — inconsistent | recurring_payments_screen, loan_detail_screen | **MEDIUM** |
| Shadows use fixed `Color(0x0A18274B)` (dark-tinted) — wrong in light mode | `AppShadows.card` | **MEDIUM** |
| Only **3 theme variants** (all violet-indigo) — no true light/dark system integration | `availableThemes` | **LOW** |

**Root cause:** No single source of truth for theme-aware colors. `ColorScheme` exists but `AppColors` bypasses it. Dark mode is bolted on via manual `isDark` ternaries scattered across screens.

**Fix:** Make all colors resolve through `Theme.of(context).colorScheme`. Remove `AppColors` dark-only aliases. Use `Theme.of(context).brightness` consistently.

---

## 3. Layout & Responsiveness — OVERFLOW PRONE

| Finding | Evidence | Severity |
|---|---|---|
| **576 `Row(`** vs **278 `Expanded(`** — ~50% of rows have no flexible children | grep counts | **HIGH** |
| Only **1 `FittedBox`** in entire app | grep → 1 | **MEDIUM** |
| Only **66 `TextOverflow`** usages vs hundreds of `Text` widgets | grep counts | **HIGH** |
| Only **5 `LayoutBuilder`** — almost no adaptive layouts | grep → 5 | **MEDIUM** |
| Only **14 `ListView.builder`** vs **20 `ListView(children:)`** | grep counts | **MEDIUM** |
| 62 `maxLines:` usages — many text widgets have no line cap | grep → 62 | **MEDIUM** |

**Root cause:** Layouts are built for a single screen size. No adaptive breakpoints. Long text (merchant names, notes) will overflow on narrow devices.

**Fix:** Add `Expanded`/`Flexible` to all Row children that can grow. Add `overflow: TextOverflow.ellipsis` + `maxLines` to all dynamic text. Use `LayoutBuilder` for responsive breakpoints.

---

## 4. Forms & Input Validation — WEAK

| Finding | Evidence | Severity |
|---|---|---|
| Only **6 `validator:`** usages across entire app | grep → 6 | **HIGH** |
| Add expense screen (1,231 lines) — likely has minimal validation | file size | **HIGH** |
| No visible input masking (currency, phone) | grep for InputFormatter | 0 currency formatters | **MEDIUM** |

**Root cause:** Forms trust user input. Empty/invalid submissions can create corrupt transactions.

**Fix:** Add `validator` to every `TextFormField`. Add input formatters for amounts. Disable submit button until valid.

---

## 5. Loading / Empty / Error States — INCONSISTENT

| Finding | Evidence | Severity |
|---|---|---|
| 30 `CircularProgressIndicator` but no standardized skeleton/shimmer | grep → 30 | **MEDIUM** |
| 24 empty-state strings but no shared `EmptyState` widget | grep → 24 | **MEDIUM** |
| 146 `SnackBar` usages — error feedback is inconsistent (some silent) | grep → 146 | **MEDIUM** |
| No global error boundary / crash screen | search | **MEDIUM** |

**Root cause:** Each screen reinvents loading/empty/error UI. Some screens have none.

**Fix:** Create shared `LoadingView`, `EmptyState`, `ErrorView` widgets. Use a global error handler screen.

---

## 6. Touch Targets & Interaction — BELOW STANDARD

| Finding | Evidence | Severity |
|---|---|---|
| 112 custom tap targets, only 6 enforce `minimumSize` | grep counts | **HIGH** |
| `IconButton` default is 48px but custom `GestureDetector`/`InkWell` may be smaller | 69 + 43 custom | **HIGH** |
| No haptic feedback on most actions (only `haptic_service` exists) | grep | **LOW** |
| No pull-to-refresh on most lists (14 `RefreshIndicator`) | grep → 14 | **MEDIUM** |

**Fix:** Enforce `minSize: Size(48,48)` on all interactive widgets. Add `RefreshIndicator` to all scrollable lists.

---

## 7. Onboarding & Navigation — ACCEPTABLE but rough

| Finding | Evidence | Severity |
|---|---|---|
| Onboarding has skip + step indicator (good) | onboarding_screen.dart:120-169 | **LOW** |
| 1,180-line onboarding screen — monolithic | file size | **MEDIUM** |
| No back-button handling on some screens (singleTask launchMode) | AndroidManifest | **LOW** |
| Deep linking not configured (no route table) | grep for routes | **MEDIUM** |

---

## 8. Motion & Animation — UNPOLISHED

| Finding | Evidence | Severity |
|---|---|---|
| `app_motion.dart` exists but usage unclear | 1 file | **LOW** |
| `flutter_slidable` used but no swipe affordance hints | grep | **LOW** |
| No reduced-motion support (`MediaQuery.disableAnimations`) | grep → 0 | **MEDIUM** |

---

## 9. Typography & Spacing

| Finding | Evidence | Severity |
|---|---|---|
| `AppTextStyles` has 18 named styles — good | app_theme.dart | **LOW** |
| But many screens use inline `TextStyle(fontSize: ...)` instead | grep | **MEDIUM** |
| `AppSpacing` exists but usage inconsistent | grep | **MEDIUM** |
| Hardcoded `EdgeInsets.all(24)` etc. (840 total) | grep → 840 | **LOW** |

---

## 10. Summary Scorecard

| Category | Score | Verdict |
|---|---|---|
| Accessibility | 1/10 | **FAIL** — unusable by screen readers |
| Theming / Dark Mode | 4/10 | **FRAGILE** — hardcoded colors, dark-only aliases |
| Responsiveness | 3/10 | **POOR** — overflow-prone, no breakpoints |
| Forms & Validation | 2/10 | **WEAK** — 6 validators total |
| Loading/Empty/Error | 4/10 | **INCONSISTENT** |
| Touch Targets | 4/10 | **BELOW STANDARD** |
| Navigation | 6/10 | **OK** |
| Motion | 5/10 | **OK** |
| Typography/Spacing | 6/10 | **OK** |

## Top 5 Priority Fixes

1. **Accessibility pass** — add Semantics + tooltips + 48px min touch targets (blocks Play Store accessibility review).
2. **Theme token cleanup** — replace `AppColors` dark-only aliases and hardcoded `Color(0x)` with `ColorScheme`-driven values.
3. **Form validation** — add validators to all `TextFormField`s, especially add-expense and onboarding.
4. **Layout safety** — add `Expanded`/`Flexible` to Rows, `TextOverflow.ellipsis` + `maxLines` to dynamic text.
5. **Shared state widgets** — create `LoadingView`/`EmptyState`/`ErrorView` and use everywhere.

---

*Audit based on static code analysis of `lib/` at commit `fdb28d2`. No runtime/visual inspection performed.*