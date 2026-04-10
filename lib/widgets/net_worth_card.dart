import '../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/net_worth_screen.dart';
import '../services/settings_service.dart';
import 'animated_widgets.dart';
import 'package:intl/intl.dart';
import '../domain/net_worth/net_worth_service.dart';
import '../data/repositories/net_worth_repo.dart';
import '../models/net_worth_summary.dart';
import 'dart:math';

class NetWorthCard extends StatefulWidget {
  const NetWorthCard({super.key});

  @override
  State<NetWorthCard> createState() => _NetWorthCardState();
}

class _NetWorthCardState extends State<NetWorthCard> {
  double _netWorth = 0.0;
  bool _hide = true;
  bool _loading = true;
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _loadNetWorth();
  }

  @override
  void didUpdateWidget(covariant NetWorthCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadNetWorth();
  }

  Future<void> _loadNetWorth() async {
    final NetWorthSummary result = await NetWorthService.instance
        .calculateNetWorth();
    final history = await NetWorthRepo().getHistory();

    if (mounted) {
      setState(() {
        _netWorth = result.netWorth;
        _history = history;
        _loading = false;
      });
      // Update last updated timestamp
      SettingsService.instance.setNetWorthLastUpdated(DateTime.now());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final currencySymbol = settings.currencySymbol;
    if (_loading) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NetWorthScreen()),
        );
        _loadNetWorth();
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: cs.surfaceContainer,
          border: Border.all(
            color: cs.outline.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.pie_chart, color: cs.primary, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total Net Worth',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          alignment: Alignment.centerLeft,
                          fit: BoxFit.scaleDown,
                          child: _hide
                              ? Text(
                                  '****',
                                  style: TextStyle(
                                    color: _netWorth < 0
                                        ? cs.error
                                        : cs.onSurface,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.none,
                                  ),
                                )
                              : CountUpText(
                                  value: _netWorth,
                                  prefix: currencySymbol,
                                  decimalPlaces: 2,
                                  style: TextStyle(
                                    color: _netWorth < 0
                                        ? cs.error
                                        : cs.onSurface,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          HapticService.instance.tap();
                          setState(() => _hide = !_hide);
                        },
                        child: Icon(
                          _hide ? Icons.visibility_off : Icons.visibility,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  if (!_loading &&
                      SettingsService.instance.netWorthLastUpdated != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Last updated: ${DateFormat('dd MMM, hh:mm a').format(SettingsService.instance.netWorthLastUpdated!)}',
                        style: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                          fontSize: 10,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_history.length > 2)
              SizedBox(
                width: 60,
                height: 40,
                child: CustomPaint(
                  painter: _SparklinePainter(
                    data: _history
                        .map((h) => (h['netWorth'] as num).toDouble())
                        .toList(),
                    color: _netWorth < 0 ? cs.error : Colors.greenAccent,
                  ),
                ),
              ),
            if (_history.length <= 2)
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;

  _SparklinePainter({required this.data, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final minVal = data.reduce(min);
    final maxVal = data.reduce(max);
    final range = maxVal - minVal == 0 ? 1.0 : maxVal - minVal;

    final path = Path();
    final stepX = size.width / (data.length - 1);

    for (int i = 0; i < data.length; i++) {
      final x = i * stepX;
      // Invert Y axis relative to height. Add padding format
      final normalizedY = (data[i] - minVal) / range;
      final y =
          size.height - (normalizedY * size.height * 0.8) - (size.height * 0.1);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
