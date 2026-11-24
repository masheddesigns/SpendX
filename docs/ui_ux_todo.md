# SpendX UI/UX audit — current status

Reviewed on 2026-11-24 against the current Flutter source and connected Android devices. Counts below are source indicators, not quality scores by themselves.

## Current scorecard (estimate)

| Area | Current | Evidence / remaining work |
|---|---:|---|
| Accessibility | 6/10 | 43 `Semantics` nodes, 65 tooltip properties, and 63 `IconButton`s. Added explicit names and selection state to expense type choices; category icon and color choices also have labels. Icon buttons and shared clean icon buttons are labeled. Remaining custom tap areas still need a screen-by-screen review. TalkBack/VoiceOver verification is intentionally excluded per product preference. |
| Theme / dark mode | 7/10 | Light and dark palettes were visually reviewed on Home, Accounts, Settings, and representative empty states. Role review confirms remaining literals are predominantly brand, category, chart, semantic status, and glass treatments. Data-heavy chart palettes still need review with representative datasets in both themes. |
| Responsiveness | 7/10 | 124 overflow declarations, 355 `Expanded`/`Flexible` uses, and 14 `LayoutBuilder`s. The current debug build was checked on the Redmi at 393 dp and 1.3 text scale; the Home timeline now reflows and logged no fresh RenderFlex overflow. A Samsung tablet at 800 dp and 1.3 text scale was reviewed in light mode using its installed build. Other screens still need targeted review. |
| Forms | 7/10 | 26 validator properties. Loan creation checks required names, amount, rate, tenure, due day, and EMI; credit-card payment validates positive amounts and reports save failures. Category, tag, budget, notification-contact, and goal forms also have required or domain-specific checks. Other workflows still need business-rule review. |
| Loading / empty / error | 8/10 | Shared state widgets are used broadly. Retention Metrics, Usage Analytics, credit-card sections, payment-account loading, and Insights failures now offer retry. Remaining work is a route-by-route retry audit. |
| Touch targets | 6/10 | Common buttons, `PrimaryButton`, `AppTapScale`, `IconButtonClean`, category choices, and expense type choices enforce 48 dp targets. A full per-control geometry review remains. |
| Navigation | 7/10 | `AppRouteTable` handles recognized routes and sends unknown routes home. Android cold and warm custom links, unknown-route fallback, and toolbar back behavior were verified on the connected phone. iOS device verification remains unavailable in this environment. |
| Motion | 7/10 | Reduced-motion support is used broadly. Receipt overlay, activity indicator, shared `PrimaryButton`, expense type selector, and bottom navigation now stop or skip their motion when requested. Remaining bespoke animations need review. |
| Typography / spacing | 6/10 | Shared text and spacing tokens are available and in use. Continue targeted checks at larger system text sizes; do not mechanically replace intentional visual styles. |

## Work completed in this pass

- Reviewed the light/dark roles in the shared theme, alert and financial status colors, category palette, chart colors, brand colors, glass surfaces, and custom transaction surfaces. Representative Home, Accounts, Settings, and empty-state screens remained legible in both themes. Kept intentionally fixed identity and data-series palettes.
- The Home cash-flow timeline now increases its label and painter height with system text scale. At 1.3 scale, the clipped Inflow date is fully visible and the connected Redmi produced no fresh overflow log after the rebuild.
- The shared bottom navigation now grows with larger text, preserving label space instead of overflowing its fixed-height bar.
- Credit-card detail sections now replace raw exception strings with concise retry actions. Payment accounts have an inline retry state; payment amount validation, no-account feedback, duplicate-submit protection, and a save-failure message were added.
- Add Loan now validates required names, positive principal, nonnegative rate, 1–600 month tenure, due day 1–31, and a positive EMI. Save remains available to show field-level errors instead of silently disabling itself.
- Installed the 32-bit debug build on the Samsung SM-T515 (800 dp). Its first-run welcome screen and SMS permission prompt rendered. After declining permission and skipping onboarding, Home rendered at 1.3 text scale without visible clipping or Flutter overflow logs. Restored the tablet's original 1200×1920 display and 1.1 text scale, then reopened its release app.
- Restored the Redmi to 1080×2340, 1.0 text scale, and Light theme after testing.

- Receipt scanning now uses an instant dialog transition and a static scan graphic when reduced motion is enabled.
- The top activity indicator stops its pulse, rotation, slide, and container transition in reduced-motion mode. Its dismiss control now has a 48 dp minimum.
- Shared `PrimaryButton` controls now enforce a 48 dp height minimum and disable their press animation when reduced motion is enabled.
- The credit card summary now stacks limit/available amounts below 340 dp, and its two main actions stack at the same breakpoint. At 320 dp, the card screen displayed without RenderFlex overflow markers.
- A 4.5 px home-screen overflow was reproduced at 320 dp in the upcoming-bill status row. The status now wraps to two lines, and the month-end marker stays within the journey track; the narrow home view now shows no overflow markers.
- `flutter analyze lib` completed with no issues.
- A debug APK built successfully and was installed on the connected Android device. The credit card screen was inspected at the device's normal width and at 320 dp; recent logs showed no Flutter overflow warning.
- Android custom links were verified on the connected device: a cold `spendx://transactions` launch opened Activity, and a warm `spendx://accounts` link navigated an already-running app to Accounts. The warm-link bridge buffers early native events and routes them through `AppRouteTable` after Flutter navigation is ready.
- Unknown Android custom links now resolve to Home. The expense type selector uses full stacked labels at narrow widths and larger text sizes, has a 48 dp minimum height, and exposes selected state and a meaningful semantic name.
- The home navigation uses shorter visible labels on compact widths while preserving full semantic labels. Its selection animation respects reduced-motion settings.
- Accounts now moves the consolidate action into a compact menu and stacks asset/liability totals when space is limited. Its subtitle and negative net-worth badge wrap safely at larger text sizes.
- Shared section headers now move their trailing action below the title on compact or larger-text layouts. The Accounts section header was verified at 320 dp and 1.3 text scale without overflow.
- Retention Metrics now catches load failures and exposes retry. Usage Analytics reuses its future across rebuilds, exposes refresh/retry, and uses a theme-aware duration label.
- Neutral informational text in category pickers, credit card payment/EMI, and report empty states now uses `ColorScheme` roles.
- Net worth report tabs, snapshot labels, and positive/negative indicators now use theme primary, secondary, error, and on-surface-variant roles.
- Insights provider failures that previously returned empty widgets now show concise theme-aware error text and a Retry action for the affected provider.
- Removed runtime `GoogleFonts.inter()` theme calls; Android now uses its platform typography, so startup does not depend on a network font fetch.

## Remaining work

1. Finish screen-by-screen geometry and naming checks for custom tap targets. TalkBack and VoiceOver remain excluded by preference.
2. Check chart/category colors with populated data in both themes; this pass reviewed representative screens and source roles, not every graph and category combination.
3. Continue the 320 dp, tablet, and larger-text pass across remaining routes.
4. Review domain rules and formatting on remaining forms.
5. Finish the async retry audit route by route. The tablet first-run view rendered onboarding behind an SMS permission prompt; the earlier blank report was not reproduced, and runtime font fetching is removed.
6. Verify route entry and back behavior on an iOS device, and audit remaining custom animations for reduced motion.

## Notes

- Current source indicators: 43 `Semantics`, 65 tooltip properties, 63 `IconButton`s, 26 validator properties, 124 `TextOverflow` declarations, 126 `maxLines`, 355 `Expanded`/`Flexible` widgets, 14 `LayoutBuilder`s, 30 `RefreshIndicator`s, 11 `minimumSize` properties, and 205 `Color(0x...)` literals. Counts are rough indicators, not quality scores.
- Do not use a raw color-literal count as a mandate for blanket replacement. Chart series, category palettes, brand marks, and glass effects have intentional fixed colors.
- `flutter analyze lib` and a split-per-ABI Android debug build completed successfully. Automated tests were not run in this pass.
