import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/net_record.dart';
import 'package:pinpoint/src/trace/redact.dart';
import 'package:pinpoint/src/trace/trace_format.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 14, build step 4: secrets are masked when recorded,
/// not when shown (rule 16), and Pinpoint never records itself (rule 14).
void main() {
  tearDown(CauseZone.debugReset);

  group('TraceRedact', () {
    const redact = TraceRedact();

    test('the defaults mask authorization, cookies, and any name with token, '
        'key or secret in it', () {
      for (final name in [
        'Authorization',
        'cookie',
        'Set-Cookie',
        'x-api-key',
        'X-Auth-Token',
        'id_token',
        'client_secret',
      ]) {
        expect(redact.masks(name), isTrue, reason: name);
      }
      for (final name in ['content-type', 'accept', 'page', 'q']) {
        expect(redact.masks(name), isFalse, reason: name);
      }
    });

    test('a URL keeps its shape; masked parameters and user info lose '
        'their values', () {
      expect(
        redact.url('https://u:pw@api.test/a?page=2&api_key=abc&token=x#top'),
        'https://***@api.test/a?page=2&api_key=***&token=***',
      );
      expect(redact.url('/existing?type=faq'), '/existing?type=faq');
      expect(redact.url('not a url %%'), 'not a url %%');
    });

    test('headers keep their names', () {
      expect(redact.headers({'Authorization': 'Bearer s3cret', 'a': 'b'}), {
        'Authorization': '***',
        'a': 'b',
      });
    });

    test('an app list replaces the defaults; names are case-blind', () {
      const own = TraceRedact(['X-Session', '*pass*']);
      expect(own.masks('x-session'), isTrue);
      expect(own.masks('password'), isTrue);
      expect(own.masks('authorization'), isFalse);
    });

    test('JSON values under masked keys are masked at any depth', () {
      expect(
        redact.json({
          'user': 'ann',
          'auth': {
            'id_token': 'abc',
            'scopes': ['a'],
          },
          'list': [
            {'secret': 1},
          ],
        }),
        {
          'user': 'ann',
          'auth': {
            'id_token': '***',
            'scopes': ['a'],
          },
          'list': [
            {'secret': '***'},
          ],
        },
      );
    });
  });

  group('network', () {
    test('acceptance: an Authorization header never appears in an event or '
        'a tool answer', () {
      final recorder = TraceRecorder();
      final net = NetRecorder(recorder);
      final call = net.request(
        via: 'fetch',
        method: 'GET',
        url: 'https://api.test/me?access_token=t0ken',
        headers: {'Authorization': 'Bearer s3cret', 'Accept': 'json'},
      )!;
      call
        ..respond(
          status: 200,
          headers: {'Set-Cookie': 'sid=c00kie', 'content-type': 'text/plain'},
        )
        ..chunk(utf8.encode('ok'))
        ..end();
      final all = [for (final e in recorder.events) e.toJsonLine()].join();
      final answer = jsonEncode(
        traceAnswer(recorder, TraceQuery.fromArgs({'detail': 'full'})),
      );
      final compact = jsonEncode(traceAnswer(recorder, const TraceQuery()));
      for (final text in [all, answer, compact]) {
        expect(text, isNot(contains('s3cret')));
        expect(text, isNot(contains('t0ken')));
        expect(text, isNot(contains('c00kie')));
      }
      final request = recorder.events.first.data;
      expect((request['headers']! as Map)['authorization'], '***');
      expect((request['headers']! as Map)['accept'], 'json');
      // The kept body is the body only: no header goes to a tape.
      expect(net.bodies.bodyOf(recorder.events.last.seq), utf8.encode('ok'));
    });

    test('acceptance: the bridge long poll gives no events', () {
      final recorder = TraceRecorder();
      final net = NetRecorder(
        recorder,
        ignoreOrigins: {'http://127.0.0.1:4747'},
      );
      expect(
        net.request(
          via: 'fetch',
          method: 'GET',
          url: 'http://127.0.0.1:4747/commands?wait=25',
        ),
        isNull,
      );
      // Another port of the same host is the app's.
      expect(
        net.request(via: 'fetch', method: 'GET', url: 'http://127.0.0.1:8080/'),
        isNotNull,
      );
      expect(recorder.events, hasLength(1));
    });

    test("Pinpoint's own work is not recorded, whatever the origin", () {
      final recorder = TraceRecorder();
      final net = NetRecorder(recorder);
      CauseZone().run(() {});
      final call = CauseZone.internal(
        () => net.request(via: 'fetch', method: 'GET', url: '/poll'),
      );
      expect(call, isNull);
      expect(recorder.events, isEmpty);
    });

    test('a relative URL is checked against the page origin', () {
      final recorder = TraceRecorder();
      final page = '${Uri.base.scheme}://${Uri.base.authority}';
      final net = NetRecorder(recorder, ignoreOrigins: {page});
      expect(
        net.request(via: 'xhr', method: 'GET', url: '/annotations'),
        isNull,
      );
    });

    test('events say how many requests were left out', () {
      final recorder = TraceRecorder();
      final net = NetRecorder(recorder, ignoreOrigins: {'http://b.test'});
      net.request(via: 'fetch', method: 'GET', url: 'http://b.test/x');
      net.request(via: 'fetch', method: 'GET', url: 'http://b.test/y');
      expect(net.ignored, 2);
      expect(
        recorder.events.where((e) => e.kind == TraceKind.netRequest),
        isEmpty,
      );
    });
  });
}
