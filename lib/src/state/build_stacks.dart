import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../model/annotation.dart' show clipText;
import '../model/source_location.dart';
import '../model/trace_event.dart';
import '../trace/trace_recorder.dart';
import 'console_filter.dart';
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

  /// Stacks left out: their element is outside the app's content (Pinpoint's
  /// own panels), or it was not watched and no frame of them was the
  /// project's (the framework's own `setState`: a scroll bar, a focus node).
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
/// scheduleBuildFor() called; ...` and a stack instead. On newer Flutter
/// versions, web sends the label and stack to `console.error`.
/// [ConsoleFilter] observes and suppresses them while the window is open.
class BuildStacks {
  BuildStacks({
    required this.hooks,
    required this.recorder,
    required this.paths,
    this.watched,
    this.content,
    this.projectFiles,
    ConsoleFilter? consoleFilter,
    this.maxPerSecond = defaultMaxPerSecond,
    int Function()? clock,
  }) : consoleFilter = consoleFilter ?? createConsoleFilter(hooks),
       _clock = clock ?? _realClock {
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

  /// The element directly above the app's own widgets. A `setState` of an
  /// element that is not under it (Pinpoint's panels and overlay) is never
  /// recorded. Null: every element counts as the app's.
  final Element? Function()? content;

  /// The app's own files, to tell its frames from the framework's. Null or
  /// empty: the deny list of [firstProjectFrameIn] decides.
  final ProjectFiles Function()? projectFiles;

  final ConsoleFilter consoleFilter;
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
  _Subject? _pendingSubject;
  bool _expectStack = false;

  // Per window: what each label turned out to be, so a `setState` loop
  // (Pinpoint's own, 60 a second) does not walk the tree again.
  final Map<String, _Subject> _subjects = <String, _Subject>{};

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
    _pendingSubject = null;
    _subjects.clear();
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
      consoleFilter.install(onMessage: _onConsoleMessage);
      flagSlot.set(true);
      _armed = true;
      _timer = Timer(length, stop);
    } catch (error) {
      _failure = 'start failed: $error';
      _restore();
    }
  }

  /// Closes the window and restores the flag, `debugPrint` and the console.
  /// Safe to call when no window is open. Returns what the window saw.
  BuildStacksSummary stop() {
    if (!_armed) return summary;
    _restore();
    if (_dropped > 0) {
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
    _pendingSubject = null;
    _subjects.clear();
    _expectStack = false;
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
    try {
      consoleFilter.restore();
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

  void _onConsoleMessage(String message) {
    if (!_armed) return;
    try {
      _consume(message);
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    _failure = 'handler failed: $error';
    _restore();
  }

  /// Whether [message] is one of the framework's lines for a
  /// `scheduleBuildFor` call: such a line is not forwarded.
  bool _consume(String message) {
    if (_expectStack) {
      if (!message.startsWith(_labelPrefix) &&
          !message.startsWith(_resortLabel) &&
          _looksLikeStack(message)) {
        _expectStack = false;
        final label = _pendingLabel;
        final subject = _pendingSubject;
        _pendingLabel = null;
        _pendingSubject = null;
        if (label != null && subject != null) _record(label, message, subject);
        return true;
      }
      // Not a stack: the expected one never came. Read this line afresh.
      _expectStack = false;
      _pendingLabel = null;
      _pendingSubject = null;
    }
    if (message.startsWith(_labelPrefix)) {
      _expectStack = true;
      _seen++;
      _pendingLabel = null;
      _pendingSubject = null;
      final text = _labelText(message).$1;
      // An element known to be outside the app costs nothing and does not
      // count toward the cap: Pinpoint's own panel must not use up the
      // budget of the app's setStates.
      var subject = _subjects[text];
      if (subject != null && !subject.inContent) {
        _filtered++;
        return true;
      }
      final now = _clock();
      if (now - _secondStart >= 1000) {
        _secondStart = now;
        _inSecond = 0;
      }
      if (_inSecond >= maxPerSecond) {
        // Whether the stack was worth keeping is not known without a walk
        // of the tree, which is the cost the cap is there to avoid.
        _dropped++;
        return true;
      }
      _inSecond++;
      subject ??= _subjectOf(text);
      if (!subject.inContent) {
        _filtered++;
        return true;
      }
      _pendingLabel = message;
      _pendingSubject = subject;
      return true;
    }
    if (message.startsWith(_resortLabel)) {
      // The element was in the dirty list already: no new setState.
      _expectStack = true;
      _pendingLabel = null;
      _pendingSubject = null;
      return true;
    }
    return message.startsWith(_dirtyListLine);
  }

  static bool _looksLikeStack(String message) =>
      ConsoleLineFilter.looksLikeStack(message);

  static (String, bool) _labelText(String label) {
    var text = label.substring(_labelPrefix.length);
    var inList = false;
    if (text.endsWith(_alreadyListed)) {
      text = text.substring(0, text.length - _alreadyListed.length);
      inList = true;
    }
    return (text, inList);
  }

  void _record(String label, String stack, _Subject subject) {
    final (text, inList) = _labelText(label);
    final element = subject.element;
    ProjectFiles? files;
    try {
      files = projectFiles?.call();
    } catch (_) {
      // Without files the deny list decides.
    }
    final frame = firstProjectFrameIn(stack, paths, files: files);
    // A stack counts when its element is followed, or when app code is in
    // it. The rest is the framework's own `setState` (a scroll, a tooltip,
    // a focus change): the engine's `invoke()` is not app code.
    if (!subject.watched && frame == null) {
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
        'watched': subject.watched,
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

  /// Most elements one walk for a label visits.
  static const int maxWalk = 50000;

  /// Most labels remembered in a window.
  static const int maxSubjects = 512;

  /// What the element of [text] is: followed, in the app's content, or
  /// neither (Pinpoint's own, or gone).
  _Subject _subjectOf(String text) {
    final watchedElement = _match(text);
    if (watchedElement != null) {
      return _Subject(watchedElement, watched: true, inContent: true);
    }
    final root = _content();
    if (root == null) {
      // No boundary to test against: every element counts as the app's.
      return const _Subject(null, watched: false, inContent: true);
    }
    final found = _findDirty(root, text);
    final subject = _Subject(found, watched: false, inContent: found != null);
    if (_subjects.length >= maxSubjects) _subjects.clear();
    _subjects[text] = subject;
    return subject;
  }

  Element? _content() {
    final get = content;
    if (get == null) return null;
    try {
      final element = get();
      return element != null && element.mounted ? element : null;
    } catch (_) {
      return null;
    }
  }

  /// The dirty element under [root] that [text] describes, or null.
  /// Only a dirty element is described: the label was made after it was
  /// marked.
  static Element? _findDirty(Element root, String text) {
    var visited = 0;
    final stack = <Element>[root];
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      if (++visited > maxWalk) break;
      try {
        if (element.dirty && element.toString() == text) return element;
        element.visitChildren(stack.add);
      } catch (_) {
        // An element that cannot be described or walked is passed over.
      }
    }
    return null;
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

/// What the element of one `scheduleBuildFor` label is.
class _Subject {
  const _Subject(
    this.element, {
    required this.watched,
    required this.inContent,
  });

  /// The element, when it was found (watched, or under the content).
  final Element? element;

  /// Whether the lens follows it.
  final bool watched;

  /// Whether it is the app's: under the content element, or the lens
  /// follows it. False: Pinpoint's own panels and overlay, or gone.
  final bool inContent;
}
