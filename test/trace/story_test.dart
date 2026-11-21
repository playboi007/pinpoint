import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/state_flow.dart';
import 'package:pinpoint/src/trace/story.dart';
import 'package:pinpoint/src/trace/story_builder.dart';
import 'package:pinpoint/src/trace/story_names.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v3 Milestone 21b: the plain-Dart story, one group of tests per row
/// of the plan's critique table. Events are made by hand, so no widget tree
/// is needed; `test/state/story_lens_test.dart` does the same from real
/// widgets.
void main() {
  late int now;
  late TraceRecorder recorder;
  var nextCause = 1;

  setUp(() {
    now = 0;
    recorder = TraceRecorder(clock: () => now);
  });
  tearDown(CauseZone.debugReset);

  TraceCause cause(String kind) =>
      TraceCause(nextCause++, kind, CauseZone.clockMs);

  void pointer(
    TraceCause c,
    String phase, {
    int id = 1,
    String? widget,
    String? label,
    String? by,
  }) => recorder.add(
    TraceKind.pointer,
    cause: c,
    widget: widget,
    data: {
      'phase': phase,
      'pointer': id,
      'x': 10,
      'y': 20,
      'label': ?label,
      'by': ?by,
    },
  );

  TraceEvent notify(
    TraceCause? c, {
    String owner = 'CartModel',
    String tag = '#a1',
    String? src,
    String? change,
    String? instance,
    String? method = 'CartModel.add',
    String? file = 'lib/cart.dart',
    int line = 10,
    String? detail,
    String via = 'provider',
  }) => recorder.add(
    TraceKind.stateNotify,
    cause: c,
    widget: owner,
    data: {
      'owner': owner,
      'tag': tag,
      'via': via,
      'file': ?file,
      'line': file == null ? null : line,
      'method': ?method,
      'src': ?src,
      'change': ?change,
      'instance': ?instance,
      'detail': ?detail,
      if (src != null) 'srcArg': 'valueListenable',
    },
  );

  TraceEvent setState(
    TraceCause? c, {
    String widget = '_CounterState',
    String method = '_CounterState.bump',
    String file = 'lib/counter.dart',
    int line = 20,
  }) => recorder.add(
    TraceKind.stateSetState,
    cause: c,
    widget: widget,
    data: {'file': file, 'line': line, 'method': method, 'watched': true},
  );

  Story build({
    StoryFilter filter = const StoryFilter(),
    List<FlowRebuild> rebuilds = const [],
    String? endedBecause,
    int? endedAt,
    List<StoryEnd> ends = const [],
  }) => StoryBuilder.build(
    recorder: recorder,
    fromSeq: 1,
    startT: 0,
    startWall: 1000000,
    rebuilds: rebuilds,
    filter: filter,
    endedBecause: endedBecause,
    endedAt: endedAt,
    ends: ends,
  );

  StoryBlock only(Story story) {
    expect(story.blocks, hasLength(1), reason: '${story.toJson()}');
    return story.blocks.single;
  }

  // ------------------------------------------------- the name ladder

  group('name ladder', () {
    StoryRow row(String owner, {String? src}) => StoryRow(
      kind: 'notify',
      owner: owner,
      src: src,
      srcArg: src == null ? null : 'valueListenable',
    );

    test('1: a class the app declared is its own name, expression or not', () {
      expect(
        storyName(row('CartModel'), expression: '_cart').text,
        'CartModel',
      );
      expect(storyName(row('CartModel<int>')).rung, 1);
      expect(storyName(row('CartModel<int>')).text, 'CartModel');
    });

    test('2: the expression read at the creating line, when it came', () {
      final name = storyName(
        row('ValueNotifier<bool>', src: 'lib/a.dart:4'),
        expression: '_focused',
      );
      expect((name.text, name.rung), ('_focused', 2));
    });

    test('3: a short type first; generics and records are cut', () {
      expect(
        storyName(row('ValueNotifier<({bool focused, bool open})>')).text,
        'ValueNotifier<(focused, open)>',
      );
      expect(storyName(row('ValueNotifier<bool>')).text, 'ValueNotifier<bool>');
      expect(
        shortType('ValueNotifier<(int, {String name, List<int> ids})>'),
        'ValueNotifier<(int, name, ids)>',
      );
      expect(
        shortType('ValueNotifier<Map<String, List<Map<String, Object?>>>>'),
        'ValueNotifier<…>',
      );
      expect(storyName(row('ValueNotifier<bool>')).rung, 3);
    });

    test('the expression is an identifier or a dotted path, nothing else', () {
      const source = '''
ValueListenableBuilder<bool>(
  valueListenable: widget.controller,
  builder: (context, v, _) => ValueListenableBuilder<int>(
    valueListenable: inner,
    builder: (context, v, _) => const SizedBox(),
  ),
)''';
      expect(
        expressionFromSource(source, 'valueListenable'),
        'widget.controller',
      );
      expect(
        expressionFromSource(
          'ListenableBuilder(listenable: this._items, builder: b)',
          'listenable',
        ),
        '_items',
      );
      for (final source in [
        'ListenableBuilder(listenable: items[0], builder: b)',
        'ListenableBuilder(listenable: make(), builder: b)',
        'ListenableBuilder(listenable: a ?? b, builder: b)',
        'ListenableBuilder(listenable: null, builder: b)',
        'ListenableBuilder(builder: b)',
        'Container(child: ListenableBuilder(builder: (c, _) => X(listenable: '
            'y), listenable: z))',
      ]) {
        final found = expressionFromSource(source, 'listenable');
        if (source.contains('listenable: z')) {
          // A nested argument is not the builder's own.
          expect(found, 'z');
        } else {
          expect(found, isNull, reason: source);
        }
      }
    });
  });

  // ------------------------------------------------- kinds of cause

  group('one block per cause, labelled by its kind', () {
    Future<void> tick(int ms) async => now += ms;

    test('tap: the pointer up of a down, with the widget and its text', () {
      final down = cause(CauseKind.pointer);
      pointer(down, 'down', widget: 'FetchButton', label: 'Fetch');
      final up = cause(CauseKind.pointer);
      pointer(up, 'up');
      notify(up);

      final block = only(build());
      expect(block.cause.kind, StoryKind.tap);
      expect(block.cause.label, 'tap "Fetch"');
      expect(block.cause.id, up.id);
      expect(block.id, 'c${up.id}');
    });

    test('tap with no text names the widget; press, drag, scroll', () {
      final down = cause(CauseKind.pointer);
      pointer(down, 'down', id: 7, widget: 'ProductCard');
      final press = cause(CauseKind.pointer);
      pointer(press, 'down', id: 8, widget: 'Other');
      notify(press, owner: 'A', tag: '#a1');
      final move = cause(CauseKind.pointer);
      pointer(move, 'move', id: 7);
      final up = cause(CauseKind.pointer);
      pointer(up, 'up', id: 7);
      notify(up, owner: 'B', tag: '#a2');
      final scroll = cause(CauseKind.pointer);
      pointer(scroll, 'scroll');
      notify(scroll, owner: 'C', tag: '#a3');

      final labels = build().blocks.map((b) => b.cause.label).toList();
      expect(labels, ['press Other', 'drag ProductCard', 'scroll']);
    });

    test('key and text input', () {
      final key = cause(CauseKind.key);
      recorder.add(
        TraceKind.key,
        cause: key,
        data: {'phase': 'down', 'key': 'Enter'},
      );
      notify(key, owner: 'A', tag: '#a1');
      final text = cause(CauseKind.other);
      recorder.add(TraceKind.text, cause: text, widget: 'EmailField');
      notify(text, owner: 'B', tag: '#a2');

      final blocks = build().blocks;
      expect(blocks[0].cause.label, 'key Enter');
      expect(blocks[0].cause.kind, StoryKind.key);
      expect(blocks[1].cause.label, 'typing in EmailField');
      expect(blocks[1].cause.kind, StoryKind.text);
      // The typed value is never in the label.
    });

    test('a timer or async callback: an entry no input names', () {
      notify(cause(CauseKind.other));
      final block = only(build());
      expect(block.cause.kind, StoryKind.timer);
      expect(block.cause.label, 'timer or async callback');
    });

    test('a network answer, a message, a route change', () {
      final net = cause(CauseKind.other);
      recorder.add(
        TraceKind.netResponse,
        cause: net,
        data: {'method': 'GET', 'url': 'https://api.test/items', 'status': 200},
      );
      notify(net, owner: 'A', tag: '#a1');
      final message = cause(CauseKind.message);
      recorder.add(
        TraceKind.message,
        cause: message,
        data: {'origin': 'https://host.test'},
      );
      notify(message, owner: 'B', tag: '#a2');
      final route = cause(CauseKind.pointer);
      recorder.add(
        TraceKind.route,
        cause: route,
        data: {'from': '/home', 'to': '/cart'},
      );
      notify(route, owner: 'C', tag: '#a3');

      final blocks = build().blocks;
      expect(blocks[0].cause.label, 'network answer GET api.test/items');
      expect(blocks[0].cause.kind, StoryKind.network);
      expect(blocks[1].cause.label, 'message from https://host.test');
      expect(blocks[2].cause.label, 'route change /home → /cart');
      expect(blocks[2].cause.kind, StoryKind.route);
    });

    test('a frame callback', () {
      notify(cause(CauseKind.frame));
      expect(only(build()).cause.label, 'frame callback');
      expect(only(build()).cause.kind, StoryKind.frame);
    });

    test('an agent command and an agent tap', () {
      final command = cause(CauseKind.agent);
      notify(command, owner: 'A', tag: '#a1');
      final down = cause(CauseKind.pointer);
      pointer(down, 'down', widget: 'FetchButton', label: 'Fetch', by: 'agent');
      final up = cause(CauseKind.pointer);
      pointer(up, 'up', by: 'agent');
      notify(up, owner: 'B', tag: '#a2');

      final blocks = build().blocks;
      expect(blocks[0].cause.label, 'agent command');
      expect(blocks[0].cause.kind, StoryKind.agent);
      expect(blocks[1].cause.label, 'agent tap "Fetch"');
      expect(blocks[1].cause.kind, StoryKind.agent);
    });

    test('a replayed tap', () {
      recorder.add(TraceKind.replayStart, data: {'tape': 't1'});
      final down = cause(CauseKind.pointer);
      pointer(down, 'down', widget: 'FetchButton', by: 'agent');
      final up = cause(CauseKind.pointer);
      pointer(up, 'up', by: 'agent');
      notify(up);

      final block = only(build());
      expect(block.cause.kind, StoryKind.replay);
      expect(block.cause.label, 'replayed tap FetchButton');
    });

    test('a change after an await keeps the tap and says "+420 ms"', () async {
      final down = cause(CauseKind.pointer);
      pointer(down, 'down', widget: 'FetchButton', label: 'Fetch');
      final up = cause(CauseKind.pointer);
      pointer(up, 'up');
      notify(up, owner: 'Loading', tag: '#a1');
      await tick(420);
      notify(up, owner: 'Items', tag: '#a2');

      final block = only(build());
      expect(block.cause.label, 'tap "Fetch"');
      expect(block.rows, hasLength(2));
      expect(block.rows[0].afterMs, isNull);
      expect(block.rows[1].afterMs, 420);
      expect(
        rowHeadline(block.rows[1], storyName(block.rows[1])),
        'Items +420 ms',
      );
    });

    test(
      'time is "+1.24 s" from the start; the clock is kept for the hover',
      () {
        now = 1240;
        final c = cause(CauseKind.other);
        notify(c);
        final block = only(build());
        expect(block.at, 1240);
        expect(blockTime(block), '+1.24 s');
        expect(block.wall, 1000000 + 1240);
        expect(formatAfterMs(420), '+420 ms');
      },
    );
  });

  // ------------------------------------------------- no PinPoint.run

  group('without PinPoint.run', () {
    test('changes group by frame, say "no cause recorded", and the top hint '
        'is given once', () {
      recorder.frameOf = () => 5;
      notify(null, owner: 'A', tag: '#a1');
      recorder.frameOf = () => 6;
      notify(null, owner: 'B', tag: '#a2');

      final story = build();

      expect(story.blocks.map((b) => b.id), ['f5', 'f6']);
      expect(story.blocks.first.cause.label, 'no cause recorded');
      expect(story.blocks.first.cause.kind, StoryKind.none);
      expect(story.blocks.first.frame, 5);
      expect(causeLine(story.blocks.first), 'no cause recorded (f5)');
      expect(story.noCauseHint, contains('PinPoint.run'));
    });

    test('"maybe after tap" only when a tap came in the 300 ms before', () {
      final down = cause(CauseKind.pointer);
      pointer(down, 'down', widget: 'FetchButton', label: 'Fetch');
      final up = cause(CauseKind.pointer);
      now = 1000;
      pointer(up, 'up');
      now = 1200;
      recorder.frameOf = () => 1;
      notify(null, owner: 'A', tag: '#a1');
      now = 2000;
      recorder.frameOf = () => 2;
      notify(null, owner: 'B', tag: '#a2');

      final blocks = build().blocks;

      expect(blocks[0].hint, 'maybe after tap "Fetch"');
      expect(blocks[1].hint, isNull);
    });

    test('with a cause zone there is no top hint', () {
      CauseZone().run(() {});
      notify(null);
      expect(build().noCauseHint, isNull);
    });
  });

  // ------------------------------------------------- hover, filters

  group('hover and the filter by cause kind', () {
    void hover(String name, {String? left, required String tag}) {
      final c = cause(CauseKind.pointer);
      recorder.add(
        TraceKind.pointer,
        cause: c,
        widget: name,
        data: {'phase': 'hover', 'left': ?left},
      );
      notify(c, owner: 'ValueNotifier<bool>', tag: tag, change: 'false → true');
    }

    test('a hover is named by the widget; a leave says "pointer left"', () {
      hover('Filters', tag: '#a1');
      final left = cause(CauseKind.pointer);
      recorder.add(
        TraceKind.pointer,
        cause: left,
        data: {'phase': 'hover', 'left': 'Filters'},
      );
      notify(left, owner: 'ValueNotifier<bool>', tag: '#a2');

      final story = build(filter: const StoryFilter(showHover: true));

      expect(story.blocks.map((b) => b.cause.label), [
        'hover Filters',
        'pointer left Filters',
      ]);
      expect(story.blocks.first.cause.kind, StoryKind.hover);
    });

    test('hover blocks are folded by default and counted; "show" brings '
        'them back', () {
      for (var i = 0; i < 4; i++) {
        hover('Row $i', tag: '#a$i');
      }
      final tap = cause(CauseKind.pointer);
      pointer(tap, 'up');
      notify(tap, owner: 'CartModel', tag: '#a9');

      final folded = build();
      expect(folded.hiddenHover, 4);
      expect(folded.blocks.single.cause.kind, StoryKind.tap);
      expect(hiddenLine(folded), '4 hover or focus changes hidden');

      final shown = build(filter: const StoryFilter(showHover: true));
      expect(shown.hiddenHover, 0);
      // Four hovers over different rows say the same: one block, "hover ×4".
      expect(shown.blocks.first.cause.label, 'hover');
      expect(shown.blocks.first.repeat, 4);
    });

    test('a pointer move that changed nothing named is "pointer move" '
        '(hover kind)', () {
      notify(cause(CauseKind.pointer));
      final block = only(build(filter: const StoryFilter(showHover: true)));
      expect(block.cause.label, 'pointer move');
      expect(block.cause.kind, StoryKind.hover);
    });

    test('a block that only moved focus is folded with the hover blocks', () {
      final c = cause(CauseKind.key);
      recorder.add(
        TraceKind.key,
        cause: c,
        data: {'phase': 'down', 'key': 'Tab'},
      );
      setState(c, widget: 'Focus');
      expect(build().hiddenHover, 1);
      expect(build().blocks, isEmpty);
      expect(
        build(filter: const StoryFilter(showHover: true)).blocks,
        hasLength(1),
      );
    });

    test(
      '"Only my state" hides owners outside the project and counts them',
      () {
        final c = cause(CauseKind.pointer);
        pointer(c, 'up');
        notify(c, owner: 'CartModel', tag: '#a1');
        // A framework holder with no creating line in the project.
        notify(c, owner: 'ValueNotifier<bool>', tag: '#a2', change: '1 → 2');
        // The same holder with its builder in the project is the app's state.
        notify(
          c,
          owner: 'ValueNotifier<int>',
          tag: '#a3',
          src: 'lib/a.dart:3',
          change: '1 → 2',
        );

        final all = build();
        expect(all.blocks.single.rows, hasLength(3));
        final mine = build(filter: const StoryFilter(onlyMine: true));
        expect(mine.blocks.single.rows.map((r) => r.owner), [
          'CartModel',
          'ValueNotifier<int>',
        ]);
        expect(mine.hiddenForeign, 1);
      },
    );
  });

  // ------------------------------------------------- grouping

  group('many instances of one notifier', () {
    test('20 list rows: one row "×N" with the variants and the instances', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      for (var i = 0; i < 12; i++) {
        notify(
          c,
          owner: 'ValueNotifier<({bool focused, bool open})>',
          tag: '#a${i + 1}',
          src: 'lib/list.dart:30',
          change: i < 3 ? 'focused false → true' : 'focused true → false',
          instance: i.isEven ? 'index $i' : null,
        );
      }

      final row = only(build()).rows.single;

      expect(row.count, 12);
      expect(row.instanceCount, 12);
      expect(row.instances, hasLength(maxStoryInstances));
      expect(row.instances.first.label, 'index 0');
      // No label: a position, never a made-up meaning.
      expect(row.instances[1].label, 'instance 2');
      expect(row.changes.map((c) => (c.text, c.count)).toList(), [
        ('focused false → true', 3),
        ('focused true → false', 9),
      ]);
      expect(
        changesText(row),
        'focused false → true (3), focused true → false (9)',
      );
      expect(
        rowHeadline(row, storyName(row, expression: '_value')),
        '_value (ValueNotifier<(focused, open)>) ×12',
      );
      expect(
        instancesText(row),
        startsWith('index 0: focused false → true; instance 2: '),
      );
    });

    test('instances of different types or creating lines are other rows', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      notify(c, owner: 'ValueNotifier<bool>', tag: '#a1', src: 'lib/a.dart:1');
      notify(c, owner: 'ValueNotifier<bool>', tag: '#a2', src: 'lib/b.dart:1');
      notify(c, owner: 'ValueNotifier<int>', tag: '#a3', src: 'lib/a.dart:1');
      expect(only(build()).rows, hasLength(3));
    });

    test('opposite changes in one block are two variants of one row, with '
        'no invented meaning', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      notify(c, owner: 'ValueNotifier<int>', tag: '#a1', change: '3 → 4');
      notify(c, owner: 'ValueNotifier<int>', tag: '#a2', change: '4 → 3');

      final row = only(build()).rows.single;
      expect(changesText(row), '3 → 4, 4 → 3');
      expect(row.verb, isNull);
    });
  });

  // ------------------------------------------------- controllers

  group('framework controllers', () {
    test('known controllers get a verb and no value', () {
      for (final MapEntry(:key, :value) in {
        'TextEditingController': 'text changed',
        'ScrollController': 'scrolled',
        'FocusNode': 'focus',
        'TabController': 'tab',
        'PageController': 'page',
        'AnimationController': 'animation',
        '_AnimatedEvaluation<double>': 'animation',
      }.entries) {
        expect(controllerVerb(key.split('<').first), value, reason: key);
      }
      expect(controllerVerb('CartModel'), isNull);
      expect(controllerVerb('ValueNotifier'), isNull);
    });

    test('their rows are folded by default and counted; "show" brings them '
        'back with the verb', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      notify(c, owner: 'CartModel', tag: '#a1');
      notify(c, owner: 'TextEditingController', tag: '#a2', detail: null);
      notify(c, owner: 'TabController', tag: '#a3', detail: 'index 2');

      final folded = build();
      expect(folded.blocks.single.rows.map((r) => r.owner), ['CartModel']);
      expect(folded.hiddenControllers, 2);
      expect(hiddenLine(folded), '2 controller changes hidden');

      final shown = build(filter: const StoryFilter(showControllers: true));
      final rows = shown.blocks.single.rows;
      expect(rows.map(verbText), ['', 'text changed', 'tab index 2']);
      expect(rows[1].mine, isFalse);
    });

    test('an animation run is one block "×N", not one per frame', () {
      for (var i = 0; i < 30; i++) {
        now = 1000 + i * 10;
        notify(
          cause(CauseKind.frame),
          owner: 'AnimationController',
          tag: '#a1',
        );
      }
      final shown = build(filter: const StoryFilter(showControllers: true));
      final block = only(shown);
      expect(block.repeat, 30);
      expect(blockTime(block), '+1.00 s … +1.29 s');
      expect(causeTitle(block), 'frame callback ×30');
      expect(build().blocks, isEmpty);
      expect(build().hiddenControllers, 30);
    });
  });

  // ------------------------------------------------- setState, hints

  group('setState-only stories and rebuilds', () {
    test('a setState row names its method and line', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      setState(c);
      final row = only(build()).rows.single;
      expect(row.kind, 'setState');
      expect(rowHeadline(row, storyName(row)), '_CounterState setState');
      expect(storyMethod(row.method), 'bump()');
      expect(storyWhere(row.file, row.line), 'lib/counter.dart:20');
    });

    test('the names never depend on the stack: a notify with no frame is '
        'still named', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      notify(c, file: null, method: null);
      final row = only(build()).rows.single;
      expect(row.file, isNull);
      expect(storyName(row).text, 'CartModel');
    });

    test('the widgets that rebuilt and the coupling hint, with no tag', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      final e = notify(c, owner: 'ProductModel', tag: '#a1');
      final join = FlowRebuild(
        frame: 1,
        eventSeqs: {e.seq},
        readers: const [
          FlowReader(
            type: 'ProductScreen',
            via: 'dependency',
            tag: '#a1',
            owner: 'ProductModel',
          ),
          FlowReader(
            type: 'FetchDialog',
            via: 'dependency',
            tag: '#a1',
            owner: 'ProductModel',
          ),
          FlowReader(type: 'Unrelated', via: 'dependency', tag: '#a9'),
        ],
      );

      final block = only(build(rebuilds: [join]));

      expect(block.rebuilt, ['ProductScreen', 'FetchDialog']);
      expect(block.rebuiltCount, 2);
      expect(block.hint, contains('widgets read'));
      expect(block.hint, contains('read the same'));
      // Plain words: no internal shape numbers reach the user.
      expect(block.hint, isNot(contains('shape')));
      expect(block.hint, isNot(contains('#a')));
    });
  });

  // ------------------------------------------------- caps, ends, json

  group('caps, end lines and the JSON the bridge reads', () {
    test('only the last 60 blocks stay; the rest are counted', () {
      for (var i = 0; i < 75; i++) {
        now = i * 100;
        final c = cause(CauseKind.pointer);
        pointer(c, 'up', widget: 'Tile$i');
        notify(c, owner: 'M$i', tag: '#a$i');
      }
      final story = build();
      expect(story.blocks, hasLength(maxStoryBlocks));
      expect(story.droppedBlocks, 15);
      expect(story.blocks.last.cause.label, startsWith('tap'));
      expect(story.blocks.first.at, 1500);
    });

    test('at most 12 rows a block; the rest are counted', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up');
      for (var i = 0; i < 15; i++) {
        notify(c, owner: 'Model$i', tag: '#a$i');
      }
      final block = only(build());
      expect(block.rows, hasLength(maxStoryRows));
      expect(block.droppedRows, 3);
    });

    test('blocks that repeat fold into "×N" with the first and last time', () {
      for (var i = 0; i < 5; i++) {
        now = 1000 + i * 100;
        final c = cause(CauseKind.pointer);
        pointer(c, 'up', widget: 'Plus');
        notify(c, owner: 'Counter', tag: '#a1', change: '1 → 2');
      }
      final block = only(build());
      expect(block.repeat, 5);
      expect(block.at, 1000);
      expect(block.lastAt, 1400);
      expect(causeTitle(block), 'tap Plus ×5');
    });

    test('dropped setState stacks are counted', () {
      recorder.add(TraceKind.stateDropped, data: {'n': 9});
      notify(cause(CauseKind.other));
      expect(build().droppedStacks, 9);
    });

    test('end lines: window ended, target left, hot reload, in time order', () {
      now = 500;
      notify(cause(CauseKind.other));

      final ended = build(
        endedBecause: 'window ended',
        endedAt: 30000,
        ends: const [StoryEnd(200, 'hot reload')],
      );
      expect(ended.ends.map((e) => e.text), ['hot reload', 'window ended']);
      expect(ended.timeline.first, isA<StoryEnd>());
      expect(ended.timeline[1], isA<StoryBlock>());
      expect(ended.ends.last.at, 30000);

      expect(
        build(endedBecause: 'target unmounted', endedAt: 900).ends.single.text,
        'target left the screen',
      );
      expect(build().ends, isEmpty);
    });

    test('the story survives JSON: the bridge reads what the app sent', () {
      final c = cause(CauseKind.pointer);
      pointer(c, 'up', widget: 'Plus', label: 'Add');
      notify(
        c,
        owner: 'ValueNotifier<bool>',
        tag: '#a1',
        src: 'lib/a.dart:1',
        change: 'false → true',
        instance: 'index 1',
      );
      notify(
        c,
        owner: 'ValueNotifier<bool>',
        tag: '#a2',
        src: 'lib/a.dart:1',
        change: 'false → true',
      );
      setState(c);
      final story = build(endedBecause: 'stopped', endedAt: 700);

      final copy = Story.fromJson(
        jsonDecode(jsonEncode(story.toJson())) as Map<String, Object?>,
      );

      expect(jsonEncode(copy.toJson()), jsonEncode(story.toJson()));
      expect(copy.blocks.single.rows.first.instanceCount, 2);
      expect(copy.ends.single.text, 'stopped');
      expect(Story.fromJson('junk').blocks, isEmpty);
    });
  });
}
