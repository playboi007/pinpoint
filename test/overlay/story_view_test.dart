import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/source_lookup.dart';
import 'package:pinpoint/src/bridge/story_text.dart';
import 'package:pinpoint/src/core/code_line_cache.dart';
import 'package:pinpoint/src/overlay/state_chain.dart';
import 'package:pinpoint/src/overlay/story_view.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';
import 'package:pinpoint/src/trace/story.dart';
import 'package:pinpoint/src/trace/story_names.dart';

import '../support/fake_bridge.dart';

/// PLAN-v3 Milestone 21b: the story rows in the watch card and the State
/// tab ([StoryView]), and the check that the card and the `state_flow` text
/// read the same blocks.
void main() {
  tearDown(() => BridgeClient.debugClient = null);

  StoryRow notifyRow({
    String owner = 'CartModel',
    String? src,
    int count = 1,
    List<StoryChange> changes = const [],
    List<StoryInstance> instances = const [],
    int instanceCount = 0,
    String? verb,
    int? afterMs,
  }) => StoryRow(
    kind: 'notify',
    owner: owner,
    src: src,
    srcArg: src == null ? null : 'valueListenable',
    count: count,
    changes: changes,
    instances: instances,
    instanceCount: instanceCount,
    verb: verb,
    afterMs: afterMs,
    file: 'lib/cart.dart',
    line: 10,
    method: 'CartModel.add',
  );

  StoryBlock block(
    String id,
    List<StoryRow> rows, {
    StoryCause cause = const StoryCause(
      kind: StoryKind.tap,
      label: 'tap "Fetch"',
      id: 1,
    ),
    int at = 1240,
    String? hint,
    List<String> rebuilt = const ['CartPage'],
    int repeat = 1,
    int? lastAt,
  }) => StoryBlock(
    id: id,
    at: at,
    wall: 1700000000000 + at,
    cause: cause,
    rows: rows,
    rebuilt: rebuilt,
    rebuiltCount: rebuilt.length,
    hint: hint,
    repeat: repeat,
    lastAt: lastAt,
  );

  Future<StoryFilter> pump(
    WidgetTester tester,
    Story story, {
    StoryFilter filter = const StoryFilter(),
    ValueChanged<StoryFilter>? onFilter,
    CodeLineCache? cache,
    BridgeClient? Function()? bridge,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StoryView(
              story: story,
              filter: filter,
              onFilter: onFilter ?? (_) {},
              cache: cache ?? CodeLineCache(),
              bridge: bridge,
            ),
          ),
        ),
      ),
    );
    return filter;
  }

  testWidgets('a block: its time and cause, the row with its change, the '
      'widgets that rebuilt, and no tag', (tester) async {
    await pump(
      tester,
      Story(
        blocks: [
          block('c1', [
            notifyRow(
              changes: const [StoryChange('count 1 → 2')],
              afterMs: 420,
            ),
          ], hint: 'CartModel.add() changed values that 2 widgets read'),
        ],
      ),
    );

    expect(find.text('+1.24 s'), findsOneWidget);
    expect(find.text('tap "Fetch"'), findsOneWidget);
    expect(find.textContaining('CartModel'), findsWidgets);
    expect(find.textContaining('+420 ms'), findsOneWidget);
    expect(find.text('count 1 → 2'), findsOneWidget);
    expect(find.textContaining('Rebuilt 1: '), findsOneWidget);
    expect(find.byKey(StateChain.hintKey('c1')), findsOneWidget);
    expect(find.textContaining('#a'), findsNothing);
    // The clock shows on hover.
    final tip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tip.message, matches(RegExp(r'^\d\d:\d\d:\d\d\.\d\d\d$')));
  });

  testWidgets('a block that repeats: "×N" and the span; frame numbers show '
      'only for a block with no cause', (tester) async {
    await pump(
      tester,
      Story(
        blocks: [
          block(
            'c2',
            [notifyRow()],
            cause: const StoryCause(kind: StoryKind.hover, label: 'hover'),
            repeat: 20,
            lastAt: 4200,
          ),
          StoryBlock(
            id: 'f9',
            at: 5000,
            frame: 9,
            cause: const StoryCause(
              kind: StoryKind.none,
              label: 'no cause recorded',
            ),
            rows: [notifyRow()],
          ),
        ],
        noCauseHint: 'Changes have no cause: PinPoint.run gives causes.',
      ),
    );

    expect(find.text('+1.24 s … +4.20 s'), findsOneWidget);
    expect(find.text('hover ×20'), findsOneWidget);
    expect(find.text('no cause recorded (f9)'), findsOneWidget);
    // The one hint at the top, once.
    expect(find.byKey(StoryKeys.noCause), findsOneWidget);
  });

  testWidgets('a grouped row: "×12", the variants with counts, and an '
      'instance list that opens', (tester) async {
    await pump(
      tester,
      Story(
        blocks: [
          block('c3', [
            notifyRow(
              owner: 'ValueNotifier<({bool focused, bool open})>',
              count: 12,
              changes: const [
                StoryChange('focused false → true', 3),
                StoryChange('focused true → false', 9),
              ],
              instanceCount: 12,
              instances: [
                for (var i = 0; i < 3; i++)
                  StoryInstance('index $i', 'focused false → true'),
              ],
            ),
          ]),
        ],
      ),
    );

    expect(
      find.textContaining('ValueNotifier<(focused, open)>'),
      findsOneWidget,
    );
    expect(find.textContaining('×12'), findsOneWidget);
    expect(
      find.text('focused false → true (3), focused true → false (9)'),
      findsOneWidget,
    );
    expect(find.byKey(StoryKeys.instanceList('c3', 0)), findsNothing);
    await tester.tap(find.byKey(StoryKeys.instances('c3', 0)));
    await tester.pump();
    expect(find.byKey(StoryKeys.instanceList('c3', 0)), findsOneWidget);
    expect(
      find.textContaining('index 1  focused false → true'),
      findsOneWidget,
    );
    expect(find.textContaining('+9 more'), findsOneWidget);
    await tester.tap(find.byKey(StoryKeys.instances('c3', 0)));
    await tester.pump();
    expect(find.byKey(StoryKeys.instanceList('c3', 0)), findsNothing);
  });

  testWidgets('the name: the short type first, the expression from the '
      'code when the bridge answers, asked once', (tester) async {
    final asked = <Uri>[];
    final fake = FakeBridge();
    BridgeClient.debugClient = MockClient((request) async {
      if (request.url.path != '/source') return fake.handle(request);
      asked.add(request.url);
      final line = int.parse(request.url.queryParameters['line']!);
      return http.Response(
        jsonEncode({
          'file': request.url.queryParameters['file'],
          'start': line,
          'end': line + 2,
          'text':
              'ValueListenableBuilder<bool>(\n'
              '  valueListenable: _focused,\n'
              '  builder: (c, v, _) => const SizedBox(),\n'
              ')',
        }),
        200,
      );
    });
    final config = PinPointConfig(
      bridgeUrl: Uri.parse('http://127.0.0.1:4747'),
    );
    BridgeClient? bridge() =>
        BridgeClient.find(url: config.bridgeUrl, sinks: config.sinks);
    final cache = CodeLineCache();
    addTearDown(cache.dispose);
    final story = Story(
      blocks: [
        block('c4', [
          notifyRow(owner: 'ValueNotifier<bool>', src: 'lib/filters.dart:12'),
        ]),
      ],
    );

    await pump(tester, story, cache: cache, bridge: bridge);
    // The first frame shows rung 3: never blocks on the bridge.
    expect(find.textContaining('ValueNotifier<bool>'), findsOneWidget);
    expect(find.textContaining('_focused'), findsNothing);

    await tester.pump();
    await tester.pump();

    expect(find.textContaining('_focused'), findsOneWidget);
    expect(find.textContaining('(ValueNotifier<bool>)'), findsOneWidget);
    expect(
      asked.where((u) => u.queryParameters['before'] == '0'),
      hasLength(1),
    );
    // Built again: not asked again.
    await pump(tester, story, cache: cache, bridge: bridge);
    await tester.pump();
    expect(
      asked.where((u) => u.queryParameters['before'] == '0'),
      hasLength(1),
    );
    expect(cache.nameAt('lib/filters.dart:12', 'valueListenable'), '_focused');
  });

  testWidgets('the fold line says what is hidden; "show" asks for it; '
      'after that "hide" is offered; "Only my state" toggles', (tester) async {
    final asked = <StoryFilter>[];
    await pump(
      tester,
      Story(
        blocks: [
          block('c5', [notifyRow()]),
        ],
        hiddenHover: 4,
        hiddenControllers: 2,
      ),
      onFilter: asked.add,
    );

    expect(
      find.text(
        '4 hover or focus changes hidden, 2 controller changes hidden ·',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(StoryKeys.foldShow));
    expect(asked.last.showHover, isTrue);
    expect(asked.last.showControllers, isTrue);

    await tester.tap(find.byKey(StoryKeys.onlyMine));
    expect(asked.last.onlyMine, isTrue);

    await pump(
      tester,
      Story(
        blocks: [
          block('c5', [notifyRow()]),
        ],
      ),
      filter: const StoryFilter(showHover: true),
      onFilter: asked.add,
    );
    expect(find.byKey(StoryKeys.fold), findsNothing);
    await tester.tap(find.byKey(StoryKeys.foldHide));
    expect(asked.last.showHover, isFalse);
  });

  testWidgets('nothing changed yet; end lines in time order; dropped '
      'blocks are counted', (tester) async {
    await pump(tester, const Story());
    expect(find.text('Nothing changed yet — use the app'), findsOneWidget);

    await pump(
      tester,
      Story(
        blocks: [
          block('c6', [notifyRow()], at: 2000),
        ],
        ends: const [
          StoryEnd(500, 'hot reload'),
          StoryEnd(9000, 'target left the screen'),
        ],
        droppedBlocks: 15,
      ),
    );
    expect(find.text('15 earlier blocks not shown'), findsOneWidget);
    final reload = tester.getTopLeft(find.textContaining('hot reload')).dy;
    final tap = tester.getTopLeft(find.text('tap "Fetch"')).dy;
    final left = tester.getTopLeft(find.textContaining('target left')).dy;
    // Oldest at the top.
    expect(reload, lessThan(tap));
    expect(tap, lessThan(left));
  });

  testWidgets('the card and the state_flow text read the same blocks', (
    tester,
  ) async {
    final story = Story(
      blocks: [
        block('c7', [
          notifyRow(
            owner: 'ValueNotifier<bool>',
            count: 3,
            changes: const [StoryChange('false → true', 3)],
          ),
        ], hint: 'CartModel.add() changed values that 2 widgets read'),
        StoryBlock(
          id: 'f8',
          at: 3000,
          frame: 8,
          cause: const StoryCause(
            kind: StoryKind.none,
            label: 'no cause recorded',
          ),
          rows: const [StoryRow(kind: 'setState', owner: '_CartState')],
        ),
      ],
      ends: const [StoryEnd(9000, 'window ended')],
    );
    // Over JSON, as the bridge gets it.
    final sent = Story.fromJson(
      jsonDecode(jsonEncode(story.toJson())) as Map<String, Object?>,
    );
    final dir = Directory.systemTemp.createTempSync('pinpoint_story_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lines = (await tester.runAsync(
      () => storyLines(sent, SourceLookup(dir)),
    ))!;
    final text = lines.join('\n');

    await pump(tester, sent);

    for (final label in ['tap "Fetch"', 'no cause recorded (f8)']) {
      expect(find.text(label), findsOneWidget);
      expect(text, contains(label));
    }
    for (final time in ['+1.24 s', '+3.00 s']) {
      expect(find.text(time), findsOneWidget);
      expect(text, contains(time));
    }
    for (final row in sent.blocks.expand((b) => b.rows)) {
      final headline = rowHeadline(row, storyName(row));
      expect(find.textContaining(headline), findsWidgets, reason: headline);
      expect(text, contains(headline));
    }
    expect(find.textContaining('+9.00 s  window ended'), findsOneWidget);
    expect(text, contains('+9.00 s  window ended'));
    expect(
      find.textContaining('CartModel.add() changed values'),
      findsOneWidget,
    );
    expect(text, contains('hint: CartModel.add() changed values'));
  });
}
