import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/net_record.dart';
import 'package:pinpoint/src/trace/sources/message_source.dart';
import 'package:pinpoint/src/trace/trace_format.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 14, build step 5: `message` events on `window`, as
/// `input.message`. The web listener is tested in Chrome
/// (`test/trace/web/message_web_test.dart`); here the event itself.
void main() {
  tearDown(CauseZone.debugReset);

  test('a message gives input.message with its origin, size, hash and '
      'masked data', () {
    final recorder = TraceRecorder();
    final source = MessageSource(platformHooks: _NoHooks())..start(recorder);
    const raw = '{"type":"session","id_token":"abc.def","account":7}';
    source.record('https://admin.test', raw);
    final event = recorder.events.single;
    expect(event.kind, TraceKind.message);
    expect(event.data['origin'], 'https://admin.test');
    expect(event.data['size'], raw.length);
    final shown = event.data['data']! as String;
    expect(shown, isNot(contains('abc.def')));
    expect(jsonDecode(shown), {
      'type': 'session',
      'id_token': '***',
      'account': 7,
    });
    expect(event.data['hash'], NetHash.of(utf8.encode(shown)));
    expect(traceSummary(event), startsWith('from https://admin.test'));
  });

  test('the data is clipped to 2 KB', () {
    final recorder = TraceRecorder();
    final source = MessageSource(platformHooks: _NoHooks())..start(recorder);
    source.record('null', 'x' * 5000);
    final data = recorder.events.single.data;
    expect((data['data']! as String).length, lessThanOrEqualTo(2048));
    expect(data['size'], 5000);
  });

  test('each message is a cause of its own', () {
    final recorder = TraceRecorder();
    CauseZone().run(() {});
    final source = MessageSource(platformHooks: _NoHooks())..start(recorder);
    source
      ..record('a', '1')
      ..record('a', '2');
    final [first, second] = recorder.events.toList();
    expect(first.cause, isNotNull);
    expect(second.cause, isNot(first.cause));
    expect(recorder.causeOf(first.cause!)!.kind, CauseKind.message);
  });

  test('stopped: nothing is recorded and the listener is gone', () {
    final hooks = _NoHooks();
    final recorder = TraceRecorder();
    final source = MessageSource(platformHooks: hooks)..start(recorder);
    expect(hooks.listening, isTrue);
    source.stop();
    expect(hooks.listening, isFalse);
    source.record('a', '1');
    expect(recorder.events, isEmpty);
  });
}

class _NoHooks implements MessageHooks {
  bool listening = false;

  @override
  bool listen(void Function(String origin, String data) onMessage) =>
      listening = true;

  @override
  void cancel() => listening = false;
}
