import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'source_metrics.dart';
import 'source_scan.dart';

ScannedSource _scan(String source) {
  final dir = Directory.systemTemp.createTempSync('pinpoint_scan');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/sample.dart')..writeAsStringSync(source);
  return ScannedSource.read(file);
}

void main() {
  group('scanner', () {
    test('a comment marker inside a string is not a comment', () {
      final scan = _scan("final a = 'http://x'; // real\n");
      expect(scan.comments.map((c) => c.text), ['// real']);
      expect(scan.codeWithStrings, contains("'http://x'"));
      expect(scan.code, isNot(contains('http')));
    });

    test(
      'interpolation, triple quotes and raw strings stay inside strings',
      () {
        final scan = _scan(
          "final a = '\${b['x'] ?? \"y\"} // no';\n"
          "final c = '''\n// no\n''';\n"
          "final d = r'\\n // no';\n"
          '// yes\n',
        );
        expect(scan.comments.map((c) => c.text), ['// yes']);
      },
    );

    test('block comments nest and count each line', () {
      final scan = _scan('/* a /* b */\n c */\nint x = 0;\n');
      expect(scan.comments.map((c) => c.text), ['/* a /* b */', 'c */']);
      expect(scan.code, contains('int x'));
    });
  });

  group('metrics', () {
    test('a function length counts the lines from its name to its brace', () {
      final scan = _scan(
        'int work(int a) {\n  if (a > 0) {\n    return a;\n  }\n  return 0;\n}\n'
        'void run() {\n  final f = () {\n    return 1;\n  };\n}\n',
      );
      final spans = {for (final s in functionSpans(scan)) s.name: s.length};
      expect(spans, {'work': 6, 'run': 5});
    });

    test('a positional bool counts, a named or setter bool does not', () {
      final scan = _scan(
        'void a(int x, bool flag) {}\n'
        'void b({bool flag = false}) {}\n'
        'void c([bool flag = false]) {}\n'
        'set d(bool value) {}\n'
        'void e(void Function(bool visible) onChange) {}\n',
      );
      final hits = positionalBoolParameters([scan]).map((h) => h.detail);
      expect(hits, ['a']);
    });

    test('a string compare counts, an empty one does not', () {
      final scan = _scan(
        "bool a(String k) => k == 'hover' || 'x' != k;\n"
        "bool b(String k) => k == '';\n"
        "String c(String k) { switch (k) { case 'up': return ''; } return k; }\n",
      );
      expect(stringKindCompares([scan]).length, 3);
    });

    test('a copied JSON helper is found by its shape', () {
      final scan = _scan(
        'Map<String, Object?> _map(Object? v) =>\n'
        '    v is Map<String, Object?> ? v : const {};\n'
        'Object? other(Object? v) => v;\n',
      );
      expect(jsonHelpers([scan]).map((h) => h.detail), ['_map']);
    });
  });
}
