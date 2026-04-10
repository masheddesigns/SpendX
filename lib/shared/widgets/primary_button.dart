import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';

enum PrimaryButtonTone { primary, secondary, outline }

class PrimaryButton extends StatefulWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    this.fullWidth,
    this.height = 48,
    this.fontSize,
    this.tone = PrimaryButtonTone.primary,
    this.hapticType = SpendXHapticType.tap,
    this.backgroundColor,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final bool expand;
  final bool? fullWidth;
  final double height;
  final double? fontSize;
  final PrimaryButtonTone tone;
  final SpendXHapticType hapticType;
  final Color? backgroundColor;
  final Color? color;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDisabled = widget.onPressed == null || widget.isLoading;

    final foregroundColor = widget.tone == PrimaryButtonTone.primary
        ? cs.onPrimary
        : (widget.tone == PrimaryButtonTone.outline
              ? cs.primary
              : cs.onSurface);

    final backgroundColor = widget.backgroundColor ??
        widget.color ??
        (widget.tone == PrimaryButtonTone.primary
        ? cs.primary
        : (widget.tone == PrimaryButtonTone.outline
              ? Colors.transparent
              : cs.surfaceContainer));

    final border = widget.tone == PrimaryButtonTone.outline
        ? BorderSide(color: cs.primary, width: 1.5)
        : BorderSide.none;

    final button = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: SizedBox(
          height: widget.height,
          child: ElevatedButton.icon(
            onPressed: isDisabled
                ? null
                : () {
                    HapticService.instance.trigger(widget.hapticType);
                    widget.onPressed!();
                  },
            icon: widget.isLoading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        foregroundColor,
                      ),
                    ),
                  )
                : (widget.icon != null
                      ? Icon(widget.icon, size: 20)
                      : const SizedBox.shrink()),
            label: Text(
              widget.label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontSize: widget.fontSize ?? 15,
                fontWeight: FontWeight.w600,
                color: foregroundColor,
              ) ?? TextStyle(
                fontSize: widget.fontSize ?? 15,
                fontWeight: FontWeight.w600,
                color: foregroundColor,
              ),
            ),
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: backgroundColor,
              foregroundColor: foregroundColor,
              disabledBackgroundColor: backgroundColor.withValues(alpha: 0.5),
              disabledForegroundColor: foregroundColor.withValues(alpha: 0.7),
              side: border,
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
              ),
            ),
          ),
        ),
      ),
    );

    final shouldExpand = widget.fullWidth ?? widget.expand;
    return shouldExpand
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  const SecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    return PrimaryButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      expand: expand,
      tone: PrimaryButtonTone.secondary,
    );
  }
}

class IconButtonClean extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final double size;

  const IconButtonClean({
    super.key,
    required this.icon,
    required this.onTap,
    this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        HapticService.instance.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(24.0),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Icon(icon, color: color ?? cs.primary, size: size),
      ),
    );
  }
}
