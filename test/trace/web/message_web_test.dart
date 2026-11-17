@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/sources/message_source.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 14, build step 5, in Chrome. Also answers a "Verify
/// by running" box: a `MessageEvent` made in script reaches the app's own
/// listener with the origin Pinpoint recorded.
void main() {
  tearDown(CauseZone.debugReset);

  test("a window message is recorded with the origin the app's listener "
      'sees, and its token is masked', () async {
    final recorder = TraceRecorder();
    CauseZone().run(() {});
    final source = MessageSource()..start(recorder);
    addTearDown(source.stop);
    final app = Completer<String>();
    final listener = ((JSObject event) {
      if (!app.isCompleted) app.complete((event['origin']! as JSString).toDart);
    }).toJS;
    globalContext.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'message'.toJS,
      listener,
    );
    addTearDown(
      () => globalContext.callMethod<JSAny?>(
        'removeEventListener'.toJS,
        'message'.toJS,
        listener,
      ),
    );
    globalContext.callMethod<JSAny?>(
      'postMessage'.toJS,
      {'type': 'session', 'token': 'T0K'}.jsify(),
      '*'.toJS,
    );
    final origin = await app.future;
    for (var i = 0; i < 50 && recorder.length == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final event = recorder.events.single;
    expect(event.kind, TraceKind.message);
    expect(event.data['origin'], origin);
    expect(jsonDecode(event.data['data']! as String), {
      'type': 'session',
      'token': '***',
    });
    expect(recorder.causeOf(event.cause!)!.kind, CauseKind.message);
  });

  test('stop removes the listener', () async {
    final recorder = TraceRecorder();
    MessageSource()
      ..start(recorder)
      ..stop();
    globalContext.callMethod<JSAny?>('postMessage'.toJS, 'x'.toJS, '*'.toJS);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(recorder.events, isEmpty);
  });
}
