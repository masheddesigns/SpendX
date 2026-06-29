import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/models/tag.dart';

void main() {
  group('Tag Model Tests', () {
    test('Tag serialization and deserialization should match', () {
      final tag = Tag(
        id: 'test-id-123',
        userId: 'user-id-456',
        name: 'Groceries',
        color: '#FF5733',
      );

      final map = tag.toMap();
      expect(map['id'], 'test-id-123');
      expect(map['name'], 'Groceries');
      expect(map['color'], '#FF5733');

      final deserialized = Tag.fromMap(map);
      expect(deserialized.id, 'test-id-123');
      expect(deserialized.name, 'Groceries');
      expect(deserialized.color, '#FF5733');
    });

    test('Tag copyWith should copy correct values', () {
      final tag = Tag(
        userId: 'user-id-1',
        name: 'Bills',
        color: '#00FF00',
      );

      final updated = tag.copyWith(name: 'Rent');
      expect(updated.id, tag.id);
      expect(updated.userId, 'user-id-1');
      expect(updated.name, 'Rent');
      expect(updated.color, '#00FF00');
    });
  });
}
