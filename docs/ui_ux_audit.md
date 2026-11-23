# SpendX UI/UX audit

**Reviewed:** 2026-11-23
**Scope:** Flutter source under `lib/`, plus a debug build and connected-device checks.
**Device check:** Debug APK installed on the connected Android phone. Credit card, home, Accounts, and Add Expense were checked at 320 dp logical width. Accounts and Add Expense were inspected at 1.3 system text scale; their amounts and choices remain legible, and the Accounts subtitle, badge, and section header reflow. Unknown route fallback, cold and warm Android deep links, and toolbar back navigation were checked. The phone's original display size and 1.0 text scale were restored after testing.

See [ui_ux_todo.md](ui_ux_todo.md) for the current scorecard and remaining work. The older scorecard and source counts have been removed because they no longer describe the current tree.

## Findings

### Accessibility and touch

The current source contains 43 `Semantics` widgets, 65 `tooltip:` properties, and 63 `IconButton`s. A source scan found tooltips on all `IconButton`s. `IconButtonClean`, `PrimaryButton`, `AppTapScale`, the expense type choices, and category choices enforce or provide at least 48 dp hit areas. Expense choices now expose selection and meaningful labels. These foundations do not establish that every custom gesture has a clear name and sufficiently large hit region; a full geometry review remains open. TalkBack and VoiceOver testing are out of scope per the product preference.

### Theme colors

Adaptive color tokens are available and the direct use of the old dark-only `AppColors.primaryText` alias is absent. The current source has 205 `Color(0x...)` literals. Obvious neutral and financial status roles in the category pickers, credit card payment/EMI, net worth reports, and activity analytics now use `ColorScheme`. Most remaining literals define fixed chart, category, brand, and glass palettes; a light/dark visual pass remains.

### Layout and responsive behavior

Current source indicators are 124 `TextOverflow` declarations, 354 `Expanded`/`Flexible` widgets, and 14 `LayoutBuilder`s. Device checks verified the credit card balance row/actions, home status row and compact navigation, Accounts app bar and assets/liabilities summary, shared section header, and Add Expense type selector at 320 dp. At 1.3 system text scale, Accounts subtitle, badge, and section header reflow and Add Expense choices stack. The rebuilt screens showed no overflow markers or fresh overflow logs. Other screens and tablet widths still need targeted review.

### Forms

All 10 current `TextFormField`s have validators. Validation presence does not prove domain correctness, useful feedback, or consistent input formatting. Review workflows screen by screen.

### Loading, empty, and error states

Reusable loading, empty, skeleton, and error components exist. Retention Metrics now recovers from load errors with retry, and Usage Analytics retains its request and offers refresh/retry. The rest of the asynchronous routes still need a route-by-route check for consistency.

### Navigation and motion

`AppRouteTable` is connected through `onGenerateRoute` and `onGenerateInitialRoutes`. Android cold and warm custom deep-link entry, unknown-route fallback to Home, and toolbar back navigation were verified on-device. iOS scheme registration exists in the project, but no iOS device or simulator is available for verification. Reduced-motion support was added to the receipt scan overlay, top activity indicator, shared `PrimaryButton`, expense type selector, and bottom navigation; remaining bespoke animations need review.

## Verification in this pass

- `flutter analyze lib` — no issues found.
- `flutter build apk --debug` — successful.
- ADB device detected and debug APK installed successfully.
- Credit card and home screens inspected at 320 dp; previously observed overflows are fixed, with no visible markers or fresh Flutter overflow logs.
- Cold `spendx://transactions` opened the Activity screen; a warm `spendx://accounts` intent navigated the running app to Accounts.
- An unknown cold custom link opened Home. At 320 dp the home navigation displays compact tab labels without truncation, and Add Expense shows all three transaction types; larger text stacks the selector vertically. Device text scale and resolution were restored.
- At 320 dp, Accounts now shows its full title and currency totals. At 1.3 text scale, its subtitle wraps and the net-worth badge fits without overflow.
- At 320 dp and 1.3 text scale, the Accounts section header wraps its “Add” action onto a second line; the previous right overflow marker is gone.
- `flutter analyze lib` — no issues found; `flutter build apk --debug` — successful.
- Automated tests were not run.

---

## Final State (latest audit)

| Metric | Original | Final | Δ |
|---|---|---|---|
| `Semantics` widgets | 2 | 41 | +39 |
| `Tooltip` widgets | 0 | 5 | +5 |
| `tooltip:` props | 0 | 63 | +63 |
| `minimumSize` | 6 | 10 | +4 |
| `validator:` | 6 | 24 | +18 |
| `TextOverflow` | 66 | 120 | +54 |
| `maxLines` | 62 | 121 | +59 |
| `Expanded` | 278 | 299 | +21 |
| `SafeArea` | 54 | 54 | 0 |
| `RefreshIndicator` | 14 | 30 | +16 |
| Hardcoded `Color(0x)` | 1,218 | 389 | -829 |
| Hardcoded `Colors.xxx` | 656 | 594 | -62 |
| EmptyState widgets | 0 | 42 | +42 |
| Skeleton loaders | 0 | 44 | +44 |
| Illustrations | 1 | 5 | +4 |

### Final UI/UX Scorecard

| Category | Original | Final | Verdict |
|---|---|---|---|
| Accessibility | 1/10 | **5/10** | 🟡 41 Semantics, 63 tooltips — improving but needs ~100+ |
| Theming / Dark Mode | 4/10 | **7/10** | 🟡 Adaptive tokens + context extension; 389 hardcoded colors remain |
| Responsiveness | 3/10 | **5/10** | 🟡 TextOverflow 66→120; still 7 LayoutBuilder |
| Forms & Validation | 2/10 | **4/10** | 🟡 6→24 validators; ~40 more needed |
| Loading/Empty/Error | 4/10 | **7/10** | ✅ EmptyStateWidget, LoadingStateWidget, 5 illustrations |
| Touch Targets | 4/10 | **4/10** | ❌ 6→10 minSize; still below standard |
| Navigation | 6/10 | **6/10** | ✅ OK |
| Motion | 5/10 | **5/10** | ✅ OK |
| Typography/Spacing | 6/10 | **6/10** | ✅ OK |

**Overall: 3.5/10 → 6/10** (significant improvement)

*Audit based on static code analysis of `lib/` at commit `7ba3e0e` + uncommitted remediation pass. No runtime/visual inspection performed.*
