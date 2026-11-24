import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Accessibility: Every Semantics(button: true) must declare a label or hint', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib directory must exist');

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    final violations = <String>[];

    for (final file in dartFiles) {
      final content = file.readAsStringSync();
      var startIndex = 0;

      while (true) {
        final semanticsIndex = content.indexOf('Semantics(', startIndex);
        if (semanticsIndex == -1) break;

        // Find closing parenthesis with nesting support
        var depth = 0;
        var endIndex = -1;
        for (var i = semanticsIndex + 'Semantics'.length; i < content.length; i++) {
          if (content[i] == '(') {
            depth++;
          } else if (content[i] == ')') {
            depth--;
            if (depth == 0) {
              endIndex = i;
              break;
            }
          }
        }

        if (endIndex != -1) {
          final snippet = content.substring(semanticsIndex, endIndex + 1);
          if (snippet.contains('button: true')) {
            final hasLabel = snippet.contains('label:') || snippet.contains('hint:');
            if (!hasLabel) {
              violations.add('${file.path}: button without label/hint in:\n$snippet\n');
            }
          }
          startIndex = endIndex + 1;
        } else {
          startIndex = semanticsIndex + 10;
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'All Semantics with button: true must have an explicit label or hint for screen readers.',
    );
  });
}
