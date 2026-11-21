import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/source_lookup.dart';
import 'package:pinpoint/src/bridge/state_flow_text.dart';

/// PLAN-v3 Milestone 21, build step 8: the text of `state_flow`, from the
/// answer the app sends and the project's own source. Plain `test`: the
/// bridge part uses real sockets (the widget binding fakes `HttpClient`).
void main() {
  late Directory project;
  late SourceLookup lookup;

  const provider = '''
import 'package:flutter/foundation.dart';

class ProductDetailProvider extends ChangeNotifier {
  bool _loading = false;
  bool _dialogLoading = false;

  void fetchDialog() {
    // both flags, one notify
    _dialogLoading = true;
    _loading = true;
    notifyListeners();
  }
}

class ProductDetailScreen {}
class _FetchDialog {}
''';

  setUp(() async {
    project = await Directory.systemTemp.createTemp('pinpoint_flow_');
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: my_app\n');
    Directory('${project.path}/lib/providers').createSync(recursive: true);
    File(
      '${project.path}/lib/providers/product_detail_provider.dart',
    ).writeAsStringSync(provider);
    lookup = SourceLookup(project);
  });
  tearDown(() => project.delete(recursive: true));

  const dependency = {
    'kind': 'provider',
    'type': 'ProductDetailProvider',
    'tag': '#a1',
    'source': {'file': 'lib/main.dart', 'line': 20, 'column': 5},
  };
  const readers = [
    {
      'kind': 'reader',
      'type': 'ProductDetailScreen',
      'source': {'file': 'lib/screens/detail.dart', 'line': 40, 'column': 3},
      'dependencies': [dependency],
    },
  ];
  const notifyRow = {
    'kind': 'notify',
    'owner': 'ProductDetailProvider',
    'tag': '#a1',
    'src': 'lib/main.dart:20',
    'file': 'package:my_app/providers/product_detail_provider.dart',
    'line': 11,
    'method': 'ProductDetailProvider.fetchDialog',
  };
  const shape1 = {
    'id': 'c41',
    'at': 1240,
    'cause': {'kind': 'tap', 'label': 'tap "Fetch"', 'id': 41},
    'rows': [notifyRow],
    'rebuilt': ['ProductDetailScreen', '_FetchDialog'],
    'rebuiltCount': 2,
    'hint':
        'ProductDetailProvider.fetchDialog() changed values that 2 widgets '
        'read; ProductDetailScreen and _FetchDialog read the '
        'same object ProductDetailProvider',
  };

  Map<String, Object?> story({
    List<Object?> blocks = const [shape1],
    List<Object?> ends = const [],
    Map<String, Object?> extra = const {},
  }) => {'blocks': blocks, 'ends': ends, ...extra};

  Map<String, Object?> answer({
    bool armedNow = false,
    bool armed = true,
    List<Object?> blocks = const [shape1],
    Map<String, Object?> extra = const {},
    Map<String, Object?> storyExtra = const {},
    List<Object?> ends = const [],
  }) => {
    'armedNow': armedNow,
    'armed': armed,
    'target': {'type': 'ProductDetailScreen', 'source': 'lib/x.dart:40'},
    'seconds': 30,
    'secondsLeft': 22,
    'readers': readers,
    'story': story(blocks: blocks, ends: ends, extra: storyExtra),
    ...extra,
  };

  test('the story: time, cause, the class, the method and its line, the '
      'code under it, the widgets that rebuilt, the hint', () async {
    final text = await stateFlowText(answer(), lookup);

    expect(text, startsWith('state_flow ProductDetailScreen (lib/x.dart:40)'));
    expect(text, contains('Story since arming, oldest first (22 s left):'));
    expect(text, contains('+1.24 s  tap "Fetch"'));
    expect(
      text,
      contains(
        ' └ ProductDetailProvider   fetchDialog()  '
        'lib/providers/product_detail_provider.dart:11',
      ),
    );
    expect(
      text,
      contains(
        'code:  void fetchDialog() { _dialogLoading = true; '
        '_loading = true; notifyListeners();',
      ),
    );
    expect(text, contains(' └ rebuilt 2: ProductDetailScreen, _FetchDialog'));
    expect(
      text,
      contains('hint: ProductDetailProvider.fetchDialog() changed values'),
    );
    expect(text, contains('Declared: ProductDetailProvider '));
    // The identity tag is for grouping: never in the story.
    expect(text, isNot(contains('#a')));
    expect(text.length, lessThan(stateFlowMaxChars));
  });

  test('the first call: what the widget reads, with tags, creating lines '
      'and declarations; then "act now"', () async {
    final text = await stateFlowText(
      answer(armedNow: true, blocks: const []),
      lookup,
    );

    expect(
      text,
      contains(
        'Armed for 30 s: act now (run_steps), then call state_flow again.',
      ),
    );
    expect(text, contains('Reads:'));
    expect(
      text,
      contains('  ProductDetailScreen (reader, lib/screens/detail.dart:40)'),
    );
    expect(
      text,
      contains(
        '    ProductDetailProvider #a1 (provider, made at lib/main.dart:20, '
        'class at lib/providers/product_detail_provider.dart:3)',
      ),
    );
    // No story yet.
    expect(text, isNot(contains('Story since arming')));
  });

  test('armed with no change, and a window that ended with none', () async {
    final waiting = await stateFlowText(answer(blocks: const []), lookup);
    expect(waiting, contains('No state change yet (22 s left).'));
    expect(waiting, contains('call state_flow again'));

    final ended = await stateFlowText(
      answer(armed: false, blocks: const [], extra: {'ended': 'window ended'}),
      lookup,
    );
    expect(ended, contains('The window ended (window ended) with no state'));
    expect(ended, contains('rearm: true'));
  });

  test('a setState-only story is readable: the method, its line, the code; '
      'a change with no cause says so, with the "maybe after" hint, once at '
      'the top; notes and drops are listed', () async {
    final text = await stateFlowText(
      answer(
        blocks: [
          {
            'id': 'f7',
            'at': 800,
            'frame': 7,
            'cause': {'kind': 'none', 'label': 'no cause recorded'},
            'hint': 'maybe after tap "Fetch"',
            'rows': [
              {
                'kind': 'setState',
                'owner': '_FetchDialog',
                'file': 'package:my_app/providers/product_detail_provider.dart',
                'line': 11,
                'method': '_FetchDialogState._onTap',
              },
            ],
            'rebuilt': ['_FetchDialog'],
            'rebuiltCount': 1,
          },
        ],
        storyExtra: {
          'droppedStacks': 4,
          'noCauseHint': 'Changes have no cause: PinPoint.run gives causes.',
        },
        extra: {
          'notes': ['no causes: wrap runApp in PinPoint.run'],
        },
      ),
      lookup,
    );

    expect(text, contains('Changes have no cause: PinPoint.run gives causes.'));
    expect(text, contains('+0.80 s  no cause recorded (f7)'));
    expect(
      text,
      contains(' └ _FetchDialog setState   _onTap()  lib/providers/'),
    );
    expect(text, contains('code:'));
    expect(text, contains('hint: maybe after tap "Fetch"'));
    expect(text, contains('Note: 4 setState stacks were dropped'));
    expect(text, contains('Note: no causes: wrap runApp in PinPoint.run'));
  });

  test(
    '"no rebuilt widget" is said for a notify, not for a setState',
    () async {
      Map<String, Object?> block({required bool notify}) => {
        'id': 'f9',
        'at': 1,
        'cause': {'kind': 'none', 'label': 'no cause recorded'},
        'rows': [
          if (notify) notifyRow,
          if (!notify)
            {
              'kind': 'setState',
              'owner': '_FetchDialog',
              'file': 'package:my_app/providers/product_detail_provider.dart',
              'line': 11,
            },
        ],
      };
      final notified = await stateFlowText(
        answer(blocks: [block(notify: true)]),
        lookup,
      );
      final setState = await stateFlowText(
        answer(blocks: [block(notify: false)]),
        lookup,
      );
      expect(notified, contains('no rebuilt widget seen for it'));
      expect(setState, isNot(contains('no rebuilt widget seen for it')));
    },
  );

  test('a frame outside the project shows no code, never throws', () async {
    final text = await stateFlowText(
      answer(
        blocks: [
          {
            ...shape1,
            'rows': [
              {...notifyRow, 'file': '/etc/passwd.dart', 'line': 1},
            ],
          },
        ],
      ),
      lookup,
    );
    expect(text, contains('fetchDialog()  /etc/passwd.dart:1'));
    expect(text, isNot(contains('code:')));
  });

  group('the name ladder (rung 2: read from the creating line)', () {
    const builder = """
import 'package:flutter/widgets.dart';

class Filters extends StatelessWidget {
  const Filters({super.key, required this.model});
  final Model model;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ValueListenableBuilder<({bool focused, bool open})>(
          valueListenable: _focused,
          builder: (context, value, _) => ValueListenableBuilder<int>(
            valueListenable: other,
            builder: (context, v, _) => Text('\$v'),
          ),
        ),
        ListenableBuilder(
          listenable: model.items[0],
          builder: (context, _) => const SizedBox(),
        ),
      ],
    );
  }
}
""";

    Map<String, Object?> row(Map<String, Object?> extra) => {
      'kind': 'notify',
      'owner': 'ValueNotifier<({bool focused, bool open})>',
      'src': 'lib/screens/filters.dart:11',
      'srcArg': 'valueListenable',
      'hasValue': true,
      'count': 12,
      'changes': [
        {'text': 'focused false → true', 'count': 3},
        {'text': 'true → false', 'count': 9},
      ],
      ...extra,
    };

    Future<String> textOf(Map<String, Object?> r) => stateFlowText(
      answer(
        blocks: [
          {
            'id': 'c1',
            'at': 10,
            'cause': {'kind': 'tap', 'label': 'tap Filters', 'id': 1},
            'rows': [r],
          },
        ],
      ),
      lookup,
    );

    test(
      'the outer builder argument is read; the short type is kept',
      () async {
        Directory('${project.path}/lib/screens').createSync(recursive: true);
        File(
          '${project.path}/lib/screens/filters.dart',
        ).writeAsStringSync(builder);

        final text = await textOf(row({}));

        expect(
          text,
          contains(
            ' └ _focused (ValueNotifier<(focused, open)>) ×12  '
            'focused false → true (3), true → false (9)',
          ),
        );
      },
    );

    test('an index or a call is no name: the short type stays', () async {
      Directory('${project.path}/lib/screens').createSync(recursive: true);
      File(
        '${project.path}/lib/screens/filters.dart',
      ).writeAsStringSync(builder);

      final text = await textOf(row({'src': 'lib/screens/filters.dart:18'}));

      expect(text, contains(' └ ValueNotifier<(focused, open)> ×12'));
      expect(text, isNot(contains('model.items')));
    });

    test('a missing file never blocks or throws', () async {
      final text = await textOf(row({'src': 'lib/gone.dart:3'}));
      expect(text, contains(' └ ValueNotifier<(focused, open)> ×12'));
    });

    test('a class of the app is named by its class, with no lookup', () async {
      final text = await textOf(row({'owner': 'CartModel', 'src': null}));
      expect(text, contains(' └ CartModel ×12'));
    });

    test('many instances: one row with ×N and the instance labels', () async {
      final text = await textOf(
        row({
          'src': null,
          'instanceCount': 14,
          'instances': [
            for (var i = 0; i < 12; i++)
              {'label': 'index $i', 'change': 'false → true'},
          ],
        }),
      );
      expect(text, contains('     instances: index 0: false → true; '));
      expect(text, contains('(+2 more)'));
    });
  });

  test('hidden changes are counted with the way to show them; end lines '
      'sit in time order', () async {
    final text = await stateFlowText(
      answer(
        blocks: [shape1],
        ends: [
          {'at': 900, 'text': 'hot reload'},
          {'at': 30000, 'text': 'window ended'},
        ],
        storyExtra: {
          'hiddenHover': 4,
          'hiddenControllers': 1,
          'droppedBlocks': 7,
        },
      ),
      lookup,
    );
    final lines = text.split('\n');
    expect(
      lines.indexWhere((l) => l.contains('+0.90 s  hot reload')),
      lessThan(lines.indexWhere((l) => l.contains('+1.24 s  tap'))),
    );
    expect(text, contains('+30.00 s  window ended'));
    expect(text, contains('(7 earlier blocks not shown)'));
    expect(
      text,
      contains(
        'Hidden: 4 hover or focus changes hidden, 1 controller change hidden. '
        'Call state_flow with hover: true or controllers: true',
      ),
    );
  });

  test('a block that repeats shows its count and span', () async {
    final text = await stateFlowText(
      answer(
        blocks: [
          {
            ...shape1,
            'repeat': 20,
            'lastAt': 4200,
            'cause': {'kind': 'hover', 'label': 'hover'},
          },
        ],
      ),
      lookup,
    );
    expect(text, contains('+1.24 s … +4.20 s  hover ×20'));
  });

  test('the answer is cut to about 4 KB; the newest blocks stay', () async {
    final many = [
      for (var i = 0; i < 12; i++)
        {
          ...shape1,
          'id': 'c${100 + i}',
          'at': 1000 + i,
          'cause': {'kind': 'tap', 'label': 'tap number $i', 'id': 100 + i},
          'hint': 'hint number $i ${'x' * 150}',
        },
    ];
    final text = await stateFlowText(answer(blocks: many), lookup);

    expect(text.length, lessThanOrEqualTo(stateFlowMaxChars));
    expect(text, contains('tap number 11'));
    expect(text, isNot(contains('tap number 0\n')));
    expect(text, contains('earlier blocks not shown'));
  });

  test('over MCP: queued, answered by the app, and shown as text with the '
      'code of the project', () async {
    final bridge = await PinPointBridge.start(
      dir: '${project.path}/.pinpoint',
      port: 0,
    );
    addTearDown(bridge.close);
    Future<Object?> send(String method, String path, [Object? body]) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${bridge.port}$path'),
        );
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final text = await utf8.decodeStream(response);
        return text.isEmpty ? null : jsonDecode(text);
      } finally {
        client.close(force: true);
      }
    }

    // Control on, and an app that answers the one command.
    await send('POST', '/commands/control', {'enabled': true});
    final app = () async {
      final polled = await send('GET', '/commands?wait=5');
      final command =
          (polled! as Map<String, Object?>)['command']! as Map<String, Object?>;
      await send('POST', '/commands/${command['id']}/result', {
        'ok': true,
        'result': answer(),
      });
      return command;
    }();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final reply =
        await send('POST', '/mcp', {
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'state_flow',
                'arguments': {
                  'target': {'type': 'ProductDetailScreen'},
                },
              },
            })
            as Map<String, Object?>;

    final command = await app;
    expect(command['tool'], 'state_flow');
    final result = reply['result']! as Map<String, Object?>;
    expect(result['isError'], isFalse);
    final text =
        ((result['content']! as List).first as Map<String, Object?>)['text']!
            as String;
    expect(text, contains('ProductDetailProvider   fetchDialog()'));
    expect(text, contains('code:  void fetchDialog()'));
    expect(text, contains('rebuilt 2: ProductDetailScreen, _FetchDialog'));
  });
}
