import 'package:flutter/material.dart';

enum InsightType { warning, info, tip, success }

class Insight {
  final String title;
  final String description;
  final InsightType type;
  final IconData icon;

  const Insight({
    required this.title,
    required this.description,
    required this.type,
    required this.icon,
  });
}
