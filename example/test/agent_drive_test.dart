// The MCP server, the store and the agent tools are not public.
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/mcp_server.dart';
import 'package:pinpoint/src/bridge/note_store.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;
import 'package:pinpoint_example/main.dart';
import 'package:pinpoint_example/router_app.dart';

import 'agent_support.dart';

/// Milestone 12: the agent drives the example app.
///
/// "How to verify": a scripted MCP client (JSON-RPC straight into the
/// bridge's MCP server, no real agent) drives the example through
/// navigate, find, tap, enter text and verify, so the run is
/// deterministic.
void main() {
  late PinPointController controller;
  late InMemoryBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = InMemoryBridge();
  });
  tearDown(() => controller.dispose());

  Future<void> start(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(1000, 1400) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pump();
    controller.agent.enabled = true;
    await tester.pump();
  }

  Future<Map<String, Object?>> run(
    WidgetTester tester,
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    final answer = await drive(tester, bridge.queue.run(tool, args));
    expect(answer['ok'], isTrue, reason: '$tool: $answer');
    return answer['result']! as Map<String, Object?>;
  }

  testWidgets('acceptance: navigate works in the example with named routes', (
    tester,
  ) async {
    await start(tester, ExampleApp(controller: controller));
    final result = await run(tester, 'navigate', {'path': '/form'});
    expect(result['handled'], isTrue);
    expect(result['route'], '/form');
    expect(find.text('Form'), findsOneWidget);
    final back = await run(tester, 'back');
    expect(back['handled'], isTrue);
    expect(find.text('Pinpoint example'), findsOneWidget);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: navigate works in the example that uses a Router', (
    tester,
  ) async {
    await start(tester, RouterExampleApp(controller: controller));
    expect(find.text('Router example'), findsOneWidget);
    final result = await run(tester, 'navigate', {'path': '/settings'});
    expect(result['handled'], isTrue);
    expect(find.text('Settings'), findsOneWidget);
    final back = await run(tester, 'back');
    expect(back['handled'], isTrue);
    expect(find.text('The Settings page'), findsNothing);
    expect(find.text('Router example'), findsOneWidget);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: stress_matrix on the bug zoo screen reports the '
      'planted width-dependent overflow only at the narrow widths', (
    tester,
  ) async {
    await start(tester, ExampleApp(controller: controller));
    await run(tester, 'navigate', {'path': HomeScreen.bugZooRoute});
    final result = await run(tester, 'stress_matrix', {
      'kinds': ['overflow', 'truncated_text'],
      'thumbnails': false,
    });
    // The planted build error, and Flutter's own overflow reports.
    while (tester.takeException() != null) {}
    final runs = (result['runs']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(runs.take(4).map((r) => r['label']), [
      'width 320',
      'width 360',
      'width 414',
      'width 768',
    ]);
    final findings = (result['findings']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final overflow = findings.where((f) => f['kind'] == 'overflow').toList();
    // The Row overflows below 432 px wide: the first three widths only,
    // and no text scale, direction or brightness run at the window width.
    expect(overflow.single['runs'], [1, 2, 3]);
    expect(overflow.single['source'], contains('bug_zoo_screen.dart'));
    expect(result['drafts'], hasLength(1));
    expect(controller.environment.isActive, isFalse, reason: 'restored');
    await bridge.shutdown(tester);
  });

  testWidgets('a scripted MCP client drives the example: navigate, find, '
      'tap, enter text, verify', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('pinpoint_drive_'),
    ))!;
    addTearDown(() => root.deleteSync(recursive: true));
    final store = (await tester.runAsync(
      () => NoteStore.open(Directory('${root.path}/.pinpoint')),
    ))!;
    final mcp = McpServer(store, commands: bridge.queue);
    var id = 0;

    Future<Map<String, Object?>> rpc(
      String method, [
      Map<String, Object?>? params,
    ]) async {
      final answer = await drive(
        tester,
        mcp.handle({
          'jsonrpc': '2.0',
          'id': ++id,
          'method': method,
          'params': ?params,
        }),
      );
      final map = answer! as Map<String, Object?>;
      expect(map['error'], isNull, reason: '$map');
      return map['result']! as Map<String, Object?>;
    }

    Future<String> call(
      String name, [
      Map<String, Object?> args = const {},
    ]) async {
      final result = await rpc('tools/call', {'name': name, 'arguments': args});
      final text = [
        for (final c in result['content']! as List<Object?>)
          if (c case {'type': 'text', 'text': final String text}) text,
      ].join('\n');
      expect(result['isError'], isFalse, reason: '$name: $text');
      return text;
    }

    Map<String, Object?> json(String text) =>
        jsonDecode(text) as Map<String, Object?>;

    await start(tester, ExampleApp(controller: controller));
    await rpc('initialize', {'protocolVersion': '2025-06-18'});
    final tools = await rpc('tools/list');
    expect([
      for (final t in tools['tools']! as List<Object?>) (t! as Map)['name'],
    ], containsAll(['navigate', 'find_widgets', 'tap', 'enter_text']));

    // Navigate.
    expect(
      json(await call('navigate', {'path': '/counter'}))['handled'],
      isTrue,
    );
    // Find by text, then tap.
    final found = json(await call('find_widgets', {'text': 'Increment'}));
    final button = (found['widgets']! as List<Object?>).first! as Map;
    expect(button['source'], contains('lib/screens/counter_screen.dart'));
    await call('tap', {'handle': button['handle']});
    expect(find.text('count: 1'), findsOneWidget);
    // Enter text.
    final field = json(await call('find_widgets', {'type': 'TextField'}));
    final handle =
        ((field['widgets']! as List<Object?>).first! as Map)['handle'];
    final typed = json(
      await call('enter_text', {'handle': handle, 'text': 'hi'}),
    );
    expect(typed['text'], 'hi');
    expect(find.text('hi'), findsOneWidget);
    // The spinner never settles.
    expect(json(await call('wait_idle', {'timeout_ms': 300}))['idle'], isFalse);

    // Verify a note filed on the bug zoo's planted overflow at 360 wide.
    final lines = File('lib/screens/bug_zoo_screen.dart').readAsLinesSync();
    final rowLine = lines.indexWhere((l) => l.contains('const Row(')) + 1;
    await tester.runAsync(
      () => store.save({
        'schema': annotationSchema,
        'id': 'pp_zoo_row',
        'status': 'fixed',
        'createdAt': '2026-11-11T10:00:00.000Z',
        'intent': 'bug',
        'comment': 'The two boxes overflow on a phone',
        'page': {'route': '/bug-zoo'},
        'anchor': {
          'file': 'lib/screens/bug_zoo_screen.dart',
          'line': rowLine,
          'widget': 'Row',
          'route': '/bug-zoo',
        },
        'environment': {
          'viewport': {'width': 360, 'height': 800},
        },
        'checks': [
          {'type': 'no_overflow'},
        ],
      }, null),
    );
    final verified = await call('verify_note', {'id': 'pp_zoo_row'});
    expect(verified, contains('Checks failed (0 of 1 passed)'));
    expect(verified, contains('Row overflows by 72 px'));
    // The bug zoo plants a build error and an overflow: both reported by
    // Flutter while the note's route and viewport were on.
    var reported = 0;
    while (tester.takeException() != null) {
      reported++;
    }
    expect(reported, greaterThan(0));
    // Restored: no viewport, back on the counter screen.
    expect(controller.environment.isActive, isFalse);
    expect(find.text('count: 1'), findsOneWidget);
    final stored = (await tester.runAsync(() => store.read('pp_zoo_row')))!;
    expect((stored['verification']! as Map)['passed'], isFalse);
    await bridge.shutdown(tester);
  });
}
