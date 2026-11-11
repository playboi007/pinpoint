// The command queue and the client hook are not public.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/src/bridge/command_queue.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';

/// The bridge's routes in memory for the example's widget tests: the app's
/// long poll reaches the real [CommandQueue] through a `MockClient` (the
/// widget binding fakes `HttpClient`). Notes routes answer empty.
class InMemoryBridge {
  InMemoryBridge() {
    BridgeClient.debugClient = MockClient(_handle);
  }

  final CommandQueue queue = CommandQueue();

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    switch ((request.method, path)) {
      case ('GET', '/commands'):
        final wait = int.tryParse(request.url.queryParameters['wait'] ?? '');
        return _json({
          'command': await queue.next(wait: Duration(seconds: wait ?? 25)),
        });
      case ('POST', '/commands/control'):
        final body = jsonDecode(request.body) as Map<String, Object?>;
        queue.setControl(body['enabled'] == true);
        return _json({'ok': true});
      case ('GET', '/annotations'):
        return _json({'cursor': '0', 'notes': <Object?>[]});
      case ('GET', '/changes'):
        return _json({'cursor': '0', 'reset': false, 'changes': <Object?>[]});
    }
    final result = RegExp(r'^/commands/([^/]+)/result$').firstMatch(path);
    if (request.method == 'POST' && result != null) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      queue.complete(result.group(1)!, body);
      return _json({'ok': true});
    }
    return _json({'error': 'Not found'}, 404);
  }

  /// Unmounts the app (which ends its poll), then the queue, and drops
  /// the client hook.
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    queue.close();
    await tester.pump(const Duration(seconds: 2));
    BridgeClient.debugClient = null;
  }

  static http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// Pumps until [future] completes. Each round also gives real time:
/// navigation answers outside the fake clock, and so do the bridge's file
/// writes and the screenshot.
Future<T> drive<T>(
  WidgetTester tester,
  Future<T> future, {
  int maxPumps = 600,
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
    if (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }
  if (!done) fail('the future did not complete in $maxPumps pumps');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}
