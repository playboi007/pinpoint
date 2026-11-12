import 'package:flutter/widgets.dart';

import '../agent/state_dump.dart';
import '../model/annotation.dart' show NoteAnchor, clipText;
import '../model/trace_event.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';
import 'sources/rebuild_source.dart';
import 'trace_recorder.dart';
import 'trace_source.dart';

/// One watched widget: its element and the `State`s it follows.
class TraceWatch {
  TraceWatch._(this.id, this.element, this.anchor, this.widget, this.maxStates);

  /// For example `w1`.
  final String id;

  Element element;
  final NoteAnchor? anchor;

  /// The watched widget's type name.
  final String widget;

  /// Most local `State`s followed: the widget's own, then those above it.
  final int maxStates;

  /// The followed `State` elements, nearest first, with their last values.
  final List<StatefulElement> states = <StatefulElement>[];
  final Map<StatefulElement, Map<String, String>> _last =
      Map<StatefulElement, Map<String, String>>.identity();

  /// Whether the widget is gone and not found again yet.
  bool gone = false;
  final Stopwatch _sinceLookup = Stopwatch();

  /// Values the followed `State`s show, by state type: what the agent can
  /// expect to see change.
  Map<String, int> get shown => {
    for (final state in states)
      state.state.runtimeType.toString(): _last[state]?.length ?? 0,
  };
}

/// `state` events for watched widgets (level 3, PLAN-v2 Milestone 13,
/// step 8).
///
/// A watch follows one widget: on each rebuild of that widget or of a
/// local `State` above it, up to the route, it takes the state dump and
/// records only the values that changed. At most [maxWatches]. A watch is
/// why the parent's cache is visible next to the child's flags.
///
/// While the rebuild source holds `debugOnRebuildDirtyWidget`, only the
/// `State`s that rebuilt are read. When another tool holds the slot, every
/// watched `State` is read after each frame instead (at most 8 watches, so
/// the cost stays bounded): the watch still runs.
class WatchSource extends TraceSource with FrameWork {
  WatchSource({
    required this.rebuilds,
    required this.content,
    required this.resolver,
    required this.adapters,
  });

  static const int maxWatches = 8;

  static const Set<String> _frameworkProperties = {
    'lifecycle state',
    '_widget',
    '_element',
  };

  /// Default and most local `State`s a watch follows.
  static const int defaultStates = 3;
  static const int maxStates = 8;

  final RebuildSource rebuilds;
  final Element? Function() content;
  final SourceResolver resolver;

  /// The app's state adapters (`PinPointConfig.stateAdapters`).
  final List<StateAdapter> Function() adapters;

  final List<TraceWatch> _watches = <TraceWatch>[];
  late final void Function(Set<Element>) _listener = _onRebuilt;
  final Set<Element> _rebuilt = Set<Element>.identity();
  TraceRecorder? _recorder;
  int _next = 0;

  @override
  String get name => 'watch';

  @override
  int get level => 3;

  @override
  bool get isInput => false;

  /// The watches set now.
  List<TraceWatch> get watches => List<TraceWatch>.unmodifiable(_watches);

  @override
  void start(TraceRecorder recorder) {
    _recorder = recorder;
    if (!rebuilds.rebuiltListeners.contains(_listener)) {
      rebuilds.rebuiltListeners.add(_listener);
    }
  }

  @override
  void stop() {
    rebuilds.rebuiltListeners.remove(_listener);
    _recorder = null;
    _rebuilt.clear();
  }

  /// Watches [element] and up to [states] local `State`s from it up to its
  /// route. The first values are recorded as a `state` event with
  /// `initial: true`. Throws a [StateError] past [maxWatches].
  TraceWatch add(Element element, {int states = defaultStates}) {
    if (_watches.length >= maxWatches) {
      throw StateError(
        'at most $maxWatches watches; unwatch one first '
        '(${_watches.map((w) => w.id).join(', ')})',
      );
    }
    final root = content();
    final watch = TraceWatch._(
      'w${++_next}',
      element,
      root == null
          ? null
          : SourceIndex(resolver: resolver).anchorFor(element, root: root),
      element.widget.runtimeType.toString(),
      states.clamp(1, maxStates),
    );
    _collect(watch);
    _watches.add(watch);
    for (final state in watch.states) {
      _read(watch, state, initial: true);
    }
    return watch;
  }

  /// Removes the watch [id]; null removes every watch. Returns how many
  /// were removed.
  int remove(String? id) {
    final before = _watches.length;
    _watches.removeWhere((w) => id == null || w.id == id);
    return before - _watches.length;
  }

  void _onRebuilt(Set<Element> rebuilt) => _rebuilt.addAll(rebuilt);

  // A post-frame tick (FrameClock): never during the build phase, so a
  // state dump, which runs app code (`debugFillProperties`), sees a
  // finished tree (watch out for).
  @override
  void afterFrame() {
    if (_recorder == null || _watches.isEmpty) {
      _rebuilt.clear();
      return;
    }
    final everyState = !rebuilds.running;
    for (final watch in _watches) {
      if (!watch.element.mounted || watch.gone) {
        _findAgain(watch);
        continue;
      }
      for (final state in watch.states) {
        if (everyState || _rebuilt.contains(state)) _read(watch, state);
      }
    }
    _rebuilt.clear();
  }

  /// The widget's own `State` (or the nearest above it), then the local
  /// `State`s above it, up to the route or the app's content.
  void _collect(TraceWatch watch) {
    watch.states.clear();
    final element = watch.element;
    final root = content();
    bool isLocal(StatefulElement e) => resolver.entryOf(e).isLocal;
    if (element is StatefulElement) watch.states.add(element);
    element.visitAncestorElements((ancestor) {
      if (identical(ancestor, root)) return false;
      // The route's own scope: the states above it belong to the
      // navigator, not to this screen.
      if (ancestor.widget.runtimeType.toString() == '_ModalScope') {
        return false;
      }
      if (ancestor is StatefulElement &&
          (watch.states.isEmpty || isLocal(ancestor))) {
        watch.states.add(ancestor);
      }
      return watch.states.length < watch.maxStates;
    });
  }

  /// Reads [state] and records what changed since its last read.
  void _read(TraceWatch watch, StatefulElement state, {bool initial = false}) {
    final recorder = _recorder;
    if (recorder == null || !state.mounted) return;
    final values = _values(
      state,
      withAdapters: identical(state, watch.states.first),
    );
    final last = watch._last[state];
    watch._last[state] = values;
    final changed = <String, Object?>{};
    if (last == null || initial) {
      changed.addAll(values);
    } else {
      for (final MapEntry(:key, :value) in values.entries) {
        final before = last[key];
        if (before != value) changed[key] = [before, value];
      }
      for (final key in last.keys) {
        if (!values.containsKey(key)) changed[key] = [last[key], null];
      }
    }
    if (changed.isEmpty) return;
    final location = resolver.locationOf(state);
    recorder.add(
      TraceKind.state,
      widget: watch.widget,
      source: location == null
          ? null
          : '${resolver.paths.relativePath(location.uri)}:'
                '${location.line}:${location.column}',
      data: {
        'watch': watch.id,
        'state': state.state.runtimeType.toString(),
        if (initial || last == null) 'initial': true,
        // Already clipped strings, at most maxTraceItems of them.
        'changed': changed,
      },
    );
  }

  /// The values [state] shows in its diagnostics, as text, and the state
  /// adapters' values for the watched widget. Diagnostics run app code:
  /// one that throws leaves the map short.
  Map<String, String> _values(
    StatefulElement state, {
    required bool withAdapters,
  }) {
    final values = <String, String>{};
    try {
      for (final property in state.state.toDiagnosticsNode().getProperties()) {
        final name = property.name;
        // `State` adds these three itself; they never change what the
        // screen does.
        if (name == null || _frameworkProperties.contains(name)) continue;
        values[name] = clipText(property.toDescription(), maxTraceChars);
        if (values.length >= maxTraceItems) break;
      }
    } catch (_) {
      // Keep what was read.
    }
    if (withAdapters) {
      for (final adapter in adapters()) {
        try {
          final read = adapter.read(state);
          if (read == null) continue;
          for (final MapEntry(:key, :value) in read.entries.take(10)) {
            values['${adapter.name}.$key'] = clipText('$value', maxTraceChars);
          }
        } catch (error) {
          values[adapter.name] = clipText('failed: $error', maxTraceChars);
        }
      }
    }
    return values;
  }

  /// A watched widget that is gone: look for it again by its anchor, at
  /// most once a second; found, follow it from there.
  void _findAgain(TraceWatch watch) {
    final recorder = _recorder;
    if (!watch.gone) {
      watch.gone = true;
      watch._sinceLookup
        ..reset()
        ..start();
      recorder?.add(
        TraceKind.state,
        widget: watch.widget,
        data: {'watch': watch.id, 'gone': true},
      );
      return;
    }
    if (watch._sinceLookup.elapsedMilliseconds < 1000) return;
    watch._sinceLookup
      ..reset()
      ..start();
    final anchor = watch.anchor;
    final root = content();
    if (anchor == null || !anchor.resolvable || root == null) return;
    final again = SourceIndex(resolver: resolver).resolve(anchor, root: root);
    if (again == null) return;
    watch
      ..element = again
      ..gone = false
      .._last.clear();
    _collect(watch);
    for (final state in watch.states) {
      _read(watch, state, initial: true);
    }
  }
}
