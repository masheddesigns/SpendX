import 'package:uuid/uuid.dart';

class Tag {
  final String id;
  final String userId;
  final String name;
  final String color;

  Tag({
    String? id,
    required this.userId,
    required this.name,
    required this.color,
  }) : id = id ?? const Uuid().v4();

  factory Tag.fromJson(Map<String, dynamic> json) {
    return Tag(
      id: json['id'],
      userId: json['user_id'] ?? '',
      name: json['name'],
      color: json['color'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'color': color,
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'color': color,
    };
  }

  factory Tag.fromMap(Map<String, dynamic> map) {
    return Tag(
      id: map['id'],
      userId: map['user_id'] ?? '',
      name: map['name'],
      color: map['color'],
    );
  }
}
