import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../agent/state_dump.dart';
import '../core/rebuild_hook.dart';
import '../model/trace_event.dart';
import '../search/source_resolver.dart';
import 'frame_clock.dart';
import 'sources/frame_source.dart';
import 'sources/rebuild_source.dart';
import 'trace_config.dart';
import 'trace_recorder.dart';
import 'trace_source.dart';
import 'watch.dart';

/// Why level 3 runs. Level 3 starts with the first reason and stops with
/// the last (PLAN-v2, "Source levels").
abstract final class TraceDemand {
  /// The Timeline panel is open.
  static const String timeline = 'timeline';

  /// The agent called `trace_detail({on: true})`.
  static const String agent = 'agent';

  /// At least one watch is set.
  static const String watch = 'watch';
}

/// The flight recorder of one `PinPointWrapper`: the recorder, its sources
/// and the level 3 switch.
///
/// The recorder and its level 1 sources run from wrapper start, not from a
/// "record" button: a bug is over by the time the user thinks of recording
/// it. Level 3 runs only while a [TraceDemand] holds it.
///
/// The running session is a static, [current], not a field of the overlay's
/// `State`: a new instance field is undefined after a web hot reload
/// (api-notes item 29, watch out for), and `PinPoint.probe` needs to find
/// it from anywhere.
class TraceSession {
  TraceSession({
    required this.config,
    required RebuildHook rebuildHook,
    required Element? Function() content,
    required SourceResolver resolver,
    List<TraceSource> builtIn = const <TraceSource>[],
    TraceRecorder? recorder,
    Object? owner,
    List<StateAdapter> Function()? adapters,
  }) : recorder =
           recorder ??
           TraceRecorder(
             maxEvents: config.maxEvents,
             maxBytes: config.maxBytes,
           ) {
    rebuildSource = RebuildSource(
      hook: rebuildHook,
      content: content,
      resolver: resolver,
      onLost: _rebuildsLost,
    );
    frameSource = FrameSource(builds: () => rebuildSource.lastTotal);
    watchSource = WatchSource(
      rebuilds: rebuildSource,
      content: content,
      resolver: resolver,
      adapters: adapters ?? () => const <StateAdapter>[],
    );
    // The rebuild source flushes before the sources that read what rebuilt
    // (watches); the frame event is written last of all.
    _sources = [
      frameSource,
      rebuildSource,
      watchSource,
      ...builtIn,
      ...config.sources,
    ];
    this.recorder.frameOf = () => clock.frame;
    for (final source in _sources) {
      if (source.level < 3) _start(source);
    }
    clock.addListener(_afterFrame);
    current = this;
    if (owner != null) _owned[owner] = this;
  }

  /// The running session, or null when Pinpoint or the recorder is off.
  /// With two wrappers (Flutter mounts a new wrapper State before it
  /// disposes the old one, api-notes item 25), the newest.
  static TraceSession? current;

  /// The session each wrapper State started, so it stops its own and not
  /// a newer one. A static, not a State field (api-notes item 29).
  static final Expando<TraceSession> _owned = Expando<TraceSession>(
    'pinpoint trace',
  );

  /// The session [owner] started, or null.
  static TraceSession? ownedBy(Object owner) => _owned[owner];

  /// Stops the session [owner] started, if any.
  static void stopOwnedBy(Object owner) {
    _owned[owner]?.dispose();
    _owned[owner] = null;
  }

  final TraceConfig config;
  final TraceRecorder recorder;
  final FrameClock clock = FrameClock();

  late final FrameSource frameSource;
  late final RebuildSource rebuildSource;
  late final WatchSource watchSource;
  late final List<TraceSource> _sources;
  final Set<TraceSource> _started = Set<TraceSource>.identity();
  final Set<String> _demand = <String>{};
  bool _disposed = false;

  /// Every source, built-in and the app's.
  List<TraceSource> get sources => List<TraceSource>.unmodifiable(_sources);

  /// Whether level 3 runs.
  bool get detailOn => _demand.isNotEmpty;

  /// What holds level 3 now.
  Set<String> get demands => Set<String>.unmodifiable(_demand);

  /// The source named [name], or null.
  TraceSource? source(String name) {
    for (final s in _sources) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Names of the sources running now. The rebuild source counts only
  /// while it holds the slot.
  List<String> get running => [
    for (final s in _sources)
      if (_started.contains(s) && (s is! RebuildSource || s.running)) s.name,
  ];

  void _start(TraceSource source) {
    try {
      source.start(recorder);
      _started.add(source);
    } catch (error) {
      debugPrint('pinpoint: trace source ${source.name} failed: $error');
    }
  }

  void _stop(TraceSource source) {
    if (!_started.remove(source)) return;
    try {
      source.stop();
    } catch (error) {
      debugPrint('pinpoint: trace source ${source.name} failed: $error');
    }
  }

  /// Runs after each frame: the sources' frame work, then the frame event,
  /// which carries the recorder's own time and the rebuild count.
  void _afterFrame() {
    if (_disposed) return;
    final watch = Stopwatch()..start();
    for (final source in _sources) {
      if (identical(source, frameSource)) continue;
      if (source is FrameWork && _started.contains(source)) {
        try {
          source.afterFrame();
        } catch (error) {
          debugPrint('pinpoint: trace source ${source.name} failed: $error');
        }
      }
    }
    recorder.charge(watch.elapsedMicroseconds);
    if (_started.contains(frameSource)) frameSource.afterFrame();
  }

  /// Adds [reason] to what holds level 3. The first reason starts it.
  void demand(String reason) {
    if (_disposed || !_demand.add(reason)) return;
    if (_demand.length == 1) _startDetail();
  }

  /// Removes [reason]. The last reason stops level 3.
  void release(String reason) {
    if (_disposed || !_demand.remove(reason)) return;
    if (_demand.isEmpty) _stopDetail();
  }

  /// Tries the rebuild source again, for example after DevTools let the
  /// slot go. Records the start like a new `detail.on`.
  void retryRebuilds() {
    if (!detailOn || rebuildSource.running) return;
    rebuildSource.start(recorder);
    if (rebuildSource.running) {
      recorder.startRebuildCoverage();
      recorder.add(
        TraceKind.detailOn,
        data: {
          'sources': [rebuildSource.name],
        },
      );
    }
  }

  void _startDetail() {
    for (final source in _sources) {
      if (source.level == 3) _start(source);
    }
    if (rebuildSource.running) recorder.startRebuildCoverage();
    recorder.add(
      TraceKind.detailOn,
      data: {
        'sources': [
          for (final s in _sources)
            if (s.level == 3 && running.contains(s.name)) s.name,
        ],
        'for': [..._demand],
        'reason': ?rebuildSource.failure,
      },
    );
  }

  void _stopDetail() {
    for (final source in _sources) {
      if (source.level == 3) _stop(source);
    }
    recorder
      ..endRebuildCoverage()
      ..add(TraceKind.detailOff);
  }

  void _rebuildsLost() {
    recorder
      ..endRebuildCoverage()
      ..add(
        TraceKind.detailOff,
        data: {
          'sources': [rebuildSource.name],
          'reason': 'rebuild slot taken',
        },
      );
  }

  /// Watches [element] (PLAN-v2 Milestone 13, step 8). Level 3 runs while
  /// any watch is set.
  TraceWatch watch(Element element, {int states = WatchSource.defaultStates}) {
    // Level 3 first, so the watch's first values are recorded.
    demand(TraceDemand.watch);
    try {
      return watchSource.add(element, states: states);
    } catch (_) {
      if (watchSource.watches.isEmpty) release(TraceDemand.watch);
      rethrow;
    }
  }

  /// Removes the watch [id], or every watch for null. The last one
  /// releases level 3. Returns how many were removed.
  int unwatch(String? id) {
    final removed = watchSource.remove(id);
    if (watchSource.watches.isEmpty) release(TraceDemand.watch);
    return removed;
  }

  /// Recorder time (ms) when Pinpoint last left idle, or null while idle.
  /// A note's trace ends here: the user saw the problem, then started
  /// picking, and wrote the comment after.
  int? activeSince;

  /// Pinpoint's overlay left idle ([active]) or went back to it.
  void pinpointActive(bool active) {
    if (!active) {
      activeSince = null;
    } else {
      activeSince ??= recorder.now;
    }
  }

  /// Most mark thumbnails kept; the oldest go first.
  static const int maxThumbnails = 20;

  /// Takes a 400 px wide image of the app for a mark, or null. Set by the
  /// wrapper.
  Future<Uint8List?> Function()? thumbnail;

  /// The marks' thumbnails, by the mark's seq.
  final Map<int, Uint8List> thumbnails = <int, Uint8List>{};

  /// Records a mark (PLAN-v2 Milestone 13, step 9): a moment the user (M
  /// key, Timeline) or the agent (`mark`) points at, with an optional
  /// sentence, and takes a thumbnail of the app.
  TraceEvent mark({String? text, String by = 'user'}) {
    final event = recorder.add(
      TraceKind.mark,
      data: {'text': traceValue(text ?? ''), 'by': by},
    );
    final capture = thumbnail;
    if (capture != null) {
      unawaited(
        capture().then(
          (png) {
            if (png == null || _disposed) return;
            thumbnails[event.seq] = png;
            while (thumbnails.length > maxThumbnails) {
              thumbnails.remove(thumbnails.keys.first);
            }
          },
          onError: (Object error) =>
              debugPrint('pinpoint: mark thumbnail failed: $error'),
        ),
      );
    }
    return event;
  }

  /// Names the mark [seq]. False when it is no longer held.
  bool renameMark(int seq, String text) {
    for (final event in recorder.newestFirst) {
      if (event.seq < seq) break;
      if (event.seq == seq && event.kind == TraceKind.mark) {
        event.data['text'] = traceValue(text);
        return true;
      }
    }
    return false;
  }

  /// What `trace_detail` answers: whether level 3 runs, for what, which
  /// sources run, and whether rebuilds are recorded.
  Map<String, Object?> detailStatus() => {
    'on': detailOn,
    'for': [..._demand],
    'running': running,
    'rebuilds': rebuildSource.running
        ? 'recorded'
        : detailOn
        ? 'not recorded: rebuild slot taken (another tool holds '
              'debugOnRebuildDirtyWidget, for example DevTools "track '
              'rebuilds"); the other level 3 sources run'
        : 'not recorded (level 3 is off)',
  };

  /// Stops every source. The record goes with the session.
  void dispose() {
    if (_disposed) return;
    for (final source in _sources.reversed) {
      _stop(source);
    }
    _demand.clear();
    _disposed = true;
    clock.dispose();
    if (identical(current, this)) current = null;
  }
}
