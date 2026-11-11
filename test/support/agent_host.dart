import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/command_queue.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';

import 'fake_bridge.dart';

/// The bridge's command routes in memory, over the real [CommandQueue], for
/// widget tests: the widget binding fakes `HttpClient`, so the app's long
/// poll goes through a `MockClient`. Every other route is a [FakeBridge].
class AgentBridge {
  AgentBridge() {
    BridgeClient.debugClient = client;
  }

  static final Uri url = Uri.parse('http://127.0.0.1:4747');

  final CommandQueue queue = CommandQueue();
  final FakeBridge notes = FakeBridge();
  late final http.Client client = MockClient(_handle);

  /// Every command route request, as `METHOD /path`.
  final List<String> requests = <String>[];

  /// The control states the app reported.
  final List<bool> control = <bool>[];

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (!path.startsWith('/commands')) return notes.handle(request);
    requests.add('${request.method} $path');
    if (request.method == 'GET' && path == '/commands') {
      final wait = int.tryParse(request.url.queryParameters['wait'] ?? '');
      final command = await queue.next(
        wait: Duration(seconds: wait ?? 25),
      );
      return _json({'command': command});
    }
    if (request.method == 'POST' && path == '/commands/control') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final enabled = body['enabled'] == true;
      control.add(enabled);
      queue.setControl(enabled);
      return _json({'enabled': enabled});
    }
    final match = RegExp(r'^/commands/([^/]+)/result$').firstMatch(path);
    if (request.method == 'POST' && match != null) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      return queue.complete(match.group(1)!, body)
          ? _json({'ok': true})
          : _json({'error': 'No command'}, 404);
    }
    return _json({'error': 'Not found'}, 404);
  }

  /// Sends [tool] through the queue, as an MCP tool does, and pumps until
  /// the app answered.
  Future<Map<String, Object?>> call(
    WidgetTester tester,
    String tool, [
    Map<String, Object?> args = const {},
  ]) => drive(tester, queue.run(tool, args));

  /// Ends every poll and request, so no timer outlives the test.
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    queue.close();
    // Past the tap dots and the flash outline.
    await tester.pump(const Duration(seconds: 2));
    BridgeClient.debugClient = null;
  }

  static http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// Pumps 20 ms at a time until [future] completes, at most [maxPumps]
/// times. Driving commands wait for frames and short timers, which only a
/// pump moves on.
Future<T> drive<T>(
  WidgetTester tester,
  Future<T> future, {
  int maxPumps = 400,
  bool realTime = false,
}) async {
  var done = false;
  late T value;
  Object? error;
  StackTrace? stack;
  unawaited(
    future.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  for (var i = 0; i < maxPumps && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (realTime && !done) {
      // Image work (screenshots, the contrast capture) finishes only on
      // the real clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
  }
  if (!done) fail('the future did not complete in $maxPumps pumps');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}

/// An app under [PinPointWrapper] that uses [AgentBridge.url], with
/// [home] as its first screen.
Widget agentApp({
  required PinPointController controller,
  required Widget home,
  Map<String, WidgetBuilder> routes = const {},
  PinPointConfig? config,
}) => MaterialApp(
  routes: routes,
  builder: (context, child) => PinPointWrapper(
    controller: controller,
    config: config ?? PinPointConfig(bridgeUrl: AgentBridge.url),
    child: child,
  ),
  home: home,
);
