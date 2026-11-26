import 'dart:ui';
import 'package:flutter/material.dart';
import '../../shared/widgets/playful/spendx_playful_button.dart';
import '../../theme/app_spacing.dart';
import '../../theme/playful_tokens.dart';

/// Production-ready sticky bottom action bar for form-filling screens in SpendX.
///
/// Features:
/// 1. Single-primary-action or dual-action layouts.
/// 2. Solid theme-aware surface by default, with optional frosted glass backdrop blur.
/// 3. Standard 48px minimum touch targets, consistent horizontal and vertical padding.
/// 4. Built-in top hairline divider for crisp visual separation.
/// 5. Loading, disabled, and duplicate-submission prevention states.
/// 6. Scaffold-friendly safe-area and keyboard handling without double-counting insets.
/// 7. Exposes static helper [overlayContentInset] only for overlay-based layouts (e.g. Stack),
///    without imposing unnecessary spacing when hosted inside [Scaffold.bottomNavigationBar].
class SpendXStickyBottomBar extends StatefulWidget {
  /// Custom child widget to display inside the bottom bar container.
  /// If provided, this overrides [primaryLabel] and [secondaryLabel].
  final Widget? child;

  /// Custom primary button widget. If null, a [SpendXPlayfulButton] is built.
  final Widget? primaryButton;

  /// Primary button text label.
  final String? primaryLabel;

  /// Primary button callback. If null, the button is rendered in a disabled state.
  final VoidCallback? onPrimaryPressed;

  /// Optional icon to show alongside the primary action label.
  final IconData? primaryIcon;

  /// Visual variant of the primary playful button.
  final PlayfulButtonVariant primaryVariant;

  /// Custom surface color for the primary button.
  final Color? primaryColor;

  /// Whether the primary button is currently in a loading state.
  final bool isPrimaryLoading;

  /// Whether the primary button is disabled.
  final bool isPrimaryDisabled;

  /// Accessibility semantic label for the primary button.
  final String? primarySemanticLabel;

  /// Custom secondary button widget.
  final Widget? secondaryButton;

  /// Secondary button text label (e.g. 'Cancel', 'Back').
  final String? secondaryLabel;

  /// Secondary button callback.
  final VoidCallback? onSecondaryPressed;

  /// Optional icon to show alongside the secondary action label.
  final IconData? secondaryIcon;

  /// Visual variant of the secondary playful button.
  final PlayfulButtonVariant secondaryVariant;

  /// Custom surface color for the secondary button.
  final Color? secondaryColor;

  /// Whether the secondary button is currently in a loading state.
  final bool isSecondaryLoading;

  /// Whether the secondary button is disabled.
  final bool isSecondaryDisabled;

  /// Accessibility semantic label for the secondary button.
  final String? secondarySemanticLabel;

  /// Flex factor for the secondary button in dual-action layout (default: 1).
  final int secondaryFlex;

  /// Flex factor for the primary button in dual-action layout (default: 2).
  final int primaryFlex;

  /// Spacing between secondary and primary buttons (default: 12.0).
  final double buttonSpacing;

  /// Minimum height of buttons (default: 48.0 for accessibility compliance).
  final double buttonHeight;

  /// Internal padding for the action bar (default: horizontal 16, vertical 12).
  final EdgeInsetsGeometry padding;

  /// Custom background color. If null, defaults to [ColorScheme.surface].
  final Color? backgroundColor;

  /// Custom top/bottom border. If null, defaults to a subtle top hairline border.
  final Border? border;

  /// Whether to enable backdrop blur (frosted glass effect).
  /// Defaults to `false` for optimal performance and crisp solid rendering.
  final bool enableBlur;

  /// Blur intensity when [enableBlur] is true (default: 12.0).
  final double blurSigma;

  /// Whether to wrap content in a [SafeArea] for bottom gesture bar / home indicator.
  final bool applySafeArea;

  /// Whether to automatically offset above the software keyboard when it appears.
  /// Defaults to `true`, ensuring the action bar remains visible and accessible while typing.
  final bool handleKeyboardInset;

  /// Whether the bar is rendered in an overlay layout (e.g. [Stack]) rather than
  /// inside [Scaffold.bottomNavigationBar].
  final bool isOverlay;

  /// Minimum time window to debounce consecutive taps and prevent duplicate submissions.
  final Duration duplicateSubmitDebounce;

  /// Suggested content bottom inset when [SpendXStickyBottomBar] is used in an
  /// overlay-based layout (e.g. inside a [Stack] over a [SingleChildScrollView] or [ListView]).
  ///
  /// IMPORTANT: When using [SpendXStickyBottomBar] inside [Scaffold.bottomNavigationBar],
  /// Flutter's [Scaffold] automatically reserves the bottom navigation bar height
  /// for its body, so DO NOT add this padding in standard Scaffold-hosted forms.
  static const double overlayContentInset = 76.0;

  /// Computes the dynamic bottom content inset for overlay-based layouts, accounting
  /// for device safe area insets and optional extra padding.
  static double getOverlayContentInset(
    BuildContext context, {
    double extraPadding = 0,
  }) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    return overlayContentInset + bottomPadding + extraPadding;
  }

  const SpendXStickyBottomBar({
    super.key,
    this.child,
    this.primaryButton,
    this.primaryLabel,
    this.onPrimaryPressed,
    this.primaryIcon,
    this.primaryVariant = PlayfulButtonVariant.primary,
    this.primaryColor,
    this.isPrimaryLoading = false,
    this.isPrimaryDisabled = false,
    this.primarySemanticLabel,
    this.secondaryButton,
    this.secondaryLabel,
    this.onSecondaryPressed,
    this.secondaryIcon,
    this.secondaryVariant = PlayfulButtonVariant.tonal,
    this.secondaryColor,
    this.isSecondaryLoading = false,
    this.isSecondaryDisabled = false,
    this.secondarySemanticLabel,
    this.secondaryFlex = 1,
    this.primaryFlex = 2,
    this.buttonSpacing = PlayfulTokens.space12,
    this.buttonHeight = 48.0,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.standard,
      vertical: PlayfulTokens.space12,
    ),
    this.backgroundColor,
    this.border,
    this.enableBlur = false,
    this.blurSigma = 12.0,
    this.applySafeArea = true,
    this.handleKeyboardInset = true,
    this.isOverlay = false,
    this.duplicateSubmitDebounce = const Duration(milliseconds: 500),
  });

  /// Creates a single-action sticky bottom bar (e.g. "Save Activity", "Confirm Payment").
  const SpendXStickyBottomBar.singleAction({
    super.key,
    required this.primaryLabel,
    required this.onPrimaryPressed,
    this.primaryIcon,
    this.primaryVariant = PlayfulButtonVariant.primary,
    this.primaryColor,
    this.isPrimaryLoading = false,
    this.isPrimaryDisabled = false,
    this.primarySemanticLabel,
    this.buttonHeight = 48.0,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.standard,
      vertical: PlayfulTokens.space12,
    ),
    this.backgroundColor,
    this.border,
    this.enableBlur = false,
    this.blurSigma = 12.0,
    this.applySafeArea = true,
    this.handleKeyboardInset = true,
    this.isOverlay = false,
    this.duplicateSubmitDebounce = const Duration(milliseconds: 500),
  })  : child = null,
        primaryButton = null,
        secondaryButton = null,
        secondaryLabel = null,
        onSecondaryPressed = null,
        secondaryIcon = null,
        secondaryVariant = PlayfulButtonVariant.tonal,
        secondaryColor = null,
        isSecondaryLoading = false,
        isSecondaryDisabled = false,
        secondarySemanticLabel = null,
        secondaryFlex = 1,
        primaryFlex = 1,
        buttonSpacing = PlayfulTokens.space12;

  /// Creates a dual-action sticky bottom bar (e.g. "Cancel" + "Save Account").
  const SpendXStickyBottomBar.dualAction({
    super.key,
    required this.primaryLabel,
    required this.onPrimaryPressed,
    this.primaryIcon,
    this.primaryVariant = PlayfulButtonVariant.primary,
    this.primaryColor,
    this.isPrimaryLoading = false,
    this.isPrimaryDisabled = false,
    this.primarySemanticLabel,
    required this.secondaryLabel,
    required this.onSecondaryPressed,
    this.secondaryIcon,
    this.secondaryVariant = PlayfulButtonVariant.tonal,
    this.secondaryColor,
    this.isSecondaryLoading = false,
    this.isSecondaryDisabled = false,
    this.secondarySemanticLabel,
    this.secondaryFlex = 1,
    this.primaryFlex = 2,
    this.buttonSpacing = PlayfulTokens.space12,
    this.buttonHeight = 48.0,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.standard,
      vertical: PlayfulTokens.space12,
    ),
    this.backgroundColor,
    this.border,
    this.enableBlur = false,
    this.blurSigma = 12.0,
    this.applySafeArea = true,
    this.handleKeyboardInset = true,
    this.isOverlay = false,
    this.duplicateSubmitDebounce = const Duration(milliseconds: 500),
  })  : child = null,
        primaryButton = null,
        secondaryButton = null;

  /// Creates a custom sticky bottom bar with arbitrary child content.
  const SpendXStickyBottomBar.custom({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.standard,
      vertical: PlayfulTokens.space12,
    ),
    this.backgroundColor,
    this.border,
    this.enableBlur = false,
    this.blurSigma = 12.0,
    this.applySafeArea = true,
    this.handleKeyboardInset = true,
    this.isOverlay = false,
    this.duplicateSubmitDebounce = const Duration(milliseconds: 500),
  })  : primaryButton = null,
        primaryLabel = null,
        onPrimaryPressed = null,
        primaryIcon = null,
        primaryVariant = PlayfulButtonVariant.primary,
        primaryColor = null,
        isPrimaryLoading = false,
        isPrimaryDisabled = false,
        primarySemanticLabel = null,
        secondaryButton = null,
        secondaryLabel = null,
        onSecondaryPressed = null,
        secondaryIcon = null,
        secondaryVariant = PlayfulButtonVariant.tonal,
        secondaryColor = null,
        isSecondaryLoading = false,
        isSecondaryDisabled = false,
        secondarySemanticLabel = null,
        secondaryFlex = 1,
        primaryFlex = 1,
        buttonSpacing = PlayfulTokens.space12,
        buttonHeight = 48.0;

  @override
  State<SpendXStickyBottomBar> createState() => _SpendXStickyBottomBarState();
}

class _SpendXStickyBottomBarState extends State<SpendXStickyBottomBar> {
  DateTime? _lastPrimaryTapTime;
  DateTime? _lastSecondaryTapTime;

  void _handlePrimaryTap() {
    if (widget.isPrimaryDisabled ||
        widget.isPrimaryLoading ||
        widget.onPrimaryPressed == null) {
      return;
    }
    final now = DateTime.now();
    if (_lastPrimaryTapTime != null &&
        now.difference(_lastPrimaryTapTime!) < widget.duplicateSubmitDebounce) {
      return;
    }
    _lastPrimaryTapTime = now;
    widget.onPrimaryPressed!();
  }

  void _handleSecondaryTap() {
    if (widget.isSecondaryDisabled ||
        widget.isSecondaryLoading ||
        widget.onSecondaryPressed == null) {
      return;
    }
    final now = DateTime.now();
    if (_lastSecondaryTapTime != null &&
        now.difference(_lastSecondaryTapTime!) < widget.duplicateSubmitDebounce) {
      return;
    }
    _lastSecondaryTapTime = now;
    widget.onSecondaryPressed!();
  }

  Widget _buildPrimaryButton() {
    if (widget.primaryButton != null) {
      return widget.primaryButton!;
    }
    final isInteractive = !widget.isPrimaryDisabled &&
        !widget.isPrimaryLoading &&
        widget.onPrimaryPressed != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Ensure child text cannot overflow SpendXPlayfulButton's internal Row
        // Container padding is 20 on each side (40 total) + optional icon (27).
        final iconSpace = widget.primaryIcon != null ? 27.0 : 0.0;
        final maxTextWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth - (PlayfulTokens.space20 * 2) - iconSpace)
                .clamp(0.0, double.infinity)
            : double.infinity;

        return SpendXPlayfulButton(
          key: const ValueKey('spendx_sticky_primary_button'),
          onPressed: isInteractive ? _handlePrimaryTap : null,
          icon: widget.primaryIcon,
          variant: widget.primaryVariant,
          customColor: widget.primaryColor,
          height: widget.buttonHeight,
          isLoading: widget.isPrimaryLoading,
          semanticLabel: widget.primarySemanticLabel ?? widget.primaryLabel,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTextWidth),
            child: Text(
              widget.primaryLabel ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSecondaryButton() {
    if (widget.secondaryButton != null) {
      return widget.secondaryButton!;
    }
    final isInteractive = !widget.isSecondaryDisabled &&
        !widget.isSecondaryLoading &&
        widget.onSecondaryPressed != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final iconSpace = widget.secondaryIcon != null ? 27.0 : 0.0;
        final maxTextWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth - (PlayfulTokens.space20 * 2) - iconSpace)
                .clamp(0.0, double.infinity)
            : double.infinity;

        return SpendXPlayfulButton(
          key: const ValueKey('spendx_sticky_secondary_button'),
          onPressed: isInteractive ? _handleSecondaryTap : null,
          icon: widget.secondaryIcon,
          variant: widget.secondaryVariant,
          customColor: widget.secondaryColor,
          height: widget.buttonHeight,
          isLoading: widget.isSecondaryLoading,
          semanticLabel: widget.secondarySemanticLabel ?? widget.secondaryLabel,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTextWidth),
            child: Text(
              widget.secondaryLabel ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final effectiveBg = widget.backgroundColor ??
        (widget.enableBlur
            ? cs.surface.withValues(alpha: 0.85)
            : cs.surface);

    final effectiveBorder = widget.border ??
        Border(
          top: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.25),
            width: 1.0,
          ),
        );

    final Widget content;
    if (widget.child != null) {
      content = widget.child!;
    } else if (widget.secondaryLabel != null || widget.secondaryButton != null) {
      content = Row(
        children: [
          Expanded(
            flex: widget.secondaryFlex,
            child: _buildSecondaryButton(),
          ),
          SizedBox(width: widget.buttonSpacing),
          Expanded(
            flex: widget.primaryFlex,
            child: _buildPrimaryButton(),
          ),
        ],
      );
    } else {
      content = SizedBox(
        width: double.infinity,
        child: _buildPrimaryButton(),
      );
    }

    Widget inner = Padding(
      padding: widget.padding,
      child: content,
    );

    // Keyboard insets handling:
    // When software keyboard is open (viewInsets > 0), the bar offsets upward.
    // To prevent double-counting, bottom safe area is excluded when keyboard is open.
    final double keyboardInset = (widget.handleKeyboardInset || widget.isOverlay)
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;

    if (widget.applySafeArea) {
      inner = SafeArea(
        top: false,
        left: true,
        right: true,
        bottom: keyboardInset == 0,
        child: inner,
      );
    }

    if (keyboardInset > 0) {
      inner = Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: inner,
      );
    }

    Widget container = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: effectiveBg,
        border: effectiveBorder,
      ),
      child: inner,
    );

    if (widget.enableBlur) {
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: widget.blurSigma,
            sigmaY: widget.blurSigma,
          ),
          child: container,
        ),
      );
    }

    return container;
  }
}
