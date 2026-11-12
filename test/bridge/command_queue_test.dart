import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/command_queue.dart';

/// Milestone 12, build step 1: the queue between the MCP tools and the
/// app's long poll, in plain Dart.
void main() {
  test('with no app polling, run answers at once that control is off', () async {
    final queue = CommandQueue();
    final watch = Stopwatch()..start();
    final answer = await queue.run('tap', const {'handle': 'h1'});
    expect(answer['ok'], isFalse);
    expect(answer['error'], startsWith('agent control is disabled'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(queue.pendingCount, 0);
  });

  test('a waiting poll takes the command; the result comes back', () async {
    final queue = CommandQueue();
    final poll = queue.next(wait: const Duration(seconds: 5));
    expect(queue.connected, isTrue);
    final run = queue.run('get_screen', const {'limit': 3});
    final command = (await poll)!;
    expect(command['tool'], 'get_screen');
    expect(command['args'], {'limit': 3});
    expect(
      queue.complete(command['id']! as String, {
        'ok': true,
        'result': {'route': '/'},
      }),
      isTrue,
    );
    expect(await run, {
      'ok': true,
      'result': {'route': '/'},
    });
    // Answered once only.
    expect(queue.complete(command['id']! as String, {'ok': true}), isFalse);
  });

  test('a command queued between two polls goes to the next poll', () async {
    final queue = CommandQueue();
    expect(await queue.next(wait: Duration.zero), isNull);
    // Polled a moment ago: still connected, so the command waits.
    final run = queue.run('get_screen', const {});
    expect(queue.pendingCount, 1);
    final command = (await queue.next())!;
    queue.complete(command['id']! as String, {'ok': false, 'error': 'nope'});
    expect(await run, {'ok': false, 'error': 'nope'});
  });

  test('an app that stops polling counts as gone after the grace', () async {
    var now = DateTime(2026, 11, 11, 12);
    final queue = CommandQueue(
      pollGrace: const Duration(seconds: 35),
      clock: () => now,
    );
    await queue.next(wait: Duration.zero);
    expect(queue.connected, isTrue);
    now = now.add(const Duration(seconds: 36));
    expect(queue.connected, isFalse);
    final answer = await queue.run('tap', const {});
    expect(answer['error'], startsWith('agent control is disabled'));
  });

  test('control off fails what is waiting and ends the poll', () async {
    final queue = CommandQueue();
    final poll = queue.next(wait: const Duration(seconds: 5));
    final command = queue.run('tap', const {});
    final taken = (await poll)!;
    final second = queue.run('scroll', const {});
    queue.setControl(false);
    expect((await command)['error'], startsWith('agent control is disabled'));
    expect((await second)['error'], startsWith('agent control is disabled'));
    expect(queue.complete(taken['id']! as String, {'ok': true}), isFalse);
    expect(queue.connected, isFalse);
    expect(
      (await queue.run('back', const {}))['error'],
      startsWith('agent control is disabled'),
    );
  });

  test('a taken command that is never answered times out', () async {
    final queue = CommandQueue();
    final poll = queue.next(wait: const Duration(seconds: 5));
    final run = queue.run(
      'wait_idle',
      const {},
      timeout: const Duration(milliseconds: 50),
    );
    await poll;
    final answer = await run;
    expect(answer['error'], 'the app did not answer wait_idle within 0 s');
  });

  test('the poll ends empty after its wait', () async {
    final queue = CommandQueue();
    expect(await queue.next(wait: const Duration(milliseconds: 10)), isNull);
  });

  test('each answer logs where its time went', () async {
    final lines = <String>[];
    final queue = CommandQueue(log: lines.add);
    final poll = queue.next(wait: const Duration(seconds: 5));
    final run = queue.run('find_widgets', const {'text': 'Save'});
    final command = (await poll)!;
    queue.complete(command['id']! as String, {
      'ok': true,
      'result': const <String, Object?>{},
      'ms': 12,
    });
    // The app's `ms` stays out of the agent's answer.
    expect(await run, {'ok': true, 'result': const <String, Object?>{}});
    expect(lines, hasLength(1));
    expect(
      lines.single,
      matches(
        RegExp(
          r'^pinpoint: find_widgets took \d+ ms \(\d+ ms until the app took '
          r'it, 12 ms in the app, \d+ ms network\)$',
        ),
      ),
    );
  });

  test('the timing line splits the total', () {
    expect(
      CommandQueue.timingLine(
        'tap',
        const Duration(milliseconds: 3000),
        const Duration(milliseconds: 20),
        2900,
      ),
      'pinpoint: tap took 3000 ms (20 ms until the app took it, 2900 ms in '
      'the app, 80 ms network)',
    );
    // An app without `ms` (older version): no split.
    expect(
      CommandQueue.timingLine(
        'tap',
        const Duration(milliseconds: 40),
        const Duration(milliseconds: 5),
        null,
      ),
      'pinpoint: tap took 40 ms (5 ms until the app took it)',
    );
  });
}
