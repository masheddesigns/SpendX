import 'package:uuid/uuid.dart';

class Category {
  final String id;
  final String userId;
  final String name;
  final String icon;
  final String color;
  final String type; // 'income' or 'expense'

  Category({
    String? id,
    required this.userId,
    required this.name,
    required this.icon,
    required this.color,
    required this.type,
  }) : id = id ?? const Uuid().v4();

  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: json['id'],
      userId: json['user_id'] ?? '',
      name: json['name'],
      icon: json['icon'],
      color: json['color'],
      type: json['type'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'icon': icon,
      'color': color,
      'type': type,
    };
  }

  // Database map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'icon': icon,
      'color': color,
      'type': type,
    };
  }

  factory Category.fromMap(Map<String, dynamic> map) {
    return Category(
      id: map['id'],
      userId: map['user_id'] ?? '',
      name: map['name'],
      icon: map['icon'],
      color: map['color'],
      type: map['type'],
    );
  }
}
