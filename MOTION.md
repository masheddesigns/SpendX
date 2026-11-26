# SpendX Motion System (`MOTION.md`)

> Single source of truth for animation timing, curves, tactile feedback, and performance rules in SpendX.
> All animations must use [`lib/theme/app_motion.dart`](lib/theme/app_motion.dart) (`AppMotion`, `AppMotionContext`) or [`lib/theme/playful_tokens.dart`](lib/theme/playful_tokens.dart) (`PlayfulTokens`).

---

## 1. Motion Philosophy
- **Purposeful & snappy:** Every animation must clarify spatial hierarchy, confirm a financial action, or provide tactile feedback—never delay the user from logging an expense.
- **Muscle-memory consistency:** Stick to the defined duration tiers and curves so taps, sheets, and routes feel unified across the app.
- **Accessibility first:** Every animated widget **must** respect `MediaQuery.disableAnimationsOf(context)` via `AppMotion.duration(context, ...)` or `context.reduceMotion` / `context.motionDuration(...)`.

---

## 2. Duration & Curve Tokens

### Standard UI Motion (`AppMotion`)
| Token | Value | Curve | Use Case |
| :--- | :--- | :--- | :--- |
| `AppMotion.fast` | `120ms` | `AppMotion.curveSpring` (`easeOutQuart`) | Tap scale, opacity press, toggle switches |
| `AppMotion.normal` | `220ms` | `AppMotion.curve` (`easeOut`) / `curveEnter` (`easeOutCubic`) | Card reveals, tab/section switches, inline expansions |
| `AppMotion.slow` | `320ms` | `AppMotion.curveEnter` (`easeOutCubic`) | Full-screen modal entries, bottom sheets |
| `AppMotion.ambient` | `1200ms` | Linear / smooth repeat | `SkeletonLoader` shimmer, ambient states |
| Exit transitions | `fast`–`normal` | `AppMotion.curveExit` (`easeIn`) | Dismissals, closing overlays |

### Playful / Tactile Motion (`PlayfulTokens`)
Use for Duolingo-style 3D buttons, streak/goal celebrations, and playful pop-ins:
- `durationPress`: `90ms` (`curveSquish`: `easeInOutCubic`) — physical button lip depression (`3.0px` `translateY`).
- `durationBounce`: `220ms` (`curveBounce`: `easeOutBack`) — release recovery with subtle 6% overshoot.
- `durationPopIn`: `320ms` (`curveSmooth`: `easeOutCubic`) — new card/badge pop-ins.
- `durationPage`: `300ms` — fluid page transitions.
- `durationCelebration`: `800ms` (`curveElastic`: `elasticOut`) — goal completion / confetti moments.

---

## 3. Interaction Patterns

### Tappable Elements (`AppTapScale`)
- Wrap custom tappable cards/buttons in `AppTapScale` (`lib/shared/widgets/app_tap_scale.dart`).
- Standard press feedback: `scale: 0.97`, `opacity: 0.85`, duration `AppMotion.fast` (`120ms`), curve `AppMotion.curveSpring`.
- Enable `haptic: true` (`HapticFeedback.lightImpact()`) for primary financial actions (saving a transaction, confirming a transfer, toggling key switches).

### Route & Page Transitions
- Use `SlideFadeTransition` (`lib/utils/page_transitions.dart` — `250ms`, `Curves.easeOutCubic`, `Offset(0.05, 0)` slide + fade) or `AppPageRoute` (`lib/shared/widgets/app_page_route.dart`) instead of raw default `MaterialPageRoute` where custom transitions are desired.
- Keep horizontal slide offsets subtle (`<= 0.05`) so navigation feels brisk, never disorienting.

### Charts & Data (`fl_chart`)
- Animate chart data transitions with `AppMotion.normal` (`220ms`) to `AppMotion.slow` (`320ms`) using `Curves.easeOutCubic`.
- Never re-run full entrance animations on every minor filter chip tap if an implicit update works smoothly.

### Lists & Swipes (`flutter_slidable`)
- **No infinite staggered lists:** If staggering transaction or account cards on initial load, cap the stagger to the **first 6–8 visible items** (`index.clamp(0, 6)`). Items scrolled into view later must appear immediately without entrance delay.
- Keep `flutter_slidable` swipe actions crisp and immediately responsive to drag velocity.

---

## 4. What Must Never Animate
1. **Scroll-blocking delays:** Never gate user input or scrolling behind an animation completing.
2. **Continuous decorative loops:** Avoid pulsing/bouncing badges or idle loops on financial dashboards (exception: active loading indicators / `SkeletonLoader` shimmer / active `DynamicIslandHUD` states).
3. **Expensive layout thrashing:** Prefer `Transform`, `Opacity`, `AnimatedScale`, and `SlideTransition` over animating `width`/`height` or `BoxShadow` blur radii on large lists.
4. **Reduced motion violations:** Never pass a hardcoded `Duration` directly to `Animated*` or `AnimationController` without checking `context.motionDuration(...)` or `context.reduceMotion`.
