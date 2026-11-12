import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/tape/net_matcher.dart';
import 'package:pinpoint/src/trace/redact.dart';

/// PLAN-v2 Milestone 15, build step 1: the request key and the nth answer,
/// plain Dart (rule 13).
void main() {
  const matcher = NetMatcher();

  group('request key', () {
    test('method, URL and body hash', () {
      final key = matcher.key('get', 'https://api.test/items?page=2', null);
      expect(key, 'GET https://api.test/items?page=2 -');
      final post = matcher.key(
        'POST',
        'https://api.test/items',
        utf8.encode('{"a":1}'),
      );
      expect(post, startsWith('POST https://api.test/items #'));
    });

    test('parameters in redact leave the key, so a fresh token matches', () {
      final a = matcher.key('GET', 'https://api.test/x?token=abc&q=1', null);
      final b = matcher.key('GET', 'https://api.test/x?token=xyz&q=1', null);
      expect(a, b);
      expect(a, 'GET https://api.test/x?q=1 -');
    });

    test('the fragment never reaches the key', () {
      expect(
        matcher.key('GET', 'https://api.test/x#top', null),
        matcher.key('GET', 'https://api.test/x', null),
      );
    });

    test('watch out for: a time or random id in the body never matches by '
        'hash; matchIgnore leaves those fields out, at any depth', () {
      List<int> body(int ts, String id) => utf8.encode(
        jsonEncode({
          'q': 'shoes',
          'ts': ts,
          'meta': {'requestId': id},
        }),
      );
      expect(
        matcher.key('POST', 'https://api.test/s', body(1, 'a')),
        isNot(matcher.key('POST', 'https://api.test/s', body(2, 'b'))),
      );
      const ignoring = NetMatcher(ignore: ['ts', 'requestId']);
      expect(
        ignoring.key('POST', 'https://api.test/s', body(1, 'a')),
        ignoring.key('POST', 'https://api.test/s', body(2, 'b')),
      );
      // Not fuzzy: another query is another key.
      expect(
        ignoring.key('POST', 'https://api.test/s', body(1, 'a')),
        isNot(
          ignoring.key(
            'POST',
            'https://api.test/s',
            utf8.encode('{"q":"hats","ts":1}'),
          ),
        ),
      );
    });

    test('matchIgnore also leaves URL parameters out', () {
      const ignoring = NetMatcher(ignore: ['_']);
      expect(
        ignoring.key('GET', 'https://api.test/x?_=1700000&q=1', null),
        ignoring.key('GET', 'https://api.test/x?q=1&_=1800000', null),
      );
    });

    test('JSON key order does not change the key', () {
      expect(
        matcher.key('POST', 'u', utf8.encode('{"a":1,"b":2}')),
        matcher.key('POST', 'u', utf8.encode('{"b":2,"a":1}')),
      );
    });

    test('custom redact names count as parameters to leave out', () {
      const custom = NetMatcher(redact: TraceRedact(['session']));
      expect(
        custom.key('GET', 'https://a.test/?session=1&x=2', null),
        'GET https://a.test/?x=2 -',
      );
    });
  });

  group('NetReplay', () {
    Tape tape(List<NetExchange> net) => Tape(
      id: 'tp_test',
      kind: TapeKind.full,
      start: const TapeStart(t: 0, seq: 1, wallTime: '2026-11-13T10:00:00Z'),
      net: net,
      bodies: {
        for (final e in net)
          if (e.status != null) e.n: Uint8List.fromList(utf8.encode('#${e.n}')),
      },
    );

    NetExchange ex(int n, String key, {int? status = 200, int ms = 40}) =>
        NetExchange(
          n: n,
          key: key,
          method: 'GET',
          url: 'https://api.test/$n',
          t: n * 10,
          status: status,
          ms: ms,
          hash: 'h$n',
          size: 2,
        );

    test('acceptance: the nth request with a key gets the nth answer', () {
      final replay = NetReplay(
        tape([ex(0, 'A'), ex(1, 'B'), ex(2, 'A'), ex(3, 'A')]),
        matcher: _KeyIsUrl(),
      );
      String served(String key) {
        final answer = replay.answer(method: 'GET', url: key);
        expect(answer, isA<ServeAnswer>(), reason: key);
        return utf8.decode((answer as ServeAnswer).body);
      }

      expect(served('A'), '#0');
      expect(served('A'), '#2');
      expect(served('B'), '#1');
      expect(served('A'), '#3');
      expect(replay.asked, ['A', 'A', 'B', 'A']);
    });

    test('unmatched fail: a clear error and no request goes out', () {
      final replay = NetReplay(tape([ex(0, 'A')]), matcher: _KeyIsUrl());
      replay.answer(method: 'GET', url: 'A');
      final second = replay.answer(method: 'GET', url: 'A');
      expect(second, isA<FailAnswer>());
      expect((second as FailAnswer).reason, contains('no answer in the tape'));
      expect(replay.unmatchedRequests, hasLength(1));
      final other = replay.answer(method: 'GET', url: 'Z');
      expect(other, isA<FailAnswer>());
    });

    test('unmatched passthrough sends the request to the server', () {
      final replay = NetReplay(
        tape([ex(0, 'A')]),
        matcher: _KeyIsUrl(),
        unmatched: Unmatched.passthrough,
      );
      expect(replay.answer(method: 'GET', url: 'A'), isA<ServeAnswer>());
      expect(replay.answer(method: 'GET', url: 'A'), isA<PassAnswer>());
      expect(replay.answer(method: 'GET', url: 'X'), isA<PassAnswer>());
    });

    test('unmatched last serves the last answer with that key', () {
      final replay = NetReplay(
        tape([ex(0, 'A'), ex(1, 'A')]),
        matcher: _KeyIsUrl(),
        unmatched: Unmatched.last,
      );
      for (var i = 0; i < 2; i++) {
        replay.answer(method: 'GET', url: 'A');
      }
      final third = replay.answer(method: 'GET', url: 'A');
      expect(utf8.decode((third as ServeAnswer).body), '#1');
      expect(replay.answer(method: 'GET', url: 'Q'), isA<FailAnswer>());
    });

    test('a request that failed in the tape fails again', () {
      final failed = NetExchange(
        n: 0,
        key: 'A',
        method: 'GET',
        url: 'u',
        t: 0,
        error: 'network error',
      );
      final replay = NetReplay(tape([failed]), matcher: _KeyIsUrl());
      final answer = replay.answer(method: 'GET', url: 'A');
      expect(answer, isA<FailAnswer>());
      expect((answer as FailAnswer).taped, isTrue);
    });

    test('watch out for: a streaming request is unsupported and passes '
        'through', () {
      final stream = NetExchange(
        n: 0,
        key: 'A',
        method: 'GET',
        url: 'u',
        t: 0,
        status: 200,
        unsupported: 'event stream',
      );
      final replay = NetReplay(tape([stream]), matcher: _KeyIsUrl());
      expect(replay.answer(method: 'GET', url: 'A'), isA<PassAnswer>());
    });

    test('latency: recorded, instant, or a set time', () {
      final t = tape([ex(0, 'A', ms: 300)]);
      Duration delay(ReplayLatency latency) => (NetReplay(
        t,
        matcher: _KeyIsUrl(),
        latency: latency,
      ).answer(method: 'GET', url: 'A') as ServeAnswer).delay;
      expect(delay(const ReplayLatency.recorded()), 300.ms);
      expect(delay(const ReplayLatency.instant()), Duration.zero);
      expect(delay(const ReplayLatency.fixed(50)), 50.ms);
      // speed 4 makes recorded latency a quarter.
      expect(
        (NetReplay(
          t,
          matcher: _KeyIsUrl(),
          speed: 4,
        ).answer(method: 'GET', url: 'A') as ServeAnswer).delay,
        75.ms,
      );
    });

    test('waitFor completes when every listed answer was delivered', () async {
      final replay = NetReplay(
        tape([ex(0, 'A'), ex(1, 'B')]),
        matcher: _KeyIsUrl(),
      );
      var done = false;
      final wait = replay.waitFor([0, 1], timeout: 1.seconds).then((ok) {
        done = true;
        return ok;
      });
      replay.delivered(0);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      replay.delivered(1);
      expect(await wait, isTrue);
      expect(await replay.waitFor([0]), isTrue);
    });

    test('waitFor gives up after its timeout', () {
      final replay = NetReplay(tape([ex(0, 'A')]), matcher: _KeyIsUrl());
      return expectLater(
        replay.waitFor([0], timeout: 10.ms),
        completion(isFalse),
      );
    });
  });
}

/// A matcher whose key is the URL, so the tests name keys directly.
class _KeyIsUrl extends NetMatcher {
  _KeyIsUrl();

  @override
  String key(String method, String url, List<int>? body) => url;
}

extension on int {
  Duration get ms => Duration(milliseconds: this);
  Duration get seconds => Duration(seconds: this);
}
