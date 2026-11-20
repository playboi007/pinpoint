import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/note_detail.dart';

/// Milestone 8, build step 4: how much of a note each detail level shows.
void main() {
  Map<String, Object?> fixture() =>
      jsonDecode(File('test/fixtures/note.json').readAsStringSync())
          as Map<String, Object?>;

  test('acceptance: compact is under 600 characters for a typical note', () {
    final text = noteText(fixture(), NoteDetail.compact);
    // ignore: avoid_print
    print('compact: ${text.length} characters');
    expect(text.length, lessThan(600));
    expect(
      text,
      'pp_20261110_143205_a1f3 (improve, submitted)\n'
      'Comment: Label truncates at narrow widths\n'
      'Target: Text("Save changes")\n'
      'Source: lib/widgets/save_bar.dart:42:18\n'
      'Rect: 912,648 96x20',
    );
  });

  test('compact cuts a long comment, never the source', () {
    final note = fixture()..['comment'] = 'word ' * 400;
    final text = noteText(note, NoteDetail.compact);
    expect(text.length, lessThanOrEqualTo(maxCompactChars));
    expect(text, contains('…'));
    expect(text, contains('Source: lib/widgets/save_bar.dart:42:18'));
  });

  test('standard adds layout, enclosing widgets, page and screenshot', () {
    final text = noteText(fixture(), NoteDetail.standard);
    for (final part in [
      'Enclosing: ElevatedButton (lib/widgets/save_bar.dart:40)',
      'Layout: rect 912,648 96x20  constraints 0<=w<=96  RenderParagraph',
      'parent Row, child 2 of 3',
      'Page: /orders/:id  viewport 1280x720  dark',
      'Screenshot: pp_20261110_143205_a1f3.png (attached',
    ]) {
      expect(text, contains(part));
    }
    expect(text, isNot(contains('Subtree')));
    expect(text, isNot(contains('Properties')));
    expect(text, isNot(contains('Environment')));
    expect(text, isNot(contains('State owners')));
  });

  test('full shows what an owner reads, one line per owner', () {
    final note = fixture()
      ..['stateOwners'] = [
        {
          'kind': 'state',
          'type': '_SaveBarState',
          'source': null,
          'dependencies': [
            {
              'kind': 'provider',
              'type': 'CartModel',
              'tag': '#a1',
              'source': {'file': 'lib/app.dart', 'line': 30, 'column': 9},
            },
            {'kind': 'inherited', 'type': 'Flags', 'tag': '#a2'},
          ],
        },
        {'kind': 'provider', 'type': 'CartModel', 'source': null},
      ];
    final text = noteText(note, NoteDetail.full);
    expect(
      text,
      contains(
        'Reads: _SaveBarState: provider CartModel #a1 (lib/app.dart:30:9), '
        'inherited Flags #a2\n',
      ),
    );
    expect('Reads:'.allMatches(text), hasLength(1));
    expect(noteText(note, NoteDetail.standard), isNot(contains('Reads:')));
  });

  test('full adds properties, subtree, state owners and environment', () {
    final note = fixture()
      ..['stateOwners'] = [
        {'kind': 'state', 'type': '_SaveBarState', 'source': null},
      ];
    final text = noteText(note, NoteDetail.full);
    expect(text, contains('Properties: maxLines=1, overflow=ellipsis'));
    expect(text, contains('Subtree:'));
    expect(text, contains('State owners: state _SaveBarState'));
    expect(text, contains('Environment: debug, web, dpr 2'));
    expect(
      text.length,
      greaterThan(noteText(note, NoteDetail.standard).length),
    );
    // Full is the standard text and more: nothing of standard is lost.
    for (final line in noteText(note, NoteDetail.standard).split('\n')) {
      expect(text, contains(line));
    }
  });

  test('standard keeps the text of the target and the reopened line', () {
    final note = fixture()
      ..['target'] = {
        ...(fixture()['target']! as Map<String, Object?>),
        'text': 'Save changes now',
      }
      ..['reopened'] = 2;
    final text = noteText(note, NoteDetail.standard);
    expect(text, contains('Text: Save changes now'));
    expect(
      text,
      contains(
        'Reopened by the user (2 times): their reason is the last reply.',
      ),
    );
    expect(text, contains('(improve, submitted, reopened 2 times)'));
  });

  // PLAN-v3 Milestone 19, steps 6 and 9.
  group('short paths and the .md', () {
    const root = '/Users/me/project/app';
    const file = '$root/lib/features/detail/detail_toolbar.dart';

    Map<String, Object?> adminLike() => fixture()
      ..['app'] = {'buildMode': 'debug', 'platform': 'web', 'projectRoot': root}
      ..['target'] = {
        'widget': 'Row',
        'source': {'file': file, 'line': 50, 'column': 16},
      }
      ..['ancestors'] = [
        {
          'widget': 'Container',
          'source': {'file': file, 'line': 45, 'column': 14},
        },
        {
          'widget': 'BxLandmark',
          'source': {'file': file, 'line': 43, 'column': 12},
        },
        {
          'widget': 'DetailToolbar',
          'source': {
            'file': '$root/lib/product_detail_screen.dart',
            'line': 278,
          },
        },
      ];

    test('a Root line, relative paths, the file once per run of rows', () {
      final text = noteText(adminLike(), NoteDetail.standard);
      expect(text, contains('Root: $root\n'));
      expect(
        text,
        contains('Source: lib/features/detail/detail_toolbar.dart:50:16'),
      );
      expect(
        text,
        contains(
          'Enclosing: Container (lib/features/detail/detail_toolbar.dart:45) '
          '< BxLandmark :43 '
          '< DetailToolbar (lib/product_detail_screen.dart:278)',
        ),
      );
      expect(text, isNot(contains('$root/')));
      expect(
        noteText(adminLike(), NoteDetail.compact),
        contains('Source: lib/features/detail/detail_toolbar.dart:50:16'),
        reason: 'compact is short too',
      );
    });

    test('the .md is the standard text and a More line', () {
      final note = adminLike();
      final md = noteMarkdown(note);
      // The screenshot on disk is the full-size file beside the .md, not
      // the MCP attachment; every other line is the standard text.
      final standard = noteText(
        note,
        NoteDetail.standard,
      ).replaceAll(' (attached, at most 800 px wide)', '');
      expect(
        md,
        '$standard\n'
        'More: get_note detail full, or pp_20261110_143205_a1f3.json\n',
      );
    });

    test('the screenshot line fits where the text is read', () {
      final note = adminLike()
        ..['screenshot'] = {'file': 'shot.png', 'hasPlatformViews': true};
      expect(
        noteText(note, NoteDetail.standard),
        contains(
          'Screenshot: shot.png (attached, at most 800 px wide) '
          '(platform views show blank)',
        ),
      );
      expect(
        noteMarkdown(note),
        contains('Screenshot: shot.png (platform views show blank)\n'),
      );
    });

    test('"rebuilds not recorded" is dropped, the run kept', () {
      final note = adminLike()
        ..['trace'] = {
          'seconds': 10,
          'rebuilds': false,
          'lines': [
            'rebuilds not recorded',
            '282  +124.69s  f5770  error  AssertionError: boom',
          ],
        };
      final text = noteText(note, NoteDetail.standard);
      expect(text, isNot(contains('rebuilds not recorded')));
      expect(text, contains('What happened (10 s before the pick):'));
      expect(text, contains('AssertionError: boom'));
    });

    test('the subtree of the full text is short too', () {
      final note = adminLike()
        ..['subtree'] =
            'Row  $file:50\n  _SearchField  $file:52\n    Text  $file:60';
      final text = noteText(note, NoteDetail.full);
      expect(
        text,
        contains(
          'Subtree:\n'
          '  Row  lib/features/detail/detail_toolbar.dart:50\n'
          '    _SearchField  :52\n'
          '      Text  :60',
        ),
      );
    });
  });

  test('the what-if overrides show from standard up (Milestone 9)', () {
    final note = fixture()
      ..['environment'] = {
        'viewport': {'width': 360, 'height': 800},
        'textScale': 1.5,
        'textDirection': 'rtl',
      };
    const line = 'What-if: viewport 360x800, textScale 1.5, rtl';
    expect(noteText(note, NoteDetail.compact), isNot(contains('What-if')));
    expect(noteText(note, NoteDetail.standard), contains(line));
    expect(noteText(note, NoteDetail.full), contains(line));
    expect(noteText(fixture(), NoteDetail.full), isNot(contains('What-if')));
  });

  test('replies show from standard up', () {
    final note = fixture()
      ..['messages'] = [
        {'at': '2026-11-10T15:00:00Z', 'from': 'agent', 'text': 'Wrapped it.'},
      ];
    expect(noteText(note, NoteDetail.compact), isNot(contains('Wrapped')));
    expect(
      noteText(note, NoteDetail.standard),
      contains('Replies:\n- agent: Wrapped it.'),
    );
  });

  // PLAN-v3 Milestone 19: the note of the admin app (8.5 KB JSON, 2.2 KB of
  // ancestors, 1.5 KB of absolute paths) as the new code makes it, and the
  // standard text under 3 KB.
  test('size check: an admin-like note has a standard text under 3 KB', () {
    final note = adminLikeNote();
    final standard = noteText(note, NoteDetail.standard);
    final md = noteMarkdown(note);
    // ignore: avoid_print
    print('standard: ${utf8.encode(standard).length} bytes');
    expect(utf8.encode(standard).length, lessThan(3 * 1024));
    expect(utf8.encode(md).length, lessThan(3 * 1024 + 100));
    // What it is made of: one root, short paths, the file once per run.
    expect(standard, contains('Root: $adminRoot\n'));
    expect(standard, isNot(contains('$adminRoot/')));
    expect(standard, isNot(contains('rebuilds not recorded')));
    expect(standard, isNot(contains('Subtree')));
    // The full text still holds the subtree, and is longer.
    final full = noteText(note, NoteDetail.full);
    expect(full, contains('Subtree:'));
    expect(utf8.encode(full).length, greaterThan(utf8.encode(standard).length));
  });

  test('detail names', () {
    expect(NoteDetail.byName(null), NoteDetail.standard);
    expect(NoteDetail.byName('full'), NoteDetail.full);
    expect(NoteDetail.byName('huge'), isNull);
  });
}

const String adminRoot = '/Users/dev/work/admin-product/app';
const String _features = '$adminRoot/lib/src/features/llm reviews/presentation';
const String _toolbar = '$_features/detail/detail_toolbar.dart';
const String _screen = '$_features/product_detail_screen.dart';
const String _semantics = '$adminRoot/lib/src/core/widgets/bx_semantics.dart';

/// A note as the admin app made it: 12 ancestors (2 of them `Semantics`
/// wrappers), absolute paths, a long subtree, the run's one error line. The
/// root is what the bridge adds when the app sent none. The framework chain
/// is not in the note any more.
Map<String, Object?> adminLikeNote() {
  Map<String, Object?> at(String file, int line, [int column = 12]) => {
    'file': file,
    'line': line,
    'column': column,
  };
  Map<String, Object?> up(String widget, String file, int line) => {
    'widget': widget,
    'source': at(file, line),
  };
  return {
    'schema': 10,
    'id': 'pp_20261115_093759_d726',
    'createdAt': '2026-11-15T09:37:59Z',
    'status': 'fixed',
    'intent': 'bug',
    'comment':
        'create. space between the filters and undo when the space is small',
    'app': {
      'buildMode': 'debug',
      'platform': 'web',
      'projectRoot': adminRoot,
      'origin': 'http://localhost:53994',
    },
    'page': {
      'url': 'http://localhost:53994/#/genai-product-review?token=***',
      'route': '/genai-product-review',
      'viewport': {'width': 1023, 'height': 703},
      'brightness': 'dark',
      'textScale': 1.0,
    },
    'target': {
      'widget': 'Row',
      'description': 'Row',
      'source': at(_toolbar, 50, 16),
      'rect': {'x': 424, 'y': 166, 'w': 583, 'h': 30},
      'renderObject': 'RenderFlex',
      'constraints': 'BoxConstraints(w=583.0, 0.0<=h<=Infinity)',
      'text':
          'Search attributes\u2026 Filters Undo 0 Accept all \u00b7 32 Reject all \u00b7 32',
      'properties': {
        'direction': 'horizontal',
        'mainAxisAlignment': 'start',
        'crossAxisAlignment': 'center',
      },
    },
    'ancestors': [
      up('Container', _toolbar, 45),
      up('Semantics', _semantics, 82),
      up('BxLandmark', _toolbar, 43),
      up('DetailToolbar', _screen, 278),
      up('Column', _screen, 273),
      up('Expanded', _screen, 272),
      up('Row', _screen, 267),
      up('Padding', _screen, 260),
      up('Expanded', _screen, 259),
      up('Column', _screen, 256),
      up('Semantics', _semantics, 82),
      up('BxLandmark', _screen, 254),
    ],
    'siblings': {
      'parent': 'Column',
      'index': 2,
      'count': 4,
      'firstIndex': 0,
      'children': ['A', 'B', 'Row', 'D'],
    },
    'subtree': [
      'Row  $_toolbar:50',
      '  _SearchField  $_toolbar:52',
      '    ConstrainedBox  $_toolbar:223 …',
      '  SizedBox  $_toolbar:56',
      '  BxFiltersButton  $_toolbar:57',
      '    CompositedTransformTarget  $_features/filters/bx_filters_button.dart:122',
      '  _UndoButton  $_toolbar:67',
      '    BxButtonSemantics  $_toolbar:250',
      '  Container  $_toolbar:68',
      '  _BulkButton-[<\'detail-toolbar-accept\'>]  $_toolbar:74',
      '  SizedBox  $_toolbar:82',
      '  _BulkButton-[<\'detail-toolbar-reject\'>]  $_toolbar:83',
    ].join('\n'),
    'screenshot': {'file': 'pp_20261115_093759_d726.png'},
    'messages': [
      {
        'at': '2026-11-15T09:38:46Z',
        'from': 'agent',
        'text': 'Investigating the requested change.',
      },
      {
        'at': '2026-11-15T09:40:34Z',
        'from': 'agent',
        'text':
            'Added spacing between toolbar controls, including filters and '
            'undo, as they wrap.',
      },
    ],
    'trace': {
      'seconds': 10,
      'rebuilds': false,
      'lines': [
        'rebuilds not recorded',
        '282  +124.69s  f5770  error  AssertionErrorImpl: Assertion failed: '
            'org-dartlang-sdk:///lib/_engine/engine/text_editing/'
            'text_editing.dart:1346:7',
      ],
    },
  };
}
