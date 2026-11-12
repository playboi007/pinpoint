import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../bridge/bridge_protocol.dart';
import '../sink/bridge_client.dart';

/// Runs one command and gives its answer: `{ok: true, result: …}` or
/// `{ok: false, error: …}`.
typedef CommandHandler = Future<Map<String, Object?>> Function(
  String tool,
  Map<String, Object?> args,
);

/// How agent commands reach the app.
///
/// A browser app cannot accept connections, so the default,
/// [LongPollTransport], asks the bridge for work. The service-extension
/// spike (step 6) is a second implementation.
abstract class CommandTransport {
  /// Starts handing commands to [handler]. Does nothing while running.
  void start(CommandHandler handler);

  /// Stops at once, ending a request that is held open.
  void stop();

  /// Whether commands are being taken.
  bool get running;
}

/// Long-polls the bridge: `GET /commands?wait=25` holds until the agent
/// calls a tool or the wait ends, then the app runs the command and posts
/// the answer to `POST /commands/<id>/result`.
///
/// One command at a time, in order. The held request never draws a frame
/// (engineering rule 2); it costs one open connection.
class LongPollTransport implements CommandTransport {
  LongPollTransport(
    this.client, {
    this.wait = commandWait,
    this.retry = const Duration(seconds: 2),
  });

  final BridgeClient client;

  /// How long one poll is held open.
  final Duration wait;

  /// The pause after a failed poll (bridge stopped), before the next one.
  final Duration retry;

  /// An empty poll answered faster than this is followed by a [retry]
  /// pause.
  static const Duration minEmptyPoll = Duration(seconds: 1);

  bool _running = false;

  /// Bumped by every start and stop, so a loop from before a stop ends
  /// even when its request answers late.
  int _generation = 0;

  http.Client? _held;
  Timer? _retryTimer;
  Completer<void>? _retryWait;

  @override
  bool get running => _running;

  @override
  void start(CommandHandler handler) {
    if (_running) return;
    _running = true;
    unawaited(_loop(++_generation, handler));
  }

  @override
  void stop() {
    if (!_running) return;
    _running = false;
    _generation++;
    // Watch out for: a poll held open for 25 seconds must end on dispose
    // and when the tab is hidden. Closing its client aborts it (on web,
    // the XHR); a test client that cannot abort is answered by the
    // bridge's control-off instead.
    _held?.close();
    _held = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final pause = _retryWait;
    _retryWait = null;
    if (pause != null && !pause.isCompleted) pause.complete();
  }

  Future<void> _loop(int generation, CommandHandler handler) async {
    bool live() => _running && generation == _generation;
    while (live()) {
      final held = BridgeClient.debugClient == null ? http.Client() : null;
      _held = held;
      final asked = Stopwatch()..start();
      try {
        final command = await client.nextCommand(wait: wait, client: held);
        if (!live()) return;
        if (command == null) {
          // An empty answer long before the wait ended (a bridge that is
          // stopping, or one that does not hold polls) would make this
          // loop spin without a pause.
          if (asked.elapsed < minEmptyPoll) await _pause(generation);
          continue;
        }
        final id = command['id'];
        final tool = command['tool'];
        final args = command['args'];
        if (id is! String || tool is! String) continue;
        final ran = Stopwatch()..start();
        final answer = await handler(
          tool,
          args is Map<String, Object?> ? args : const <String, Object?>{},
        );
        // Stopped meanwhile: the bridge has failed the command already.
        if (!live()) return;
        // `ms`: the time in the app, so the bridge log can tell it from
        // the time on the network.
        await client.postCommandResult(id, {
          ...answer,
          'ms': ran.elapsedMilliseconds,
        });
      } on Object {
        if (!live()) return;
        await _pause(generation);
      } finally {
        if (identical(_held, held)) _held = null;
        held?.close();
      }
    }
  }

  /// Waits [retry], or less when stopped.
  Future<void> _pause(int generation) {
    final done = _retryWait = Completer<void>();
    _retryTimer = Timer(retry, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }
}

/// Whether `ext.pinpoint.command` is registered in this isolate.
bool get debugRegisteredPinpointExtension =>
    ServiceExtensionTransport._registered;

/// A spike (plan Milestone 12, step 2): commands as a VM service extension,
/// `ext.pinpoint.command`, which the bridge would call over the debug
/// connection. No polling and no CORS, but it needs the debug service
/// address, and on web it is registered only while a debugger is attached
/// (`flutter run -d chrome`; docs/api-notes.md, item 14). So the long poll
/// stays the default, and the bridge does not call this yet.
///
/// Parameters are strings: `tool`, and `args` as JSON. The answer is the
/// command's answer as JSON.
class ServiceExtensionTransport implements CommandTransport {
  /// The extension's name.
  static const String method = 'ext.pinpoint.command';

  /// `registerExtension` has no unregister, and throws on a second
  /// registration: register once per isolate and route to the current
  /// handler.
  static bool _registered = false;
  static CommandHandler? _handler;

  bool _running = false;

  @override
  bool get running => _running;

  @override
  void start(CommandHandler handler) {
    _running = true;
    _handler = handler;
    if (_registered) return;
    _registered = true;
    developer.registerExtension(method, (name, params) async {
      return developer.ServiceExtensionResponse.result(
        await handle(name, params),
      );
    });
  }

  @override
  void stop() {
    _running = false;
    _handler = null;
  }

  /// Answers one call of the extension, as JSON.
  static Future<String> handle(String name, Map<String, String> params) async {
    final handler = _handler;
    if (handler == null) {
      return jsonEncode({'ok': false, 'error': 'agent control is disabled'});
    }
    final tool = params['tool'];
    if (tool == null || tool.isEmpty) {
      return jsonEncode({'ok': false, 'error': 'tool is required'});
    }
    Map<String, Object?> args = const {};
    final raw = params['args'];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) args = decoded;
      } on FormatException {
        return jsonEncode({'ok': false, 'error': 'args is not JSON'});
      }
    }
    return jsonEncode(await handler(tool, args));
  }
}
