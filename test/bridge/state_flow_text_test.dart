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
  const notify = {
    'seq': 12,
    'owner': 'ProductDetailProvider',
    'tag': '#a1',
    'via': 'provider',
    'file': 'package:my_app/providers/product_detail_provider.dart',
    'line': 11,
    'method': 'ProductDetailProvider.fetchDialog',
  };
  const shape1 = {
    'cause': 41,
    'kind': 'pointer',
    'entry': 'input.pointer up ElevatedButton (lib/screens/detail.dart:60)',
    'frame': 9,
    't': 1200,
    'notifies': [notify],
    'setStates': <Object?>[],
    'rebuilt': [
      {
        'type': 'ProductDetailScreen',
        'via': 'dependency',
        'tag': '#a1',
        'owner': 'ProductDetailProvider',
      },
      {
        'type': '_FetchDialog',
        'via': 'dependency',
        'tag': '#a1',
        'owner': 'ProductDetailProvider',
      },
    ],
    'hint':
        'shape 1: ProductDetailProvider (ProductDetailProvider.fetchDialog) '
        'notified once and 2 readers rebuilt: one method changed the values '
        'both read; shape 3: ProductDetailScreen and _FetchDialog read the '
        'same object ProductDetailProvider #a1',
  };

  Map<String, Object?> answer({
    bool armedNow = false,
    bool armed = true,
    List<Object?> causes = const [shape1],
    Map<String, Object?> extra = const {},
  }) => {
    'armedNow': armedNow,
    'armed': armed,
    'target': {'type': 'ProductDetailScreen', 'source': 'lib/x.dart:40'},
    'seconds': 30,
    'secondsLeft': 22,
    'readers': readers,
    'events': causes.length,
    'causes': causes,
    ...extra,
  };

  test('the chain: cause, notify with its line, the code under it, the '
      'readers that rebuilt, the hint', () async {
    final text = await stateFlowText(answer(), lookup);

    expect(text, startsWith('state_flow ProductDetailScreen (lib/x.dart:40)'));
    expect(text, contains('Chain since arming (22 s left):'));
    expect(
      text,
      contains(
        'input.pointer up ElevatedButton (lib/screens/detail.dart:60) '
        '(cause c41)',
      ),
    );
    expect(
      text,
      contains(
        ' └ ProductDetailProvider #a1 notified   fetchDialog()  '
        'lib/providers/product_detail_provider.dart:11',
      ),
    );
    // The lines up to the notify, the comment left out.
    expect(
      text,
      contains(
        'code:  void fetchDialog() { _dialogLoading = true; _loading = true; '
        'notifyListeners();',
      ),
    );
    expect(text, contains(' └ rebuilt because they read it:'));
    expect(
      text,
      contains(
        'ProductDetailScreen   (dependencies: ProductDetailProvider #a1)'
        '   <- same object',
      ),
    );
    expect(
      text,
      contains(
        '_FetchDialog          (dependencies: ProductDetailProvider #a1)'
        '   <- same object',
      ),
    );
    expect(text, contains(' hint: shape 1: ProductDetailProvider'));
    expect(text, contains('shape 3: ProductDetailScreen and _FetchDialog'));
    expect(
      text,
      contains(
        'Declared: ProductDetailProvider '
        'lib/providers/product_detail_provider.dart:3',
      ),
    );
    expect(text.length, lessThan(stateFlowMaxChars));
  });

  test('the first call: what the widget reads, with tags, creating lines '
      'and declarations; then "act now"', () async {
    final text = await stateFlowText(
      answer(armedNow: true, causes: const []),
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
    // No chain yet.
    expect(text, isNot(contains('Chain since arming')));
  });

  test('armed with no change, and a window that ended with none', () async {
    final waiting = await stateFlowText(answer(causes: const []), lookup);
    expect(waiting, contains('No state change yet (22 s left).'));
    expect(waiting, contains('call state_flow again'));

    final ended = await stateFlowText(
      answer(armed: false, causes: const [], extra: {'ended': 'window ended'}),
      lookup,
    );
    expect(ended, contains('The window ended (window ended) with no state'));
    expect(ended, contains('rearm: true'));
  });

  test('a setState shows its line and code; a cause with no recorded id '
      'says so; notes and drops are listed', () async {
    final text = await stateFlowText(
      answer(
        causes: [
          {
            'frame': 7,
            'notifies': <Object?>[],
            'setStates': [
              {
                'seq': 3,
                'widget': '_FetchDialog',
                'file': 'package:my_app/providers/product_detail_provider.dart',
                'line': 11,
                'method': '_FetchDialogState._onTap',
              },
            ],
            'rebuilt': [
              {'type': '_FetchDialog', 'via': 'setState'},
            ],
          },
        ],
        extra: {
          'dropped': 4,
          'notes': ['no causes: wrap runApp in PinPoint.run'],
        },
      ),
      lookup,
    );

    expect(text, contains('a change in frame f7 (no cause recorded)'));
    expect(
      text,
      contains(' └ _FetchDialog setState   _onTap()  lib/providers/'),
    );
    expect(text, contains('(its own setState)'));
    expect(text, contains('Note: 4 setState stacks were dropped'));
    expect(text, contains('Note: no causes: wrap runApp in PinPoint.run'));
  });

  test(
    '"no rebuilt reader" is said for a notify, not for a setState',
    () async {
      Map<String, Object?> cause({required bool notify}) => {
        'frame': 9,
        'notifies': [
          if (notify)
            {
              'seq': 1,
              'owner': 'ProductModel',
              'tag': '#a1',
              'file': 'package:my_app/providers/product_detail_provider.dart',
              'line': 11,
            },
        ],
        'setStates': [
          if (!notify)
            {
              'seq': 2,
              'widget': '_FetchDialog',
              'file': 'package:my_app/providers/product_detail_provider.dart',
              'line': 11,
            },
        ],
        'rebuilt': <Object?>[],
      };
      final notified = await stateFlowText(
        answer(causes: [cause(notify: true)]),
        lookup,
      );
      final setState = await stateFlowText(
        answer(causes: [cause(notify: false)]),
        lookup,
      );
      expect(notified, contains('no rebuilt reader seen for it'));
      expect(setState, isNot(contains('no rebuilt reader seen for it')));
    },
  );

  test('a frame outside the project shows no code, never throws', () async {
    final text = await stateFlowText(
      answer(
        causes: [
          {
            ...shape1,
            'notifies': [
              {...notify, 'file': '/etc/passwd.dart', 'line': 1},
            ],
          },
        ],
      ),
      lookup,
    );
    expect(text, contains('notified   fetchDialog()  /etc/passwd.dart:1'));
    expect(text, isNot(contains('code:')));
  });

  test('the answer is cut to about 4 KB; the newest causes stay', () async {
    final many = [
      for (var i = 0; i < 12; i++)
        {...shape1, 'cause': 100 + i, 'hint': 'hint number $i ${'x' * 150}'},
    ];
    final text = await stateFlowText(answer(causes: many), lookup);

    expect(text.length, lessThanOrEqualTo(stateFlowMaxChars));
    expect(text, contains('(cause c111)'));
    expect(text, isNot(contains('(cause c100)')));
    expect(text, contains('earlier causes not shown'));
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
    expect(text, contains('notified   fetchDialog()'));
    expect(text, contains('code:  void fetchDialog()'));
    expect(text, contains('<- same object'));
  });
}
