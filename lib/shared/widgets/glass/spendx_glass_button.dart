import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';
import 'spendx_glass_surface.dart';

enum SpendXGlassButtonVariant {
  primary,
  secondary,
  tonal,
  danger,
}

/// Interactive Apple-inspired Liquid Glass button.
///
/// Implements Section 9 of C15-A-R1:
/// - Floating glass pill control
/// - Translucent material with environmental interaction
/// - Pressed-state tactile deformation / scale (0.96)
/// - Directional specular rim highlight
/// - Clean legible iconography and typography
class SpendXGlassButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final SpendXGlassButtonVariant variant;
  final Color? accentColor;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final bool isLoading;

  const SpendXGlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = SpendXGlassButtonVariant.tonal,
    this.accentColor,
    this.padding,
    this.width,
    this.height = 44,
    this.borderRadius,
    this.isLoading = false,
  });

  factory SpendXGlassButton.icon({
    Key? key,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    SpendXGlassButtonVariant variant = SpendXGlassButtonVariant.tonal,
    Color? accentColor,
    EdgeInsetsGeometry? padding,
    double? width,
    double? height = 44,
    BorderRadius? borderRadius,
    bool isLoading = false,
  }) {
    return SpendXGlassButton(
      key: key,
      onPressed: onPressed,
      icon: icon,
      variant: variant,
      accentColor: accentColor,
      padding: padding,
      width: width,
      height: height,
      borderRadius: borderRadius,
      isLoading: isLoading,
      child: Text(label),
    );
  }

  @override
  State<SpendXGlassButton> createState() => _SpendXGlassButtonState();
}

class _SpendXGlassButtonState extends State<SpendXGlassButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    if (widget.onPressed != null && !widget.isLoading) {
      setState(() => _isPressed = true);
      _animController.forward();
    }
  }

  void _handleTapUp(TapUpDetails _) {
    setState(() => _isPressed = false);
    _animController.reverse();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
    _animController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = widget.borderRadius ?? BorderRadius.circular(AppRadius.full);

    // Resolve variant styling
    final Color tintColor;
    final Color textColor;
    final Border border;

    if (widget.accentColor != null) {
      final acc = widget.accentColor!;
      tintColor = isDark
          ? acc.withValues(alpha: _isPressed ? 0.30 : 0.16)
          : acc.withValues(alpha: _isPressed ? 0.22 : 0.12);
      textColor = isDark ? acc : acc;
      border = Border.all(
        color: acc.withValues(alpha: isDark ? 0.38 : 0.28),
        width: 0.6,
      );
    } else {
      switch (widget.variant) {
        case SpendXGlassButtonVariant.primary:
          tintColor = AppTheme.primaryBlue.withValues(alpha: _isPressed ? 0.85 : 0.75);
          textColor = Colors.white;
          border = Border.all(color: Colors.white.withValues(alpha: 0.35), width: 0.6);
          break;
        case SpendXGlassButtonVariant.secondary:
          tintColor = isDark
              ? Colors.white.withValues(alpha: _isPressed ? 0.16 : 0.09)
              : Colors.black.withValues(alpha: _isPressed ? 0.10 : 0.05);
          textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
          border = Border.all(
            color: isDark ? Colors.white.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.12),
            width: 0.5,
          );
          break;
        case SpendXGlassButtonVariant.tonal:
          tintColor = AppTheme.primaryBlue.withValues(alpha: _isPressed ? 0.28 : 0.16);
          textColor = isDark ? const Color(0xFF93C5FD) : AppTheme.primaryBlue;
          border = Border.all(
            color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.35 : 0.25),
            width: 0.5,
          );
          break;
        case SpendXGlassButtonVariant.danger:
          tintColor = AppTheme.semanticExpense.withValues(alpha: _isPressed ? 0.28 : 0.16);
          textColor = AppTheme.semanticExpense;
          border = Border.all(
            color: AppTheme.semanticExpense.withValues(alpha: isDark ? 0.40 : 0.30),
            width: 0.5,
          );
          break;
      }
    }

    final isEnabled = widget.onPressed != null && !widget.isLoading;

    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) => Transform.scale(
        scale: _scaleAnimation.value,
        child: child,
      ),
      child: GestureDetector(
        onTapDown: isEnabled ? _handleTapDown : null,
        onTapUp: isEnabled ? _handleTapUp : null,
        onTapCancel: isEnabled ? _handleTapCancel : null,
        onTap: isEnabled
            ? () {
                HapticFeedback.lightImpact();
                widget.onPressed!();
              }
            : null,
        child: SpendXGlassSurface(
          level: SpendXGlassLevel.interactive,
          width: widget.width,
          height: widget.height,
          borderRadius: radius,
          color: isEnabled ? tintColor : tintColor.withValues(alpha: 0.3),
          border: border,
          padding: widget.padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Center(
            child: widget.isLoading
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(textColor),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, size: 16, color: textColor),
                        const SizedBox(width: 6),
                      ],
                      DefaultTextStyle(
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                          letterSpacing: -0.1,
                        ),
                        child: widget.child,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
