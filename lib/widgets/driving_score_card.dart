import 'package:flutter/material.dart';
import 'dart:math';
import '../../services/driving_score_service.dart';

/// Premium Driving Score card — circular ring gauge centrepiece.
class DrivingScoreCard extends StatefulWidget {
  final DrivingScore score;
  const DrivingScoreCard({super.key, required this.score});

  @override
  State<DrivingScoreCard> createState() => _DrivingScoreCardState();
}

class _DrivingScoreCardState extends State<DrivingScoreCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color _gradeColor(double score) {
    if (score >= 80) return const Color(0xFF22C55E);
    if (score >= 60) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mainColor = _gradeColor(widget.score.overall);

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35), width: 1),
        boxShadow: [
          BoxShadow(
            color: mainColor.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: mainColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.emoji_events_rounded,
                      color: mainColor, size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Driving Score',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: cs.onSurface,
                        )),
                    Text('Based on your driving habits',
                        style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant)),
                  ],
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: mainColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(widget.score.grade,
                      style: TextStyle(
                          color: mainColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 22,
                          letterSpacing: 1)),
                ),
              ],
            ),
          ),

          // ── Circular gauge ──
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, _) {
                final val = widget.score.overall / 100 * _anim.value;
                return Row(
                  children: [
                    // Ring
                    SizedBox(
                      width: 140,
                      height: 140,
                      child: CustomPaint(
                        painter: _RingGaugePainter(
                          value: val,
                          color: mainColor,
                          trackColor: cs.outlineVariant.withValues(alpha: 0.18),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                (widget.score.overall * _anim.value)
                                    .toStringAsFixed(0),
                                style: TextStyle(
                                  fontSize: 40,
                                  fontWeight: FontWeight.bold,
                                  color: mainColor,
                                  height: 1,
                                ),
                              ),
                              Text('/ 100',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    // Metrics list beside the ring
                    Expanded(
                      child: Column(
                        children: widget.score.metrics
                            .map((m) => _miniMetricRow(m, cs))
                            .toList(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // ── Divider + detailed bars ──
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.25)),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              children: widget.score.metrics
                  .map((m) => _metricBar(m, cs))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniMetricRow(ScoreMetric m, ColorScheme cs) {
    final color = _gradeColor(m.score);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(m.icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(m.label,
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Text(m.score.toStringAsFixed(0),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color)),
        ],
      ),
    );
  }

  Widget _metricBar(ScoreMetric m, ColorScheme cs) {
    final color = _gradeColor(m.score);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(m.icon, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(m.label,
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface))),
              Text('${m.score.toInt()}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
          const SizedBox(height: 5),
          AnimatedBuilder(
            animation: _anim,
            builder: (_, _) => ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (m.score / 100) * _anim.value,
                backgroundColor: cs.outlineVariant.withValues(alpha: 0.18),
                valueColor: AlwaysStoppedAnimation(color),
                minHeight: 7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Full circular ring painter ──────────────────────────────────────
class _RingGaugePainter extends CustomPainter {
  final double value; // 0–1
  final Color color;
  final Color trackColor;

  const _RingGaugePainter({
    required this.value,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 10;
    const startAngle = -pi / 2; // top
    const sweepFull = pi * 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = trackColor;

    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawCircle(center, radius, track);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepFull * value,
      false,
      fill,
    );
  }

  @override
  bool shouldRepaint(_RingGaugePainter old) =>
      old.value != value || old.color != color;
}
