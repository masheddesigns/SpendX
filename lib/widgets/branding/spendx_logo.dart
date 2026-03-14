import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class SpendXLogo extends StatelessWidget {
  final double size;
  final Color? color;

  const SpendXLogo({
    super.key,
    this.size = 56,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/logo.svg',
      width: size,
      height: size,
      colorFilter: color != null 
          ? ColorFilter.mode(color!, BlendMode.srcIn)
          : ColorFilter.mode(Theme.of(context).colorScheme.primary, BlendMode.srcIn),
      placeholderBuilder: (BuildContext context) => Icon(
        Icons.account_balance_wallet_rounded,
        size: size,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
