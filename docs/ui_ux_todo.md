# SpendX UI/UX audit — current status

Reviewed on 2026-11-23 against the current Flutter source. Counts below are source indicators, not quality scores by themselves. Historical audit counts were stale and should not be used as the current baseline.

## Current scorecard (estimate)

| Area | Current | Evidence / remaining work |
|---|---:|---|
| Accessibility | 6/10 | 43 `Semantics` nodes, 65 tooltip properties, and 63 `IconButton`s. Added explicit names and selection state to expense type choices; category icon and color choices also have labels. Icon buttons and shared clean icon buttons are labeled. Remaining custom tap areas still need a screen-by-screen review. TalkBack/VoiceOver verification is intentionally excluded per product preference. |
| Theme / dark mode | 7/10 | Adaptive theme context tokens are in use. Obvious neutral text and financial status roles were moved to `ColorScheme` in the category pickers, credit payment/EMI, net worth reports, and activity analytics. 205 fixed color literals remain, mostly intentional chart, category, brand, and glass palettes; full light/dark visual review remains. |
| Responsiveness | 7/10 | 124 overflow declarations, 354 `Expanded`/`Flexible` uses, and 14 `LayoutBuilder`s. Credit card, Accounts, home, bottom navigation, and expense type choices now adapt to narrow layouts. At 320 dp, key labels and amounts fit; Accounts and Add Expense were also checked at 1.3 system text scale. Other screens and tablet widths still need review. |
| Forms | 6/10 | All 10 `TextFormField`s currently have validators. Review domain rules, input formatting, and submit feedback on each workflow. |
| Loading / empty / error | 8/10 | Shared state widgets are used broadly. Retention Metrics now shows a retryable error instead of remaining on a spinner; Usage Analytics keeps its request stable and offers retry. Remaining work is a route-by-route retry audit. |
| Touch targets | 6/10 | Common buttons, `PrimaryButton`, `AppTapScale`, `IconButtonClean`, category choices, and expense type choices enforce 48 dp targets. A full per-control geometry review remains. |
| Navigation | 7/10 | `AppRouteTable` handles recognized routes and sends unknown routes home. Android cold and warm custom links, unknown-route fallback, and toolbar back behavior were verified on the connected phone. iOS device verification remains unavailable in this environment. |
| Motion | 7/10 | Reduced-motion support is used broadly. Receipt overlay, activity indicator, shared `PrimaryButton`, expense type selector, and bottom navigation now stop or skip their motion when requested. Remaining bespoke animations need review. |
| Typography / spacing | 6/10 | Shared text and spacing tokens are available and in use. Continue targeted checks at larger system text sizes; do not mechanically replace intentional visual styles. |

## Work completed in this pass

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

## Remaining work

1. Review custom controls screen by screen for accessible names and 48 dp hit areas, without adding duplicate announcements to already-labeled controls.
2. Review the remaining color literals by visual role in light and dark themes; retain intentional palette colors.
3. Exercise remaining high-value screens at 320 dp, tablet widths, and larger text scales; fix only observed layout problems.
4. Review form rules and error feedback beyond the presence of validators.
5. Confirm every async route has useful loading, empty, error, and retry states.
6. Verify route entry and back behavior on an iOS device, and audit remaining custom animations for reduced motion.

## Notes

- The earlier reports contain obsolete counts. Current source indicators: 205 color literals, 354 `Expanded`/`Flexible` widgets, and 14 `LayoutBuilder`s. Counts are refreshed during this pass and remain rough indicators, not quality scores.
- Do not use a raw color-literal count as a mandate for blanket replacement. Chart series, category palettes, brand marks, and glass effects have intentional fixed colors.
- Automated tests were not run in this pass.
