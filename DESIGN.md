# SpendX Design System (`DESIGN.md`)

> Single source of truth for SpendX's visual language, tokens, typography, and component rules.
> All UI changes must reference the tokens in [`lib/theme/app_theme.dart`](lib/theme/app_theme.dart), [`lib/theme/app_spacing.dart`](lib/theme/app_spacing.dart), and [`lib/theme/playful_tokens.dart`](lib/theme/playful_tokens.dart) rather than hardcoding raw colors, font styles, or arbitrary spacing.

---

## 1. Aesthetic Direction
- **Identity:** Modern, energetic, reassuring personal finance (inspired by Revolut, Monzo, Finch, and Duolingo).
- **Theme Variants:** `spendx_modern`, `liquid_glass_dark`, `premium_dark` (managed by `AppTheme`).
- **Core Principles:**
  1. **Clarity over decoration:** Financial numbers always use tabular figures and high contrast.
  2. **Tactile & calm:** Warm light canvas (`#FAF7F2`) and deep navy-slate dark canvas (`#0D0F17`)—never pure `#FFFFFF` or `#000000` backgrounds.
  3. **Locked financial semantics:** Income, expense, transfer, and warning colors are invariant across themes so users build instant color memory.

---

## 2. Color Tokens

### Brand & Playful Accents
| Token | Hex | Source | Usage |
| :--- | :--- | :--- | :--- |
| `AppTheme.primaryBlue` / `PlayfulTokens.electricViolet` | `#6558E8` | `app_theme.dart` | Primary CTAs, active tabs, brand highlights |
| `AppTheme.primaryBlueMuted` / `PlayfulTokens.electricVioletLip` | `#4C3FC7` | `app_theme.dart` | Pressed states, 3D button lips, muted accents |
| `PlayfulTokens.electricVioletLight` | `#8175FF` | `playful_tokens.dart` | Hover/highlight accents |
| `PlayfulTokens.neoMint` / `Lip` | `#2EC4B6` / `#20968B` | `playful_tokens.dart` | Playful positive/goal accents |
| `PlayfulTokens.sunsetCoral` / `Lip` | `#FF5A5F` / `#D63E43` | `playful_tokens.dart` | Playful alert/streak accents |
| `PlayfulTokens.mangoGold` / `Lip` | `#FFB703` / `#D49700` | `playful_tokens.dart` | Rewards, badges, highlights |
| `PlayfulTokens.cyberCyan` / `Lip` | `#00BBF9` / `#0098CC` | `playful_tokens.dart` | Info/playful category accents |

### Locked Financial Semantics
| Semantic Role | Hex | Context Helper |
| :--- | :--- | :--- |
| **Income / Success** | `#35B779` | `context.incomeColor` (`AppColors.success`) |
| **Expense / Danger / Shortfall** | `#E76D76` | `context.expenseColor` (`AppColors.danger`) |
| **Transfer** | `#55B8C5` | `context.transferColor` (`AppColors.transfer`) |
| **Warning** | `#F3AD4E` | `context.warningColor` (`AppColors.warning`) |

### Surfaces & Text (Dark vs. Light)
Use `SpendXThemeContext` (`context.canvasColor`, `context.surfaceColor`, `context.borderColor`, `context.textPrimary`, `context.textSecondary`, `context.textMuted`) instead of `Theme.of(context).brightness` checks.

| Role | Dark Mode | Light Mode |
| :--- | :--- | :--- |
| **Canvas (`bg`)** | `#0D0F17` | `#FAF7F2` |
| **Surface (`card`)** | `#171A26` | `#FFFFFF` |
| **Elevated** | `#1F2333` | `#FFFFFF` |
| **Border** | `#262B3D` | `#EBE6DC` |
| **Text Primary** | `#F5F7FC` | `#202432` |
| **Text Secondary** | `#9AA1B5` | `#6B7280` |
| **Text Muted** | `#656C82` | `#9AA1B5` |

### Special Surfaces
- **Credit Card Instruments:** Always dark in both themes (`#1E2230` → `#12151E` in dark; `#232A3B` → `#141824` in light).
- **Cinematic Full-Screen Flows (`CinematicTheme`):** `#0A0C10` bg, `#12151D` surface, `#191D28` elevated, `#1E2330` border.
- **Liquid Glass:** `AppTheme.glassBlur` (`16.0`), `glassNavBlur` (`20.0`), `glassControlBlur` (`12.0`).

---

## 3. Typography (`AppTextStyles`)
- **Numeric Rule:** Every balance, transaction amount, KPI, and chart figure **must** use `FontFeature.tabularFigures()` (built into `displayBalance`, `largeAmount`, `amountMedium`, `numericData`).
- **Scale:**
  - `displayBalance`: `34px`, `w700`, `-1.0` tracking (hero balances)
  - `largeAmount`: `26px`, `w700`, `-0.5` tracking (summary totals)
  - `titleXLarge`: `24px`, `w700`, `-0.4` tracking (screen titles)
  - `heading`: `20px`, `w600`, `-0.3` tracking
  - `amountMedium`: `18px`, `w700`, `-0.3` tracking (card amounts)
  - `subheading`: `16px`, `w600`, `-0.2` tracking
  - `numericData`: `15px`, `w600`, `-0.2` tracking (list row amounts)
  - `body` / `button`: `14px`, `w400` / `w600`
  - `sectionHeading` / `bodyMedium`: `13px`, `w600` / `w400`
  - `chip`: `12px`, `w600`
  - `caption` / `navigation`: `11px`, `w500` / `w600`
  - `badge`: `10px`, `w700`, `+0.2` tracking

---

## 4. Spacing, Geometry & Elevation

### Spacing (`AppSpacing`)
Strict 4pt / 8pt grid:
- `micro` (`8.0`), `tight` (`12.0`), `standard` (`16.0`), `section` (`24.0`), `major` (`32.0`).
- **Screen padding:** `AppSpacing.screenPadding` (`16.0` all around) or `listHorizontalPadding` (`12.0` for card lists).
- **Card internals:** `AppSpacing.cardPadding` (`horizontal: 14, vertical: 10`), `cardGap` (`6.0`), `sectionHeaderGap` (`8.0`), `sectionGap` (`16.0`).

### Corner Radii (`AppRadius` & `PlayfulTokens`)
Use `AppRadius` for standard Material/cards and `PlayfulTokens` for playful/tactile surfaces—never invent ad-hoc radii:
- **Chips / badges:** `AppRadius.s` (`8.0`) / `PlayfulTokens.radiusXs` (`8.0`)
- **Inputs / buttons:** `AppRadius.m` (`12.0`) / `PlayfulTokens.radiusSm` (`12.0`)
- **Standard cards / sheets:** `AppRadius.card` (`16.0`) / `PlayfulTokens.radiusMd` (`18.0`)
- **Hero containers / nav:** `AppRadius.xxl` (`24.0`) / `PlayfulTokens.radiusLg` (`26.0`)
- **Pills:** `AppRadius.full` (`999.0`) / `PlayfulTokens.radiusPill` (`999.0`)

### Shadows (`AppShadows`)
- Light mode cards: `AppShadows.card` (soft `#18274B` tint).
- Dark mode cards: `AppShadows.darkCard` (`#40000000`).
- Floating elements / nav: `AppShadows.floating`.
- Brand glow: `AppShadows.glow` (`#256558E8`).

---

## 5. Component & Layout Guardrails
1. **Reuse shared widgets** from `lib/shared/widgets/` (`AppCard`, `PrimaryButton`, `AppAmountField`, `AppTapScale`, `SpendxAppBar`, `SpendxGlass`, `SkeletonLoader`, `EmptyStateWidget`, `ErrorStateWidget`) before creating new primitives.
2. **Minimum touch target:** `48x48dp` on all interactive elements (enforced by `AppTapScale`).
3. **Avoid nested cards:** Never place a bordered/shadowed card inside another bordered/shadowed card; use spacing or subtle `onSurfaceOverlay` dividers instead.
4. **No raw `Colors.*`:** Never use `Colors.red`, `Colors.green`, `Colors.grey`, or pure `Colors.black` / `Colors.white` for UI surfaces or semantic states—use `AppTheme`, `AppColors`, or `SpendXThemeContext`.
