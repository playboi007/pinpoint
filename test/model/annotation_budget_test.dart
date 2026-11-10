import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';

/// Milestone 4, build step 4: the JSON without the screenshot stays under
/// 8 KB. Long parts are cut, least useful first, and named in `truncated`.
void main() {
  int bytes(Annotation a) => utf8.encode(jsonEncode(a.toJson())).length;

  Annotation note({
    String comment = 'Label truncates',
    int properties = 20,
    int subtreeLines = 40,
    int chain = 40,
    int ancestors = 12,
    String text = 'Save changes',
  }) => Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.bug,
    comment: comment,
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(route: '/orders'),
    target: TargetInfo(
      widget: 'Text',
      description: 'Text("${'d' * 190}")',
      sourceUnavailable: false,
      source: const SourceRef(file: 'lib/a.dart', line: 1, column: 1),
      text: text,
      properties: {
        for (var i = 0; i < properties; i++) 'property$i': 'v' * 200,
      },
      sections: {
        'Text': {'text': 't' * 200, 'fontSize': '14.0'},
      },
    ),
    ancestors: [
      for (var i = 0; i < ancestors; i++)
        AncestorInfo(
          widget: 'Ancestor$i',
          source: SourceRef(file: 'lib/widgets/a_$i.dart', line: i, column: 1),
        ),
    ],
    frameworkChain: [for (var i = 0; i < chain; i++) '_FrameworkWidget$i'],
    siblings: SiblingsInfo(
      parent: 'Column',
      index: 6,
      count: 1000,
      firstIndex: 0,
      children: [for (var i = 0; i < 12; i++) 'ListTile-[<${'k' * 60}>]'],
    ),
    subtree: [
      for (var i = 0; i < subtreeLines; i++)
        '${'  ' * (i % 4)}Widget$i  lib/widgets/some/long/path/file_$i.dart:$i',
    ].join('\n'),
  );

  test('a note under the budget is unchanged', () {
    final small = note(properties: 2, subtreeLines: 3, chain: 4);
    final fitted = small.fitToBudget();
    expect(bytes(fitted), bytes(small));
    expect(fitted.truncated, isEmpty);
  });

  test('a full note is cut under 8 KB, least useful parts first', () {
    final full = note();
    expect(bytes(full), greaterThan(maxPayloadBytes));

    final fitted = full.fitToBudget();
    expect(bytes(fitted), lessThanOrEqualTo(maxPayloadBytes));
    expect(fitted.truncated, isNotEmpty);
    expect(fitted.truncated.first, 'subtree');
    // What the agent acts on is kept whole.
    expect(fitted.comment, full.comment);
    expect(fitted.target.source!.file, 'lib/a.dart');
    expect(fitted.target.text, 'Save changes');
    expect(fitted.truncated, isNot(contains('comment')));
  });

  test('a cut subtree keeps its first lines and ends in an ellipsis', () {
    final fitted = note().fitToBudget();
    final lines = fitted.subtree?.split('\n');
    if (lines != null) {
      expect(lines.first, startsWith('Widget0'));
      expect(lines.last, '…');
    }
  });

  test('a cut sibling list still holds the target', () {
    final fitted = note().fitToBudget(maxBytes: 3000);
    final siblings = fitted.siblings;
    if (siblings != null && fitted.truncated.contains('siblings')) {
      expect(siblings.firstIndex, lessThanOrEqualTo(siblings.index));
      expect(
        siblings.firstIndex + siblings.children.length,
        greaterThan(siblings.index),
      );
    }
    expect(bytes(fitted), lessThanOrEqualTo(3000));
  });

  test('a huge comment is cut only as the last resort', () {
    final long = note(comment: 'c' * 20000).fitToBudget();
    expect(bytes(long), lessThanOrEqualTo(maxPayloadBytes));
    expect(long.truncated.last, 'comment');
    expect(long.comment, endsWith('…'));
    expect(long.comment.length, greaterThan(1000));
  });

  test('multi-byte text is measured in UTF-8 bytes', () {
    // Three bytes per character: 3,000 characters are 9,000 bytes.
    final wide = note(
      comment: '漢' * 3000,
      properties: 0,
      subtreeLines: 1,
      chain: 1,
      ancestors: 1,
    ).fitToBudget();
    expect(bytes(wide), lessThanOrEqualTo(maxPayloadBytes));
    expect(() => utf8.encode(wide.comment), returnsNormally);
  });
}
