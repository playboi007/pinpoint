import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/sink/markdown_formatter.dart';
import 'package:pinpoint/src/sink/pinpoint_sink.dart';

import '../support/fake_sink.dart';

/// Milestone 5: Send gives the note to each sink in order.
void main() {
  final note = Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.bug,
    comment: 'Label truncates\nat narrow widths',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(route: '/orders/:id'),
    target: const TargetInfo(
      widget: 'Text',
      description: 'Text("Save changes")',
      source: SourceRef(
        file: 'lib/widgets/save_bar.dart',
        line: 42,
        column: 18,
      ),
      sourceUnavailable: false,
    ),
    ancestors: const [
      AncestorInfo(
        widget: 'SaveBar',
        source: SourceRef(
          file: 'lib/pages/order_page.dart',
          line: 88,
          column: 22,
        ),
      ),
    ],
  );

  group('sendToSinks', () {
    test('calls every sink in order and reports each', () async {
      final calls = <String>[];
      final sinks = [
        _Recording('A', calls),
        _Recording('B', calls, fail: true),
        _Recording('C', calls),
      ];
      final results = await sendToSinks(note, sinks);
      expect(calls, ['A', 'B', 'C']);
      expect([for (final r in results) r.sink], ['A', 'B', 'C']);
      expect([for (final r in results) r.ok], [true, false, true]);
      expect(results[1].error.toString(), contains('B is down'));
    });

    test('a sink that throws before its future still fails alone', () async {
      final results = await sendToSinks(note, [_ThrowsAtOnce(), FakeSink()]);
      expect([for (final r in results) r.ok], [false, true]);
    });

    test('a sink that never answers times out', () async {
      final hung = FakeSink()..gate = Completer<void>();
      final results = await sendToSinks(note, [
        hung,
        FakeSink(name: 'next'),
      ], timeout: const Duration(milliseconds: 20));
      expect(results.first.error, isA<TimeoutException>());
      expect(results.last.ok, isTrue);
    });

    test('no sinks, no results', () async {
      expect(await sendToSinks(note, const []), isEmpty);
    });
  });

  group('markdownFor (interim until Milestone 7)', () {
    test('leads with the comment and the location, then the full note', () {
      final markdown = markdownFor(note);
      final lines = markdown.split('\n');
      expect(lines.first, '# Pinpoint ${note.id} (${note.intent.name})');
      expect(markdown, contains('Comment: ${note.comment}'));
      expect(
        markdown,
        contains('Enclosing: SaveBar (lib/pages/order_page.dart:88)'),
      );
      final source = note.target.source!;
      expect(
        markdown,
        contains('Source: ${source.file}:${source.line}:${source.column}'),
      );
      final json = RegExp(r'```json\n([\s\S]*)\n```')
          .firstMatch(markdown)!
          .group(1)!;
      expect(jsonDecode(json), jsonDecode(jsonEncode(note.toJson())));
    });
  });
}

class _Recording extends PinPointSink {
  _Recording(this.name, this.calls, {this.fail = false});

  @override
  final String name;
  final List<String> calls;
  final bool fail;

  @override
  Future<void> send(Annotation note) async {
    calls.add(name);
    if (fail) throw StateError('$name is down');
  }
}

class _ThrowsAtOnce extends PinPointSink {
  @override
  String get name => 'eager';

  @override
  Future<void> send(Annotation note) => throw StateError('no');
}
