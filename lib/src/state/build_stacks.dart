import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../model/annotation.dart' show clipText;
import '../model/source_location.dart';
import '../model/trace_event.dart';
import '../trace/trace_recorder.dart';
import 'console_filter.dart' show ConsoleLineFilter;
import 'stack_frames.dart';

/// What one window of [BuildStacks] saw.
@immutable
class BuildStacksSummary {
  const BuildStacksSummary({
    required this.seen,
    required this.recorded,
    required this.filtered,
    required this.dropped,
    this.failure,
  });

  /// `scheduleBuildFor` stacks that came in, whatever became of them.
  final int seen;

  /// Stacks recorded as `state.setState`.
  final int recorded;

  /// Stacks left out because their element was not watched and no frame
  /// of them was the project's.
  final int filtered;

  /// Stacks that the cap dropped: over [BuildStacks.maxPerSecond] in one
  /// second.
  final int dropped;

  /// Why the window ended early, for example an error in the handler.
  final String? failure;

  @override
  String toString() =>
      'seen $seen, recorded $recorded, filtered $filtered, dropped $dropped'
      '${failure == null ? '' : ', failed: $failure'}';
}

/// Who called `setState` (PLAN-v3 Milestone 21, step 3): a stack for every
/// `markNeedsBuild`, in an armed window only.
///
/// This covers a `State` that changes with no listenable that Pinpoint can
/// see. It sets `debugPrintScheduleBuildForStacks`, so `BuildOwner.
/// scheduleBuildFor` prints the element (a label) and the stack for each
/// call. A `setState` loop (a spinner is 60 a second) would flood: the window
/// is short (at most [maxWindow]) and capped at [maxPerSecond] stacks a
/// second; past that, a stack is dropped and counted.
///
/// Both globals (the flag and `debugPrint`) go through [HookRegistry] and
/// come back on [stop], on [HookRegistry.dispose] and after an error in the
/// handler. These lines are never forwarded to the real `debugPrint`: the
/// app's console stays as it was. Every other line is forwarded unchanged.
///
/// What the framework prints (api-notes, item 32; Flutter 3.47.5, on the
/// VM): three `debugPrint` calls for one call of `scheduleBuildFor`: the
/// label `scheduleBuildFor() called for <element>`, the stack as one
/// string, then `...the build scope's dirty list is now: [...]`. An element
/// that is already in the dirty list prints a label `BuildOwner.
/// scheduleBuildFor() called; ...` and a stack instead. On web the label
/// and the stack go to `console.error` through `ErrorToConsoleDumper`, not
/// through `debugPrint` (verified in Chrome, api-notes item 34): the dump
/// listener reads them there. `ConsoleFilter` keeps them out of the
/// console while the lens is armed.
class BuildStacks {
  BuildStacks({
    required this.hooks,
    required this.recorder,
    required this.paths,
    this.watched,
    this.maxPerSecond = defaultMaxPerSecond,
    int Function()? clock,
  }) : _clock = clock ?? _realClock {
    hooks.onDispose(() {
      if (armed) stop();
    });
  }

  /// Stacks taken in one second.
  static const int defaultMaxPerSecond = 30;

  /// Longest window; a longer request is cut to this.
  static const Duration maxWindow = Duration(seconds: 30);

  static const String _labelPrefix = 'scheduleBuildFor() called for ';
  static const String _alreadyListed = ' (ALREADY IN LIST)';
  static const String _resortLabel = 'BuildOwner.scheduleBuildFor() called;';
  static const String _dirtyListLine =
      "...the build scope's dirty list is now:";

  final HookRegistry hooks;
  final TraceRecorder recorder;

  /// Decides which frames are the project's.
  final SourcePaths paths;

  /// The elements the lens follows. A stack whose element is one of them
  /// is always recorded.
  final Iterable<Element> Function()? watched;

  final int maxPerSecond;
  final int Function() _clock;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _realClock() => _stopwatch.elapsedMilliseconds;

  GlobalSlot<DebugPrintCallback>? _printSlot;
  GlobalSlot<bool>? _flagSlot;
  late final DebugPrintCallback _wrapper = _onPrint;
  DebugPrintCallback? _forward;
  Timer? _timer;
  bool _armed = false;

  // The label of the stack that comes next, when it is to be recorded.
  String? _pendingLabel;
  bool _expectStack = false;

  int _seen = 0;
  int _recorded = 0;
  int _filtered = 0;
  int _dropped = 0;
  int _secondStart = 0;
  int _inSecond = 0;
  String? _failure;

  /// Whether a window is open.
  bool get armed => _armed;

  /// Stacks dropped by the cap in the window now, or in the last one.
  int get dropped => _dropped;

  /// What the window now (or the last one) saw.
  BuildStacksSummary get summary => BuildStacksSummary(
    seen: _seen,
    recorded: _recorded,
    filtered: _filtered,
    dropped: _dropped,
    failure: _failure,
  );

  // The web has no `debugPrint` for these lines: the dump listener is the
  // way in. A listener cannot be removed, so one is added for the whole
  // process and it forwards to whichever window is open.
  static bool _dumpListenerAdded = false;
  static BuildStacks? _open;

  /// Opens a window of [duration] (at most [maxWindow]), or restarts the
  /// timer of the open one. The window ends by itself.
  void start(Duration duration) {
    final length = duration > maxWindow ? maxWindow : duration;
    if (_armed) {
      _timer?.cancel();
      _timer = Timer(length, stop);
      return;
    }
    _seen = _recorded = _filtered = _dropped = 0;
    _secondStart = _clock();
    _inSecond = 0;
    _failure = null;
    _pendingLabel = null;
    _expectStack = false;
    try {
      final printSlot = _printSlot ??= hooks.slot<DebugPrintCallback>(
        key: 'debugPrint',
        read: () => debugPrint,
        write: (value) => debugPrint = value,
      );
      final flagSlot = _flagSlot ??= hooks.slot<bool>(
        key: 'debugPrintScheduleBuildForStacks',
        read: () => debugPrintScheduleBuildForStacks,
        write: (value) => debugPrintScheduleBuildForStacks = value,
      );
      printSlot.set(_wrapper);
      _forward = printSlot.previous;
      _open = this;
      if (!_dumpListenerAdded) {
        _dumpListenerAdded = true;
        ErrorToConsoleDumper.addWebDumpListener(_onDump);
      }
      flagSlot.set(true);
      _armed = true;
      _timer = Timer(length, stop);
    } catch (error) {
      _failure = 'start failed: $error';
      _restore();
    }
  }

  /// Closes the window: the flag and `debugPrint` are what they were.
  /// Safe to call when no window is open. Returns what the window saw.
  BuildStacksSummary stop() {
    final wasArmed = _armed;
    _restore();
    if (wasArmed && _dropped > 0) {
      try {
        recorder.add(TraceKind.stateDropped, data: {'n': _dropped});
      } catch (_) {
        // Only observes.
      }
    }
    return summary;
  }

  void _restore() {
    _armed = false;
    _timer?.cancel();
    _timer = null;
    _pendingLabel = null;
    _expectStack = false;
    if (identical(_open, this)) _open = null;
    // The flag first: no new line is printed once it is off.
    try {
      _flagSlot?.release();
    } catch (_) {
      // Keep going: `debugPrint` must come back too.
    }
    try {
      _printSlot?.release();
    } catch (_) {
      // Nothing left to undo.
    }
  }

  // The `debugPrint` of the app, while the window is open.
  void _onPrint(String? message, {int? wrapWidth}) {
    final forward = _forward;
    try {
      if (message != null && _armed && _consume(message)) return;
    } catch (error) {
      _fail(error);
    }
    if (forward != null) {
      forward(message, wrapWidth: wrapWidth);
    } else {
      debugPrintThrottled(message, wrapWidth: wrapWidth);
    }
  }

  static void _onDump(String message) {
    final open = _open;
    if (open == null || !open._armed) return;
    try {
      open._consume(message, fromDump: true);
    } catch (error) {
      open._fail(error);
    }
  }

  void _fail(Object error) {
    _failure = 'handler failed: $error';
    _restore();
  }

  /// Whether [message] is one of the framework's lines for a
  /// `scheduleBuildFor` call: such a line is not forwarded.
  bool _consume(String message, {bool fromDump = false}) {
    if (_expectStack) {
      if (!message.startsWith(_labelPrefix) &&
          !message.startsWith(_resortLabel) &&
          _looksLikeStack(message)) {
        _expectStack = false;
        final label = _pendingLabel;
        _pendingLabel = null;
        if (label != null) _record(label, message);
        return true;
      }
      // Not a stack: the expected one never came. Read this line afresh.
      _expectStack = false;
      _pendingLabel = null;
    }
    if (message.startsWith(_labelPrefix)) {
      _expectStack = true;
      _seen++;
      final now = _clock();
      if (now - _secondStart >= 1000) {
        _secondStart = now;
        _inSecond = 0;
      }
      if (_inSecond >= maxPerSecond) {
        _dropped++;
        _pendingLabel = null;
      } else {
        _inSecond++;
        _pendingLabel = message;
      }
      return !fromDump;
    }
    if (message.startsWith(_resortLabel)) {
      // The element was in the dirty list already: no new setState.
      _expectStack = true;
      _pendingLabel = null;
      return !fromDump;
    }
    if (message.startsWith(_dirtyListLine)) return !fromDump;
    return false;
  }

  static bool _looksLikeStack(String message) =>
      ConsoleLineFilter.looksLikeStack(message);

  void _record(String label, String stack) {
    var text = label.substring(_labelPrefix.length);
    var inList = false;
    if (text.endsWith(_alreadyListed)) {
      text = text.substring(0, text.length - _alreadyListed.length);
      inList = true;
    }
    final element = _match(text);
    final frame = firstProjectFrameIn(stack, paths);
    // A stack counts when its element is followed, or when app code is in
    // it. The rest is the framework's own `setState` (a scroll, a tooltip).
    if (element == null && frame == null) {
      _filtered++;
      return;
    }
    final widget = _typeOf(text, element);
    _recorded++;
    recorder.add(
      TraceKind.stateSetState,
      widget: widget,
      source: frame?.where,
      data: {
        'element': clipText(text, 160),
        'watched': element != null,
        if (element is StatefulElement)
          'state': element.state.runtimeType.toString(),
        if (inList) 'inDirtyList': true,
        if (frame != null) ...{
          'file': frame.file,
          'line': frame.line,
          'method': frame.method,
        },
      },
    );
  }

  /// The watched element whose description is [text], or null. The label
  /// is `'$element'` made inside `scheduleBuildFor`, after the element was
  /// marked dirty, so only a dirty element can match.
  Element? _match(String text) {
    final set = watched;
    if (set == null) return null;
    try {
      for (final element in set()) {
        if (!element.dirty) continue;
        if (element.toString() == text) return element;
      }
    } catch (_) {
      // An element that cannot be described is not matched.
    }
    return null;
  }

  static String _typeOf(String text, Element? element) {
    if (element != null) {
      try {
        return element.widget.runtimeType.toString();
      } catch (_) {
        // Unmounted: read the text instead.
      }
    }
    final open = text.indexOf('(');
    return open > 0 ? text.substring(0, open) : clipText(text, 60);
  }
}
