import 'package:flutter/material.dart';
import '../../../services/sound_effects_service.dart';
import '../../../theme/playful_tokens.dart';

enum PlayfulButtonVariant { primary, income, expense, tonal, outline }

/// 3D Tactile Playful Button.
///
/// Features:
/// - Tactile physical press-down: depresses along the Y axis with spring physics.
/// - 3D shadow lip that flattens realistically when pushed.
/// - Integrated pop sound effect and light haptic feedback.
/// - Fluid scale deformation (0.97x) with bounce recovery.
class SpendXPlayfulButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final PlayfulButtonVariant variant;
  final double? width;
  final double height;
  final Color? customColor;
  final Color? customLipColor;
  final bool isLoading;
  final String? semanticLabel;

  const SpendXPlayfulButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = PlayfulButtonVariant.primary,
    this.width,
    this.height = 48.0,
    this.customColor,
    this.customLipColor,
    this.isLoading = false,
    this.semanticLabel,
  });

  factory SpendXPlayfulButton.icon({
    Key? key,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    PlayfulButtonVariant variant = PlayfulButtonVariant.primary,
    double? width,
    double height = 48.0,
    Color? customColor,
    Color? customLipColor,
    bool isLoading = false,
    String? semanticLabel,
  }) {
    return SpendXPlayfulButton(
      key: key,
      onPressed: onPressed,
      icon: icon,
      variant: variant,
      width: width,
      height: height,
      customColor: customColor,
      customLipColor: customLipColor,
      isLoading: isLoading,
      semanticLabel: semanticLabel ?? label,
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 15,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  @override
  State<SpendXPlayfulButton> createState() => _SpendXPlayfulButtonState();
}

class _SpendXPlayfulButtonState extends State<SpendXPlayfulButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pressAnim;
  bool _isDown = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: PlayfulTokens.durationPress,
      reverseDuration: PlayfulTokens.durationBounce,
    );
    _pressAnim = CurvedAnimation(
      parent: _ctrl,
      curve: PlayfulTokens.curveSquish,
      reverseCurve: PlayfulTokens.curveBounce,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    if (widget.onPressed == null || widget.isLoading) return;
    _isDown = true;
    _ctrl.forward();
    SoundEffectsService.instance.pop();
  }

  void _handleTapUp(TapUpDetails _) {
    if (!_isDown) return;
    _isDown = false;
    _ctrl.reverse();
    widget.onPressed?.call();
  }

  void _handleTapCancel() {
    if (!_isDown) return;
    _isDown = false;
    _ctrl.reverse();
  }

  ({Color surface, Color lip, Color text}) _resolveColors(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (widget.customColor != null) {
      return (
        surface: widget.customColor!,
        lip: widget.customLipColor ?? widget.customColor!.withValues(alpha: 0.7),
        text: Colors.white,
      );
    }

    switch (widget.variant) {
      case PlayfulButtonVariant.primary:
        return (
          surface: PlayfulTokens.electricViolet,
          lip: PlayfulTokens.electricVioletLip,
          text: Colors.white,
        );
      case PlayfulButtonVariant.income:
        return (
          surface: PlayfulTokens.neoMint,
          lip: PlayfulTokens.neoMintLip,
          text: Colors.white,
        );
      case PlayfulButtonVariant.expense:
        return (
          surface: PlayfulTokens.sunsetCoral,
          lip: PlayfulTokens.sunsetCoralLip,
          text: Colors.white,
        );
      case PlayfulButtonVariant.tonal:
        return (
          surface: isDark
              ? cs.surfaceContainerHighest
              : cs.surfaceContainerHigh,
          lip: isDark
              ? cs.outline.withValues(alpha: 0.3)
              : cs.outlineVariant,
          text: cs.onSurface,
        );
      case PlayfulButtonVariant.outline:
        return (
          surface: Colors.transparent,
          lip: Colors.transparent,
          text: cs.primary,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _resolveColors(context);
    final isOutline = widget.variant == PlayfulButtonVariant.outline;
    final isDisabled = widget.onPressed == null && !widget.isLoading;

    return Semantics(
      button: true,
      enabled: !isDisabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _pressAnim,
          builder: (context, _) {
            final double depression = _pressAnim.value * PlayfulTokens.buttonDepression;
            final double scale = 1.0 - (_pressAnim.value * 0.03);

            return Transform.scale(
              scale: scale,
              child: SizedBox(
                width: widget.width,
                height: widget.height + PlayfulTokens.buttonLipHeight,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    // Bottom 3D Lip / Bevel
                    if (!isOutline && !isDisabled)
                      Positioned(
                        top: PlayfulTokens.buttonLipHeight,
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: colors.lip,
                            borderRadius: BorderRadius.circular(PlayfulTokens.radiusPill),
                            boxShadow: PlayfulTokens.tactileShadow(
                              color: colors.lip,
                              elevation: (1.0 - _pressAnim.value) * 3.0,
                            ),
                          ),
                        ),
                      ),

                    // Top Interactive Surface
                    Positioned(
                      top: isOutline ? 0 : depression,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: widget.height,
                        padding: const EdgeInsets.symmetric(
                          horizontal: PlayfulTokens.space20,
                        ),
                        decoration: BoxDecoration(
                          color: isDisabled
                              ? colors.surface.withValues(alpha: 0.4)
                              : colors.surface,
                          borderRadius: BorderRadius.circular(PlayfulTokens.radiusPill),
                          border: isOutline
                              ? Border.all(
                                  color: Theme.of(context).colorScheme.outline,
                                  width: 1.5,
                                )
                              : null,
                        ),
                        child: Center(
                          child: widget.isLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      colors.text,
                                    ),
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (widget.icon != null) ...[
                                      Icon(
                                        widget.icon,
                                        size: 19,
                                        color: colors.text,
                                      ),
                                      const SizedBox(width: PlayfulTokens.space8),
                                    ],
                                    DefaultTextStyle(
                                      style: TextStyle(
                                        color: colors.text,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2,
                                      ),
                                      child: widget.child,
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
