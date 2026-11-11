import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Runs one agent command: [tool] with [args]. Checks [cancel] after each
/// wait, so Esc stops it.
typedef AgentRunner = Future<Map<String, Object?>> Function(
  String tool,
  Map<String, Object?> args,
  AgentCancel cancel,
);

/// Thrown inside a command when the user stopped it.
class AgentAborted implements Exception {
  const AgentAborted();

  @override
  String toString() => 'stopped by the user (agent control was turned off)';
}

/// The stop flag of one running command.
class AgentCancel {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;

  /// Throws [AgentAborted] once cancelled. Call it after every await.
  void check() {
    if (_cancelled) throw const AgentAborted();
  }
}

/// A dot where a synthetic tap landed, in global logical pixels.
@immutable
class AgentMark {
  const AgentMark(this.position, {this.longPress = false});

  final Offset position;
  final bool longPress;
}

/// Whether the agent may operate the app, and what it is doing now.
///
/// Off by default, and off again after every restart: anything on the
/// command channel can operate the app, so the user turns it on in the
/// overlay, sees a chip while it is on, and Esc turns it off and stops the
/// running command.
class AgentControl extends ChangeNotifier {
  /// Tools that change the app. Refused while control is off.
  static const Set<String> drivingTools = {
    'tap',
    'long_press',
    'enter_text',
    'scroll',
    'scroll_to',
    'navigate',
    'back',
    'set_environment',
    'reset_environment',
    'verify_note',
    'stress_matrix',
  };

  /// Tools that only read. They reach the app only through the command
  /// channel, which is closed while control is off.
  static const Set<String> readTools = {
    'get_screen',
    'find_widgets',
    'inspect',
    'flash',
    'wait_idle',
    'scan',
    'screenshot',
    'get_state',
  };

  /// How long a tap dot stays.
  static const Duration markTime = Duration(milliseconds: 600);

  /// How long `flash` outlines a widget.
  static const Duration flashTime = Duration(milliseconds: 1500);

  bool _enabled = false;
  String? _driving;
  AgentCancel? _cancel;
  bool _disposed = false;

  /// Runs commands; set by the overlay while it is mounted.
  AgentRunner? runner;

  final ValueNotifier<List<AgentMark>> _marks = ValueNotifier<List<AgentMark>>(
    const <AgentMark>[],
  );
  final ValueNotifier<RenderObject?> _flash = ValueNotifier<RenderObject?>(
    null,
  );
  final Set<Timer> _timers = <Timer>{};

  /// Whether the user allows the agent to operate the app.
  bool get enabled => _enabled;

  /// Turning it off stops the running command.
  set enabled(bool value) {
    if (value == _enabled || _disposed) return;
    _enabled = value;
    if (!value) _cancel?.cancel();
    notifyListeners();
  }

  /// The tool running now, or null.
  String? get driving => _driving;

  /// Where synthetic taps landed in the last moment.
  ValueListenable<List<AgentMark>> get marks => _marks;

  /// The render object `flash` outlines, or null.
  ValueListenable<RenderObject?> get flash => _flash;

  /// What Esc does: stops the running command and turns control off.
  void abort() => enabled = false;

  /// Runs [tool] with [args]. The answer is `{ok: true, result: …}` or
  /// `{ok: false, error: …}`; it never throws.
  Future<Map<String, Object?>> run(
    String tool,
    Map<String, Object?> args,
  ) async {
    // Checked here, before anything runs, whatever the transport: a driving
    // command never reaches the app while control is off.
    if (!_enabled && drivingTools.contains(tool)) {
      return error('agent control is disabled');
    }
    final runner = this.runner;
    if (runner == null) return error('Pinpoint is not running in this app');
    if (_driving != null) {
      return error('another command is running ($_driving); try again');
    }
    final cancel = _cancel = AgentCancel();
    _driving = tool;
    notifyListeners();
    try {
      return await runner(tool, args, cancel);
    } on AgentAborted catch (stopped) {
      return error('$tool $stopped');
    } on Object catch (failure) {
      return error('$tool failed: $failure');
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      _driving = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Shows a dot at [position] for [markTime].
  void mark(Offset position, {bool longPress = false}) {
    if (_disposed) return;
    final mark = AgentMark(position, longPress: longPress);
    _marks.value = [..._marks.value, mark];
    _after(markTime, () {
      _marks.value = [
        for (final m in _marks.value)
          if (!identical(m, mark)) m,
      ];
    });
  }

  /// Outlines [renderObject] for [flashTime].
  void flashOn(RenderObject renderObject) {
    if (_disposed) return;
    _flash.value = renderObject;
    _after(flashTime, () {
      if (identical(_flash.value, renderObject)) _flash.value = null;
    });
  }

  void _after(Duration delay, VoidCallback action) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      if (!_disposed) action();
    });
    _timers.add(timer);
  }

  /// A success answer.
  static Map<String, Object?> ok(Object? result) => {
    'ok': true,
    'result': result,
  };

  /// An error answer.
  static Map<String, Object?> error(String message) => {
    'ok': false,
    'error': message,
  };

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _marks.dispose();
    _flash.dispose();
    super.dispose();
  }
}
