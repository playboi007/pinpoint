import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/sink/markdown_formatter.dart';

/// Milestone 7, build step 1: the Markdown the agent reads, as a pure
/// function fixed by golden files.
void main() {
  const fullGolden = 'test/goldens/note_full.md';
  const minimalGolden = 'test/goldens/note_minimal.md';

  /// The plan's example note (Milestone 4 payload, Milestone 7 layout).
  final full = Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.improve,
    comment: 'Label truncates at narrow widths',
    app: const AppInfo(
      buildMode: 'debug',
      platform: 'web',
      projectRoot: '/Users/me/app',
    ),
    page: const PageInfo(
      url: 'http://localhost:5000/#/orders/12',
      route: '/orders/:id',
      viewport: PayloadSize(1280, 720),
      devicePixelRatio: 2,
      textScale: 1,
      brightness: 'dark',
      locale: 'en_US',
    ),
    target: const TargetInfo(
      widget: 'Text',
      description: 'Text("Save changes")',
      source: SourceRef(
        file: 'lib/widgets/save_bar.dart',
        line: 42,
        column: 18,
      ),
      sourceUnavailable: false,
      rect: PayloadRect(912, 648, 96, 20),
      renderObject: 'RenderParagraph',
      constraints: 'BoxConstraints(0.0<=w<=96.0, 0.0<=h<=Infinity)',
      parentData: 'offset=Offset(16.0, 10.0)',
      text: 'Save changes',
      properties: {'maxLines': '1', 'overflow': 'ellipsis'},
    ),
    ancestors: const [
      AncestorInfo(
        widget: 'ElevatedButton',
        source: SourceRef(
          file: 'lib/widgets/save_bar.dart',
          line: 40,
          column: 14,
        ),
      ),
      AncestorInfo(
        widget: 'SaveBar',
        source: SourceRef(
          file: 'lib/pages/order_page.dart',
          line: 88,
          column: 22,
        ),
      ),
    ],
    frameworkChain: const ['RichText', 'Text', 'DefaultTextStyle'],
    siblings: const SiblingsInfo(
      parent: 'Row',
      index: 1,
      count: 3,
      firstIndex: 0,
      children: ['Icon', 'Text', 'Spacer'],
    ),
    subtree: 'Text  lib/widgets/save_bar.dart:42\n  RichText',
    inherited: const InheritedInfo(
      themeBrightness: 'dark',
      useMaterial3: true,
      textDirection: 'ltr',
    ),
    screenshot: ScreenshotInfo(
      file: 'pp_20261110_143205_a1f3.png',
      pixelRatio: 2,
      width: 640,
      height: 400,
      png: Uint8List.fromList(const [1, 2, 3]),
    ),
  );

  /// Profile build, nothing local, a comment over several lines.
  final minimal = Annotation(
    id: 'pp_20261110_090000_00ff',
    createdAt: DateTime.utc(2026, 11, 10, 9),
    intent: AnnotationIntent.bug,
    comment: 'Wrong colour.\n# Not a heading\n\nSecond paragraph.',
    app: const AppInfo(buildMode: 'profile', platform: 'web'),
    page: const PageInfo(url: 'http://localhost:5000/'),
    target: const TargetInfo(
      widget: 'RichText',
      sourceUnavailable: true,
      constraints: 'BoxConstraints(w=96.0, h=20.0)',
    ),
    errors: const ['target.parentData'],
    truncated: const ['subtree'],
  );

  void expectGolden(String actual, String path) {
    if (autoUpdateGoldenFiles) File(path).writeAsStringSync(actual);
    expect(
      actual,
      File(path).readAsStringSync(),
      reason:
          'Run `flutter test --update-goldens test/sink/'
          'markdown_formatter_test.dart` after a deliberate change, and '
          'review the diff.',
    );
  }

  group('goldens', () {
    test('the plan example', () => expectGolden(markdownFor(full), fullGolden));

    test('a note with no source and a comment over several lines', () {
      expectGolden(markdownFor(minimal), minimalGolden);
    });
  });

  group('layout', () {
    final markdown = markdownFor(full);
    final lines = markdown.split('\n');

    test('leads with the id and intent, then the comment and location', () {
      expect(lines[0], '# Pinpoint pp_20261110_143205_a1f3 (improve)');
      expect(lines[2], 'Comment: Label truncates at narrow widths');
      expect(lines[4], 'Target: Text("Save changes")');
      expect(lines[5], 'Source: lib/widgets/save_bar.dart:42:18');
    });

    test('lists the enclosing local widgets, nearest first', () {
      expect(
        markdown,
        contains(
          'Enclosing: ElevatedButton (lib/widgets/save_bar.dart:40) < '
          'SaveBar (lib/pages/order_page.dart:88)',
        ),
      );
    });

    test('page and layout lines are short', () {
      expect(
        markdown,
        contains('Page: /orders/:id  viewport 1280x720  dark  textScale 1.0'),
      );
      expect(
        markdown,
        contains(
          'Layout: rect 912,648 96x20  constraints 0<=w<=96  '
          'parent Row, child 2 of 3',
        ),
      );
      expect(markdown, contains('Properties: maxLines=1, overflow=ellipsis'));
      expect(markdown, contains('Screenshot: pp_20261110_143205_a1f3.png'));
    });

    test('never carries the image data', () {
      expect(markdown, isNot(contains(base64Encode([1, 2, 3]))));
    });

    test('a comment line cannot start a heading or a field', () {
      final text = markdownFor(minimal);
      expect(text, contains('Comment: Wrong colour.\n  # Not a heading\n'));
      expect(
        RegExp(r'^# ', multiLine: true).allMatches(text),
        hasLength(1),
        reason: 'only the title is a heading',
      );
    });

    test('says when the source is unavailable and names what is missing', () {
      final text = markdownFor(minimal);
      expect(text, contains('Source: unavailable'));
      expect(text, contains('constraints w=96, h=20'));
      expect(text, contains('Not collected: target.parentData'));
      expect(text, contains('Truncated: subtree'));
      expect(text, isNot(contains('Enclosing:')));
      expect(text, isNot(contains('Screenshot:')));
    });
  });

  group('compactConstraints', () {
    test('drops unbounded ranges and trailing .0', () {
      expect(
        compactConstraints('BoxConstraints(0.0<=w<=96.0, 0.0<=h<=Infinity)'),
        '0<=w<=96',
      );
      expect(
        compactConstraints('BoxConstraints(w=96.0, h=20.5)'),
        'w=96, h=20.5',
      );
      expect(
        compactConstraints(
          'BoxConstraints(0.0<=w<=Infinity, 0.0<=h<=Infinity)',
        ),
        'unconstrained',
      );
      expect(
        compactConstraints('BoxConstraints(unconstrained)'),
        'unconstrained',
      );
    });

    test('leaves other constraints as they are', () {
      const sliver = 'SliverConstraints(AxisDirection.down, ...)';
      expect(compactConstraints(sliver), sliver);
    });
  });

  group('markdownFromJson takes what the bridge receives', () {
    test('gives the same text as markdownFor', () {
      final json =
          jsonDecode(jsonEncode(full.toJson())) as Map<String, Object?>;
      expect(markdownFromJson(json), markdownFor(full));
    });

    test('does not throw on fields of the wrong type', () {
      final odd = <String, Object?>{
        'id': 7,
        'intent': ['bug'],
        'comment': null,
        'page': 'x',
        'target': {
          'widget': 3,
          'source': {'file': 1, 'line': 'a'},
          'rect': {'x': 'a'},
          'properties': [1, 2],
        },
        'ancestors': 'none',
        'siblings': {'index': 'a'},
        'subtree': 12,
        'screenshot': {'file': false},
        'errors': [1, 'ok'],
      };
      expect(() => markdownFromJson(odd), returnsNormally);
      expect(markdownFromJson(const {}), startsWith('# Pinpoint'));
    });
  });

  test('Annotation.toMarkdown is the formatter', () {
    expect(full.toMarkdown(), markdownFor(full));
  });
}
