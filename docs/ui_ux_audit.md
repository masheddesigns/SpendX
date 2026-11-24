# SpendX UI/UX audit

**Reviewed:** 2026-11-24
**Scope:** Flutter source under `lib/`, plus a debug build and connected-device checks.
**Device check:** The Redmi was checked at 320 dp in prior passes and at its normal 393 dp width with 1.3 text scale. A Samsung SM-T515 tablet (800 dp logical width) ran the current debug build at 1.3 text scale in light mode. Its first-run onboarding permission prompt and Home rendered; Home showed no visible clipping or Flutter overflow logs. Both devices were restored to their original display and text settings.

See [ui_ux_todo.md](ui_ux_todo.md) for the current scorecard and remaining work. The older scorecard and source counts have been removed because they no longer describe the current tree.

## Findings

### Accessibility and touch

The current source contains 43 `Semantics` widgets, 65 `tooltip:` properties, and 63 `IconButton`s. A source scan found tooltips on all `IconButton`s. `IconButtonClean`, `PrimaryButton`, `AppTapScale`, expense choices, and category choices provide 48 dp hit areas. A full geometry and naming review of custom gestures remains open. TalkBack and VoiceOver testing are out of scope per the product preference.

### Theme colors

Adaptive color tokens are available and the direct use of the old dark-only `AppColors.primaryText` alias is absent. The current source has 205 `Color(0x...)` literals. Neutral text and status roles use `ColorScheme`; remaining literal uses cluster around category, chart, brand, alert, and glass roles. Light and dark appearances were visually reviewed on Home, Accounts, Settings, and representative empty states. Data-heavy chart and category combinations still need review with representative data.

### Layout and responsive behavior

Current source indicators are 124 `TextOverflow` declarations, 355 `Expanded`/`Flexible` widgets, and 14 `LayoutBuilder`s. At 1.3 text scale, the Home journey's Inflow date overflowed by 1 px; its label and canvas now grow with text scale. The Redmi showed no fresh overflow log after the fix. The tablet showed Home at 800 dp and 1.3 text scale without visible clipping. Other screens still need targeted review.

### Forms

There are 26 validator properties. Add Loan now checks required names, a positive principal, a nonnegative rate, 1–600 month tenure, due day 1–31, and positive monthly EMI. Pay Credit Card now shows amount errors instead of silently returning. Add/edit category, tag, budget, notification-contact, and goal forms have required or domain-specific checks. Review business rules and formatting on remaining workflows.

### Loading, empty, and error states

Reusable loading, empty, skeleton, and error components exist. Credit-card sections, payment-account loading, Retention Metrics, Usage Analytics, and Insights provider errors now have retry controls. The rest of the async routes still need a route-by-route check. Theme creation no longer requests Inter from Google Fonts at runtime, removing that network dependency from first paint.

### Navigation and motion

`AppRouteTable` is connected through `onGenerateRoute` and `onGenerateInitialRoutes`. Android cold and warm custom deep-link entry, unknown-route fallback to Home, and toolbar back navigation were verified on-device. iOS scheme registration exists in the project, but no iOS device or simulator is available for verification. Reduced-motion support was added to the receipt scan overlay, top activity indicator, shared `PrimaryButton`, expense type selector, and bottom navigation; remaining bespoke animations need review.

## Verification in this pass

- `flutter analyze lib` — no issues found.
- `flutter build apk --debug` — successful.
- ADB device detected and debug APK installed successfully.
- The current 32-bit debug build opened on the SM-T515. First run rendered onboarding behind an SMS permission prompt; after declining permission and skipping onboarding, Home rendered at 800 dp and 1.3 text scale. No fresh `RenderFlex overflowed` or fatal startup logs appeared.
- Credit card and home screens inspected at 320 dp; previously observed overflows are fixed, with no visible markers or fresh Flutter overflow logs.
- Cold `spendx://transactions` opened the Activity screen; a warm `spendx://accounts` intent navigated the running app to Accounts.
- An unknown cold custom link opened Home. At 320 dp the home navigation displays compact tab labels without truncation, and Add Expense shows all three transaction types; larger text stacks the selector vertically. Device text scale and resolution were restored.
- At 320 dp, Accounts now shows its full title and currency totals. At 1.3 text scale, its subtitle wraps and the net-worth badge fits without overflow.
- At 320 dp and 1.3 text scale, the Accounts section header wraps its “Add” action onto a second line; the previous right overflow marker is gone.
- `flutter analyze lib` — no issues found; `flutter build apk --debug` — successful.
- Automated tests were not run.


## Current verification and remaining work

- `flutter analyze lib` completed with no issues.
- `flutter build apk --debug --split-per-abi` completed successfully. The current debug build was installed on the Redmi and checked at 1.3 text scale; after the Home timeline fix there were no fresh RenderFlex overflow logs.
- The Samsung SM-T515 is 32-bit only. The matching debug APK installed. First run showed onboarding and an SMS permission prompt; after declining and skipping, Home rendered. Runtime Google Fonts fetching has been removed. The release app was reopened and the tablet's original 1200×1920 size and 1.1 text scale were restored.
- The Redmi was restored to 1080×2340, 1.0 text scale, and Light theme. Its screen size and text scale are normal.
- Source indicators: 43 Semantics, 65 tooltip properties, 63 IconButtons, 26 validator properties, 124 TextOverflow declarations, 126 maxLines, 355 Expanded/Flexible widgets, 14 LayoutBuilders, 30 RefreshIndicators, 11 minimumSize properties, and 205 fixed Color literals.
- Automated tests were not run. The remaining work is a full custom-gesture geometry review, data-backed chart palette review, remaining route checks at tablet and large text sizes, route-by-route async retry review, and iOS verification. TalkBack and VoiceOver remain excluded by preference.
