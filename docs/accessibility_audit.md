# SpendX — Accessibility Audit

**Date:** Tue Nov 24 2026  
**Method:** Static code analysis + UI/UX pro max skill guidelines (Flutter stack).  
**Scope:** All `lib/` Dart files (392+).

---

## 1. Summary

| Metric | Count | Status |
|---|---|---|
| Interactive widgets (IconButton, GestureDetector, InkWell, TextButton, ElevatedButton, OutlinedButton, ListTile, Switch, Checkbox) | ~338 | — |
| `Semantics` widgets | 44 | ❌ ~13% coverage |
| `Semantics` with `label:` | 39 | ❌ 89% of Semantics have labels (good ratio, low count) |
| `Tooltip` widgets | 8 | ❌ 2% |
| `tooltip:` property | 65 | 🟡 19% |
| `semanticLabel` usage | 29 | ❌ 9% |
| `minimumSize` (48px touch) | 11 | ❌ 3% |
| `SizedBox(minWidth: 48)` | 4 | ❌ |
| `excludeFromSemantics` | 0 | ❌ decorative images not excluded |
| `FocusNode` (managed) | 0 | ❌ No keyboard focus management |
| `Shortcuts`/`Actions`/`onKeyEvent` | 2 | ❌ No keyboard navigation |
| `MediaQuery.disableAnimations` | 1 (in AppTapScale) | 🟡 Only 1 widget checks |

**Accessibility Score: 4/10** (was 1/10 originally)

---

## 2. Critical Issues

### A. Missing Semantics on Interactive Widgets (~294 widgets)
- **63 `IconButton`** — most have `icon:` but no `tooltip:` or `Semantics`.
- **65 `GestureDetector`** — tap targets with no semantic label.
- **44 `InkWell`** — same.
- **72 `TextButton`** — text provides implicit label (OK), but no `Semantics` for screen readers.
- **72 `ListTile`** — title provides label (OK), but trailing/leading actions lack labels.
- **2 `Switch` + 2 `Checkbox`** — no `Semantics` wrapping.

**What to do:** Add `Semantics(label: '...', button: true)` to every interactive widget. Prioritize: app bar icons, FAB, list item actions, card tap targets.

### B. Touch Targets Below 48px
- 112 custom tap targets (`GestureDetector` 65 + `InkWell` 44 + others).
- Only 11 enforce `minimumSize: Size(48,48)` or `SizedBox(48,48)`.
- `IconButton` default is 48px (OK), but many custom `InkWell`/`GestureDetector` have no size constraint.
- `AppTapScale` enforces 48px min — good, but only used in some places.

**What to do:** Audit all `GestureDetector`/`InkWell`. Wrap in `ConstrainedBox(constraints: BoxConstraints(minWidth: 48, minHeight: 48))` or use `AppTapScale`.

### C. No Keyboard Navigation
- 0 managed `FocusNode`s (only constructor params).
- 0 `Shortcuts`/`Actions`/`onKeyEvent` handlers.
- Web/desktop users cannot Tab through the app.

**What to do:** Add `FocusNode` management to form fields and buttons. Add `Shortcuts` for common actions (Enter to submit, Escape to cancel).

### D. No Decorative Image Exclusion
- 0 `excludeFromSemantics` usages.
- 9 `Image`/`SvgPicture` widgets — illustrations and logos are announced by screen readers.

**What to do:** Add `excludeFromSemantics: true` to decorative images (logos, illustrations, empty state art).

### E. Reduced Motion Not Respected (mostly)
- Only `AppTapScale` checks `MediaQuery.disableAnimationsOf(context)`.
- Other animations (page transitions, card animations, splash) don't check.

**What to do:** Add `if (!MediaQuery.of(context).disableAnimations)` guard before all `AnimationController` starts.

---

## 3. Flutter Accessibility Guidelines (from ui-ux-pro-max)

| Guideline | Status | Evidence |
|---|---|---|
| Use `Semantics` widget | ❌ 13% coverage | 44/338 interactive widgets |
| Test with screen readers (TalkBack/VoiceOver) | ❌ Not done | No evidence of testing |
| Touch target 44pt (iOS) / 48dp (Android) | ❌ 3% enforcement | 11/338 |
| Color contrast 4.5:1 | 🟡 Unknown | Need manual check (hardcoded colors) |
| Focus appearance | ❌ None | 0 FocusNode management |
| Alt text for images | ❌ 0 | 9 images, 0 excludeFromSemantics |

---

## 4. Priority Fixes

### P0 (Blocks Play Store accessibility review)
1. Add `Semantics(label:)` to all 63 `IconButton`s
2. Add `tooltip:` to all icon-only buttons
3. Enforce 48px min on all 112 custom tap targets

### P1 (Important)
4. Add `excludeFromSemantics: true` to 9 decorative images
5. Add `FocusNode` management to forms
6. Add `MediaQuery.disableAnimations` to all animations

### P2 (Nice to have)
7. Add `Shortcuts`/`Actions` for keyboard navigation
8. Run TalkBack/VoiceOver manual testing
9. Add `Semantics` to remaining interactive widgets (ListTile trailing, cards)

---

## 5. Quick Wins (1 hour each)
- [ ] `grep -rn "IconButton(" lib` → add `tooltip:` to each
- [ ] `grep -rn "GestureDetector(\|InkWell(" lib` → wrap in `ConstrainedBox(minWidth: 48, minHeight: 48)`
- [ ] `grep -rn "SvgPicture.asset\|Image.asset" lib` → add `excludeFromSemantics: true` to decorative ones
- [ ] `grep -rn "AnimationController" lib` → add disableAnimations check

---

*Audit based on static code analysis of `lib/` at commit `d0e4f51`. No runtime/visual inspection performed.*