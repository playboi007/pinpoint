import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../model/trace_event.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';
import '../trace/sources/rebuild_source.dart';
import '../trace/state_flow.dart';
import '../trace/trace_recorder.dart';
import 'build_stacks.dart';
import 'console_filter.dart';
import 'dependencies.dart';
import 'listen.dart';
import 'stack_frames.dart';

/// What the lens knows now. A new object after each change, so a UI can
/// listen to [StateLens] and read this.
@immutable
class StateLensState {
  const StateLensState({
    this.armed = false,
    this.target,
    this.targetType,
    this.targetSource,
    this.readers = const <ReaderRef>[],
    this.dependencies = const <DependencyRef>[],
    this.rebuilds = const <FlowRebuild>[],
    this.fromSeq = 0,
    this.events = 0,
    this.window = Duration.zero,
    this.secondsLeft = 0,
    this.endedBecause,
    this.rebuildsRecorded = false,
  });

  /// Whether a window is open.
  final bool armed;

  /// The element the lens follows. Kept after the window ends, for the
  /// answer that follows it; null before the first arm.
  final Element? target;

  /// The target widget's type, and where it is created (`lib/x.dart:40`).
  final String? targetType;
  final String? targetSource;

  /// What the target's nearest state owners read (always computed, cheap).
  final List<ReaderRef> readers;

  /// The state objects behind [readers], one entry per object (by tag).
  final List<DependencyRef> dependencies;

  /// The elements that rebuilt for each frame with state events, so far.
  final List<FlowRebuild> rebuilds;

  /// The first seq of the window: events from here on belong to it.
  final int fromSeq;

  /// `state.notify` and `state.setState` events since arming.
  final int events;

  /// The length of the window, and the seconds left when this state was
  /// made (see [StateLens.secondsLeft] for the live value).
  final Duration window;
  final int secondsLeft;

  /// Why the last window ended: `window ended`, `stopped`, `target
  /// unmounted`, `re-targeted`, `disposed`. Null while armed.
  final String? endedBecause;

  /// Whether rebuilds are recorded: without them the lens names the
  /// notifies but not the readers that rebuilt.
  final bool rebuildsRecorded;
}

/// The state lens for one target element (PLAN-v3 Milestone 21, step 5).
///
/// [arm] computes what the target reads (always cheap), attaches
/// [StateListen] to the objects it reads and to the target's subtree,
/// starts [BuildStacks] and, on web, the [ConsoleFilter]; and for a window
/// (at most [maxWindow]) joins each state event with the elements that
/// rebuilt after it (step 4). The window ends by itself, on [stop], on
/// dispose and when the target unmounts: then every listener and global is
/// taken back.
///
/// One lens at a time: [arm] again re-targets. The chain stays readable
/// after the window ends ([chain]), until the next [arm].
class StateLens extends ChangeNotifier
    implements ValueListenable<StateLensState> {
  StateLens({
    required this.recorder,
    required this.resolver,
    required this.hooks,
    required this.rebuildSource,
    required this.content,
    required this.demandDetail,
    required this.releaseDetail,
    IdentityTags? tags,
    ConsoleFilter? consoleFilter,
    int Function()? clock,
    int maxPerSecond = BuildStacks.defaultMaxPerSecond,
  }) : tags = tags ?? IdentityTags.shared,
       _clock = clock ?? _realClock {
    _console = consoleFilter ?? createConsoleFilter(hooks);
    _stacks = BuildStacks(
      hooks: hooks,
      recorder: recorder,
      paths: resolver.paths,
      watched: _watchedElements,
      content: content,
      projectFiles: _projectFiles,
      maxPerSecond: maxPerSecond,
    );
    hooks.onDispose(() => stop(reason: 'disposed'));
  }

  /// The window when the caller names none.
  static const Duration defaultWindow = Duration(seconds: 30);

  /// Longest window; a longer request is cut to this.
  static const Duration maxWindow = Duration(seconds: 30);

  /// How long after the window ended the same target still gets its chain
  /// from `state_flow` instead of a new window.
  static const Duration recentFor = Duration(minutes: 2);

  /// The most rebuilt elements one join reads.
  static const int maxJoinElements = 600;

  /// The most joins kept.
  static const int maxRebuilds = 200;

  final TraceRecorder recorder;
  final SourceResolver resolver;
  final HookRegistry hooks;
  final RebuildSource rebuildSource;

  /// The element directly above the app's own widgets.
  final Element? Function() content;

  /// Level 3 (rebuilds) is held while armed: [demandDetail] when a window
  /// opens, [releaseDetail] when it ends.
  final void Function() demandDetail;
  final void Function() releaseDetail;

  final IdentityTags tags;
  final int Function() _clock;
  late final ConsoleFilter _console;
  late final BuildStacks _stacks;

  // The app's own files, read when a window opens (a walk of the tree) and
  // used for every stack of it.
  ProjectFiles? _files;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _realClock() => _stopwatch.elapsedMilliseconds;

  late final void Function(Set<Element>) _joinListener = _onRebuilt;
  StateListen? _listen;
  Timer? _timer;
  bool _demanded = false;
  bool _disposed = false;
  bool _armed = false;

  Element? _target;
  String? _targetType;
  String? _targetSource;
  List<ReaderRef> _readers = const <ReaderRef>[];
  List<DependencyRef> _dependencies = const <DependencyRef>[];
  final List<FlowRebuild> _rebuilds = <FlowRebuild>[];
  int _fromSeq = 0;
  int _processed = 0;
  int _events = 0;
  Duration _window = Duration.zero;
  int _endsAt = 0;
  int? _endedAt;
  String? _endedBecause;
  bool _rebuildsRecorded = false;
  BuildStacksSummary? _summary;
  StateLensState _state = const StateLensState();

  @override
  StateLensState get value => _state;

  /// Whether a window is open.
  bool get armed => _armed;

  /// The element followed, also after the window ended; null before the
  /// first arm.
  Element? get target => _target;

  /// Seconds left in the open window, rounded up; 0 when none is open.
  int get secondsLeft =>
      _armed ? ((_endsAt - _clock()).clamp(0, 1 << 30) / 1000).ceil() : 0;

  /// What the `setState` window saw (cap drops, a failure), or null.
  BuildStacksSummary? get stacksSummary => _summary ?? _stacks.summary;

  /// The console filter, for tests and the UI.
  ConsoleFilter get consoleFilter => _console;

  /// Whether [element] is the target of the open window.
  bool isTarget(Element element) =>
      _armed && identical(_target, element) && element.mounted;

  /// Whether [element] is the target of the open window, or of one that
  /// ended less than [within] ago. The chain of such a target is read, not
  /// armed again.
  bool wasTarget(Element element, {Duration within = recentFor}) {
    if (!identical(_target, element) || !element.mounted) return false;
    if (_armed) return true;
    final ended = _endedAt;
    return ended != null && _clock() - ended <= within.inMilliseconds;
  }

  /// The elements the `setState` stacks are matched to.
  Iterable<Element> _watchedElements() sync* {
    final target = _target;
    if (target != null && target.mounted) yield target;
    for (final reader in _readers) {
      if (reader.element.mounted) yield reader.element;
    }
  }

  ProjectFiles _projectFiles() => _files ?? ProjectFiles.none;

  // The files that the project's widgets were created in, under the app's
  // content. Empty when there is no content or no creation location.
  ProjectFiles _readProjectFiles() {
    try {
      final root = content();
      if (root == null || !root.mounted) return ProjectFiles.none;
      final uris = SourceIndex(resolver: resolver).localFiles(root: root);
      return ProjectFiles(uris, resolver.paths);
    } catch (_) {
      // Diagnostics run code written by widget authors.
      return ProjectFiles.none;
    }
  }

  /// Opens a window on [element], or moves the open one to it. [window] is
  /// cut to [maxWindow].
  void arm(Element element, {Duration window = defaultWindow}) {
    if (_disposed || !element.mounted) return;
    if (_armed) _teardown('re-targeted');
    final length = window > maxWindow
        ? maxWindow
        : (window < const Duration(seconds: 1)
              ? const Duration(seconds: 1)
              : window);
    _target = element;
    final entry = resolver.entryOf(element);
    _targetType = entry.name;
    final location = entry.location;
    _targetSource = location == null
        ? null
        : '${resolver.paths.relativePath(location.uri)}:${location.line}';
    _rebuilds.clear();
    _events = 0;
    _endedBecause = null;
    _endedAt = null;
    _summary = null;
    _fromSeq = _processed = recorder.nextSeq;
    _window = length;
    _rebuildsRecorded = false;
    _endsAt = _clock() + length.inMilliseconds;
    // Part 1: who reads what. Cheap, so it runs on every arm.
    _readers = const <ReaderRef>[];
    _dependencies = const <DependencyRef>[];
    try {
      _readers = nearestReaders(
        element,
        resolver,
        boundary: content(),
        tags: tags,
      );
      final seen = <String>{};
      _dependencies = [
        for (final reader in _readers)
          for (final d in reader.dependencies)
            if (seen.add(d.tag)) d,
      ];
    } catch (_) {
      // Diagnostics run code written by widget authors.
    }
    _files = _readProjectFiles();
    _armed = true;
    try {
      // Part 2: Pinpoint's listener on what the target reads and on the
      // builders in its subtree.
      final listen = _listen = StateListen(
        recorder: recorder,
        resolver: resolver,
        tags: tags,
        projectFiles: _projectFiles,
      );
      listen
        ..attachDependencies(_dependencies)
        ..attachSubtree(element);
      // Part 3: `setState` stacks, and no red lines in the browser console.
      _console.install();
      _stacks.start(length);
      demandDetail();
      _demanded = true;
      // After level 3 started: false when another tool holds the slot.
      _rebuildsRecorded = rebuildSource.running;
      rebuildSource.rebuiltListeners.add(_joinListener);
      _timer = Timer(length, () => stop(reason: 'window ended'));
    } catch (error) {
      debugPrint('pinpoint: state lens failed to arm: $error');
      _teardown('failed: $error');
    }
    _publish();
  }

  /// Closes the window: every listener, the flag, `debugPrint` and the
  /// console are what they were. The chain stays. Safe to call when no
  /// window is open.
  void stop({String reason = 'stopped'}) {
    if (!_armed) return;
    _teardown(reason);
    _publish();
  }

  void _teardown(String reason) {
    _armed = false;
    _timer?.cancel();
    _timer = null;
    rebuildSource.rebuiltListeners.remove(_joinListener);
    try {
      _listen?.stop();
    } catch (_) {
      // Keep going: the globals must come back.
    }
    _listen = null;
    try {
      _summary = _stacks.stop();
    } catch (_) {
      // Nothing left to undo.
    }
    try {
      _console.restore();
    } catch (_) {
      // Nothing left to undo.
    }
    if (_demanded) {
      _demanded = false;
      try {
        releaseDetail();
      } catch (_) {
        // The session may be gone.
      }
    }
    _endedBecause = reason;
    _endedAt = _clock();
  }

  /// A frame in which elements rebuilt (called by the rebuild source after
  /// each frame while it runs).
  void _onRebuilt(Set<Element> rebuilt) {
    if (!_armed) return;
    final target = _target;
    if (target == null || !target.mounted) {
      // Not here: the rebuild source is walking its listeners.
      scheduleMicrotask(() {
        if (_armed && !(_target?.mounted ?? false)) {
          stop(reason: 'target unmounted');
        }
      });
      return;
    }
    try {
      if (_join(rebuilt)) _publish();
    } catch (_) {
      // The lens only observes.
    }
  }

  // The state events since the last join, grouped by cause, each with the
  // elements that rebuilt because of them. Returns whether it joined any.
  bool _join(Set<Element> rebuilt) {
    final end = recorder.nextSeq;
    final groups = <String, List<TraceEvent>>{};
    for (var seq = _processed; seq < end; seq++) {
      final e = recorder.at(seq);
      if (e == null) continue;
      if (e.kind != TraceKind.stateNotify &&
          e.kind != TraceKind.stateSetState) {
        continue;
      }
      if (isNoiseSetState(e)) continue;
      groups
          .putIfAbsent(
            e.cause == null ? 'f${e.frame}' : 'c${e.cause}',
            () => <TraceEvent>[],
          )
          .add(e);
    }
    _processed = end;
    if (groups.isEmpty) return false;
    final listen = _listen;
    for (final events in groups.values) {
      _events += events.length;
      final owners = <String, String>{};
      for (final e in events) {
        if (e.kind == TraceKind.stateNotify && e.data['tag'] is String) {
          owners[e.data['tag']! as String] = '${e.data['owner'] ?? e.widget}';
        }
      }
      final setStateTypes = {
        for (final e in events)
          if (e.kind == TraceKind.stateSetState && e.widget != null) e.widget!,
      };
      final readers = <String, FlowReader>{};
      final builders = Map<Element, String>.identity();
      if (listen != null) {
        for (final tag in owners.keys) {
          for (final element in listen.elementsFor(tag)) {
            // A provider scope is where the object lives, not a reader.
            if (element is! InheritedElement) builders[element] = tag;
          }
        }
      }
      var read = 0;
      for (final element in rebuilt) {
        if (++read > maxJoinElements) break;
        if (!element.mounted) continue;
        final entry = resolver.entryOf(element);
        var asReader = false;
        final builderTag = builders[element];
        if (builderTag != null) {
          asReader = true;
          _add(
            readers,
            FlowReader(
              type: entry.name,
              via: 'builder',
              source: _where(entry),
              tag: builderTag,
              owner: owners[builderTag],
            ),
          );
        }
        final stateful = element is StatefulElement;
        if (entry.isLocal && (stateful || element is StatelessElement)) {
          for (final dependency in dependenciesOf(
            element,
            resolver,
            tags: tags,
          )) {
            if (!owners.containsKey(dependency.tag)) continue;
            asReader = true;
            _add(
              readers,
              FlowReader(
                type: entry.name,
                via: 'dependency',
                source: _where(entry),
                tag: dependency.tag,
                owner: dependency.type,
              ),
            );
          }
        }
        // A builder or a reader that also called `setState` is one reader.
        if (!asReader &&
            stateful &&
            entry.isLocal &&
            setStateTypes.contains(entry.name)) {
          _add(
            readers,
            FlowReader(
              type: entry.name,
              via: 'setState',
              source: _where(entry),
            ),
          );
        }
      }
      _rebuilds.add(
        FlowRebuild(
          frame: recorder.frameOf(),
          eventSeqs: {for (final e in events) e.seq},
          readers: readers.values.toList(),
        ),
      );
    }
    while (_rebuilds.length > maxRebuilds) {
      _rebuilds.removeAt(0);
    }
    return true;
  }

  static void _add(Map<String, FlowReader> readers, FlowReader reader) =>
      readers.putIfAbsent(reader.key, () => reader);

  String? _where(ChainEntry entry) {
    final location = entry.location;
    return location == null
        ? null
        : '${resolver.paths.relativePath(location.uri)}:${location.line}';
  }

  void _publish() {
    if (_disposed) return;
    _state = StateLensState(
      armed: _armed,
      target: _target,
      targetType: _targetType,
      targetSource: _targetSource,
      readers: _readers,
      dependencies: _dependencies,
      rebuilds: List<FlowRebuild>.unmodifiable(_rebuilds),
      fromSeq: _fromSeq,
      events: _events,
      window: _window,
      secondsLeft: secondsLeft,
      endedBecause: _armed ? null : _endedBecause,
      rebuildsRecorded: _rebuildsRecorded,
    );
    notifyListeners();
  }

  /// The chain since the window opened: per cause, what notified, what
  /// rebuilt and a coupling hint ([stateFlowChain]).
  Map<String, Object?> chain() {
    // Events after the last frame have no join yet: they show with an
    // empty `rebuilt` list.
    return stateFlowChain(recorder, fromSeq: _fromSeq, rebuilds: _rebuilds);
  }

  /// What the target reads, as the note's `stateOwners` shape.
  List<Map<String, Object?>> readersJson() => [
    for (final reader in _readers) reader.toInfo(resolver.paths).toJson(),
  ];

  /// Closes the window and drops the lens for good.
  @override
  void dispose() {
    if (_disposed) return;
    if (_armed) _teardown('disposed');
    _disposed = true;
    super.dispose();
  }
}
