import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PLAN-v2 rule 13: the tape model, the matcher and the tape recorder
/// import no `dart:ui` and no `package:flutter`, also through the files
/// they import. The bridge imports them.
void main() {
  test('tape files are plain Dart, all the way down', () {
    final import = RegExp(
      r'''^(?:import|export)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    final seen = <String>{};
    void visit(String path) {
      if (!seen.add(path)) return;
      final source = File(path).readAsStringSync();
      for (final match in import.allMatches(source)) {
        final uri = match[1]!;
        expect(
          uri == 'dart:ui' || uri.startsWith('package:flutter'),
          isFalse,
          reason: '$path imports $uri',
        );
        if (uri.startsWith('dart:') || uri.startsWith('package:')) continue;
        visit(File(path).parent.uri.resolve(uri).toFilePath());
      }
    }

    for (final path in plainTapeFiles) {
      visit(File(path).absolute.path);
    }
    expect(seen.length, greaterThanOrEqualTo(plainTapeFiles.length));
  });
}

const List<String> plainTapeFiles = [
  'lib/src/model/tape.dart',
  'lib/src/tape/net_matcher.dart',
  'lib/src/tape/tape_recorder.dart',
];
