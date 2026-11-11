import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';

/// Milestone 4, build step 1: the payload model, fixed by a golden file
/// before any collection code exists.
void main() {
  const golden = 'test/goldens/annotation_schema.json';

  Annotation example() => Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5, 123),
    intent: AnnotationIntent.improve,
    comment: 'Label truncates at narrow widths',
    app: const AppInfo(
      buildMode: 'debug',
      platform: 'web',
      projectRoot: '/Users/me/app',
      origin: 'http://localhost:5000',
    ),
    status: NoteStatus.submitted,
    anchor: const NoteAnchor(
      file: 'lib/widgets/save_bar.dart',
      line: 42,
      column: 18,
      widget: 'Text',
      route: '/orders/:id',
    ),
    messages: [
      NoteMessage(
        at: DateTime.utc(2026, 11, 10, 14, 40),
        from: 'agent',
        text: 'Gave the label room to wrap.',
      ),
    ],
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
      rect: PayloadRect(912, 648.5, 96, 20),
      renderObject: 'RenderParagraph',
      constraints: 'BoxConstraints(0.0<=w<=96.0, 0.0<=h<=Infinity)',
      text: 'Save changes',
      properties: {'maxLines': '1', 'overflow': 'ellipsis'},
      sections: {
        'Text': {
          'text': 'Save changes',
          'fontSize': '14.0',
          'fontWeight': 'w400 (Regular)',
        },
      },
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
    frameworkChain: const [
      'RichText',
      'Text',
      'DefaultTextStyle',
      'ElevatedButton',
    ],
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
    screenshot: const ScreenshotInfo(
      file: 'pp_20261110_143205_a1f3.png',
      pixelRatio: 2,
      width: 640,
      height: 400,
      crop: PayloadRect(800, 558.5, 320, 200),
    ),
    errors: const ['target.parentData'],
    truncated: const ['subtree'],
  );

  test('toJson matches the schema golden', () {
    final expected = jsonDecode(File(golden).readAsStringSync());
    // Through a real encode, so the golden also proves the map is valid
    // JSON.
    final actual = jsonDecode(jsonEncode(example().toJson()));
    expect(actual, expected);
  });

  test('schema is version 5 and keys come in a fixed order', () {
    final json = example().toJson();
    expect(json['schema'], 5);
    expect(json.keys.take(6), [
      'schema',
      'id',
      'createdAt',
      'status',
      'intent',
      'comment',
    ]);
  });

  group('environment (Milestone 9)', () {
    Annotation note({Map<String, Object?>? environment}) => Annotation(
      id: 'pp_1',
      createdAt: DateTime.utc(2026),
      intent: AnnotationIntent.bug,
      comment: '',
      app: const AppInfo(buildMode: 'debug', platform: 'web'),
      page: const PageInfo(),
      target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
      environment: environment,
    );

    test('is left out when nothing is overridden', () {
      expect(note().toJson().containsKey('environment'), isFalse);
      expect(
        note(environment: const {}).toJson().containsKey('environment'),
        isFalse,
      );
    });

    test('follows the page and holds only the overridden fields', () {
      final json = note(
        environment: const {
          'viewport': {'width': 360, 'height': 800},
          'textScale': 1.5,
        },
      ).toJson();
      final keys = json.keys.toList();
      expect(keys.indexOf('environment'), keys.indexOf('page') + 1);
      expect(json['environment'], {
        'viewport': {'width': 360, 'height': 800},
        'textScale': 1.5,
      });
    });

    test('reads back from JSON', () {
      final back = Annotation.fromJson(
        jsonDecode(
          jsonEncode(
            note(environment: const {'textDirection': 'rtl'}).toJson(),
          ),
        ) as Map<String, Object?>,
      )!;
      expect(back.environment, {'textDirection': 'rtl'});
    });
  });

  group('finding and checks (Milestone 10)', () {
    Annotation note({
      Map<String, Object?>? finding,
      List<Map<String, Object?>> checks = const [],
    }) => Annotation(
      id: 'pp_1',
      createdAt: DateTime.utc(2026),
      intent: AnnotationIntent.bug,
      comment: '',
      app: const AppInfo(buildMode: 'debug', platform: 'web'),
      page: const PageInfo(),
      target: const TargetInfo(widget: 'Row', sourceUnavailable: true),
      finding: finding,
      checks: checks,
    );

    const finding = {
      'kind': 'overflow',
      'severity': 'error',
      'summary': 'Row overflows by 72 px on the right',
      'key': 'overflow|lib/a.dart:3:5|',
      'data': {'overflow': 72.0, 'side': 'right'},
    };

    test('are left out of a note made by hand', () {
      final json = note().toJson();
      expect(json.containsKey('finding'), isFalse);
      expect(json.containsKey('checks'), isFalse);
    });

    test('follow the environment slot and read back from JSON', () {
      final json = note(
        finding: finding,
        checks: const [
          {'type': 'no_overflow'},
        ],
      ).toJson();
      final keys = json.keys.toList();
      expect(keys.indexOf('finding'), keys.indexOf('page') + 1);
      expect(keys.indexOf('checks'), keys.indexOf('finding') + 1);
      final back = Annotation.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      )!;
      expect(back.finding, finding);
      expect(back.checks, [
        {'type': 'no_overflow'},
      ]);
    });

    test('a check without a type is dropped on read', () {
      final back = Annotation.fromJson({
        ...note().toJson(),
        'checks': [
          {'min': 48},
          'no_overflow',
          {'type': 'visible'},
        ],
      })!;
      expect(back.checks, [
        {'type': 'visible'},
      ]);
    });
  });

  test('empty errors and truncated lists are left out', () {
    final json = Annotation(
      id: 'pp_1',
      createdAt: DateTime.utc(2026),
      intent: AnnotationIntent.bug,
      comment: '',
      app: const AppInfo(buildMode: 'debug', platform: 'web'),
      page: const PageInfo(),
      target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
    ).toJson();
    expect(json.containsKey('errors'), isFalse);
    expect(json.containsKey('truncated'), isFalse);
    // Missing optional parts are null, not absent: the shape stays fixed.
    expect(json['siblings'], isNull);
    expect(json.containsKey('siblings'), isTrue);
    expect(json['ancestors'], isEmpty);
  });

  group('JSON cannot hold Infinity or NaN', () {
    test('non-finite numbers become null', () {
      const rect = PayloadRect(double.nan, 0, double.infinity, 20);
      expect(rect.toJson(), {'x': null, 'y': 0, 'w': null, 'h': 20});
      const page = PageInfo(
        viewport: PayloadSize(double.infinity, 600),
        devicePixelRatio: double.nan,
      );
      expect(() => jsonEncode(page.toJson()), returnsNormally);
      expect(page.toJson()['devicePixelRatio'], isNull);
    });

    test('numbers are rounded to 0.01 and whole numbers are ints', () {
      expect(const PayloadRect(1, 2.004, 3.456, 4.5).toJson(), {
        'x': 1,
        'y': 2,
        'w': 3.46,
        'h': 4.5,
      });
      expect(const PayloadRect(1, 2, 3, 4).toJson()['x'], isA<int>());
    });
  });

  group('id and createdAt', () {
    test('id is pp_<date>_<time>_<4 hex> in UTC, safe as a file name', () {
      final id = annotationId(
        DateTime.utc(2026, 11, 10, 14, 32, 5),
        math.Random(1),
      );
      expect(id, matches(RegExp(r'^pp_20261110_143205_[0-9a-f]{4}$')));
      // The receiver uses the id as a file name (Milestone 7).
      expect(id, matches(RegExp(r'^[a-z0-9_]+$')));
    });

    test('a local time is converted to UTC', () {
      final local = DateTime(2026, 11, 10, 14, 32, 5);
      final id = annotationId(local, math.Random(1));
      final utc = local.toUtc();
      final stamp =
          '${utc.year}${_two(utc.month)}${_two(utc.day)}_'
          '${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}';
      expect(id, startsWith('pp_${stamp}_'));
    });

    test('createdAt is UTC to the second, with a Z', () {
      final json = example().toJson();
      expect(json['createdAt'], '2026-11-10T14:32:05Z');
    });
  });

  group('clipText', () {
    test('short text is unchanged', () {
      expect(clipText('Save', 10), 'Save');
      expect(clipText('0123456789', 10), '0123456789');
    });

    test('long text is cut to max characters, ending in an ellipsis', () {
      final clipped = clipText('0123456789ABC', 10);
      expect(clipped, '012345678…');
      expect(clipped.length, 10);
    });

    test('a surrogate pair is never split', () {
      // Nine ASCII characters, then an emoji (two UTF-16 code units).
      final clipped = clipText('012345678😀tail', 11);
      expect(clipped, '012345678…');
      expect(() => utf8.encode(clipped), returnsNormally);
      expect(clipped.codeUnits.last, '…'.codeUnitAt(0));
    });
  });

  test('the model imports neither dart:ui nor package:flutter', () {
    // `bin/bridge.dart` is a plain Dart process and imports this file.
    for (final file in [
      'lib/src/model/annotation.dart',
      'lib/src/model/source_location.dart',
    ]) {
      final imports = File(file)
          .readAsLinesSync()
          .where((l) => l.startsWith('import '));
      for (final line in imports) {
        expect(line, isNot(contains('dart:ui')), reason: file);
        expect(line, isNot(contains('package:flutter')), reason: file);
      }
    }
  });
}

String _two(int n) => n.toString().padLeft(2, '0');
