// Plain Dart with no `dart:io` and no Flutter: the bridge serves it over
// HTTP, and widget tests (which cannot open sockets) call it directly.

import 'dart:async';
import 'dart:math' as math;

/// What the bridge says when no app takes commands.
const String agentControlDisabled =
    'agent control is disabled. Ask the user to turn on "Allow agent '
    'control" in the Pinpoint overlay of the running app (the app must use '
    'this bridge).';

/// Agent commands on their way from the MCP tools to the app, and their
/// results on the way back.
///
/// A browser app cannot accept connections, so the app asks for work: it
/// long-polls [next], runs the command, and hands the result to
/// [complete]. An MCP tool calls [run] and waits for that result.
///
/// The app polls only while the user has turned on "Allow agent control".
/// So [run] answers [agentControlDisabled] at once when no app polled
/// recently, or the app said it turned control off ([setControl]): nothing
/// waits for an app that will never ask.
///
/// One app at a time: whichever app polls takes the next command.
class CommandQueue {
  CommandQueue({
    this.pollGrace = const Duration(seconds: 35),
    DateTime Function()? clock,
    this._log,
  }) : _clock = clock ?? DateTime.now;

  /// How long after its last poll an app still counts as connected. Longer
  /// than the app's wait, so an app between two polls is not missed.
  final Duration pollGrace;

  final DateTime Function() _clock;

  /// Gets one line per answered command: where its time went.
  final void Function(String line)? _log;

  /// The longest an app may hold a poll open.
  static const Duration maxWait = Duration(seconds: 30);

  int _next = 0;
  bool _closed = false;

  /// False after the app said it turned control off; true once it polls.
  bool _enabled = false;
  DateTime? _lastPoll;

  final List<_Command> _pending = <_Command>[];
  final Map<String, _Command> _running = <String, _Command>{};
  final List<Completer<Map<String, Object?>?>> _waiters =
      <Completer<Map<String, Object?>?>>[];

  /// Whether an app takes commands now: it is polling, or polled within
  /// [pollGrace], and has not turned control off since.
  bool get connected {
    if (!_enabled || _closed) return false;
    if (_waiters.isNotEmpty) return true;
    final last = _lastPoll;
    return last != null && _clock().difference(last) <= pollGrace;
  }

  /// Commands not yet taken by the app, for tests.
  int get pendingCount => _pending.length;

  /// Sends [tool] with [args] to the app and waits for its answer, at most
  /// [timeout]. The answer is `{ok: true, result: …}` or `{ok: false,
  /// error: …}`; a missing app or a timeout is an error answer too, never
  /// an exception.
  Future<Map<String, Object?>> run(
    String tool,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!connected) return error(agentControlDisabled);
    final command = _Command('c${++_next}', tool, args);
    _pending.add(command);
    _deliver();
    try {
      return await command.done.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(command);
      _running.remove(command.id);
      final taken = command.taken;
      return error(
        taken
            ? 'the app did not answer $tool within ${timeout.inSeconds} s'
            : 'no app took $tool within ${timeout.inSeconds} s; '
                  '$agentControlDisabled',
      );
    }
  }

  /// The app's long poll: the next command as `{id, tool, args}`, or null
  /// when none comes within [wait] (at most [maxWait]).
  Future<Map<String, Object?>?> next({
    Duration wait = const Duration(seconds: 25),
  }) async {
    if (_closed) return null;
    _enabled = true;
    _lastPoll = _clock();
    if (_pending.isNotEmpty) return _take();
    final waiter = Completer<Map<String, Object?>?>();
    _waiters.add(waiter);
    final timer = Timer(wait > maxWait ? maxWait : wait, () {
      _waiters.remove(waiter);
      if (!waiter.isCompleted) waiter.complete(null);
    });
    try {
      return await waiter.future;
    } finally {
      timer.cancel();
      _lastPoll = _clock();
    }
  }

  /// The app's answer to the command [id]. Returns false for an unknown or
  /// finished command.
  bool complete(String id, Map<String, Object?> answer) {
    final command = _running.remove(id);
    if (command == null || command.done.isCompleted) return false;
    _log?.call(
      timingLine(
        command.tool,
        command.watch.elapsed,
        command.queued,
        answer['ms'],
      ),
    );
    command.done.complete(
      answer['ok'] == true
          ? {'ok': true, 'result': answer['result']}
          : error(
              answer['error'] is String
                  ? answer['error']! as String
                  : 'the app gave no reason',
            ),
    );
    return true;
  }

  /// The app turned agent control on or off. Off fails every command it
  /// has not answered, and ends its poll.
  void setControl(bool enabled) {
    _enabled = enabled;
    if (enabled) {
      _lastPoll = _clock();
      return;
    }
    _failAll(agentControlDisabled);
  }

  /// Fails everything and refuses new work.
  void close() {
    _closed = true;
    _failAll('the bridge stopped');
  }

  void _failAll(String reason) {
    for (final command in [..._pending, ..._running.values]) {
      if (!command.done.isCompleted) command.done.complete(error(reason));
    }
    _pending.clear();
    _running.clear();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _waiters.clear();
  }

  void _deliver() {
    while (_waiters.isNotEmpty && _pending.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) waiter.complete(_take());
    }
  }

  /// Where the time of one command went: [total] from the tool call to
  /// the answer, [queued] until the app took it, and [appMs] (the `ms` the
  /// app reports) running it. The rest is the network and the bridge.
  static String timingLine(
    String tool,
    Duration total,
    Duration queued,
    Object? appMs,
  ) {
    final all = total.inMilliseconds;
    final wait = queued.inMilliseconds;
    if (appMs is! num) {
      return 'pinpoint: $tool took $all ms ($wait ms until the app took it)';
    }
    final app = appMs.round();
    final network = math.max(0, all - wait - app);
    return 'pinpoint: $tool took $all ms ($wait ms until the app took it, '
        '$app ms in the app, $network ms network)';
  }

  Map<String, Object?> _take() {
    final command = _pending.removeAt(0);
    command
      ..taken = true
      ..queued = command.watch.elapsed;
    _running[command.id] = command;
    return {'id': command.id, 'tool': command.tool, 'args': command.args};
  }

  /// An error answer.
  static Map<String, Object?> error(String message) => {
    'ok': false,
    'error': message,
  };
}

class _Command {
  _Command(this.id, this.tool, this.args);

  final String id;
  final String tool;
  final Map<String, Object?> args;
  final Completer<Map<String, Object?>> done =
      Completer<Map<String, Object?>>();
  bool taken = false;

  /// Runs from the tool call.
  final Stopwatch watch = Stopwatch()..start();

  /// How long it waited for the app's poll.
  Duration queued = Duration.zero;
}
