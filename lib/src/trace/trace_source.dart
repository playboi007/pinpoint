import 'trace_recorder.dart';

/// Where a [TraceSource]'s events come from, and when it runs.
///
/// - 1: always, from wrapper start. Cheap, takes no global slot another
///   tool wants.
/// - 2: on by default behind one switch (network bodies).
/// - 3: only while something needs it: the Timeline is open, a watch is
///   set, or the agent asked with `trace_detail`.
abstract class TraceSource {
  const TraceSource();

  /// A short name, for example `pointer`. Shown by `trace_detail`.
  String get name;

  /// 1, 2 or 3; see above. A source that takes a slot another tool wants,
  /// or costs much per event, is level 3.
  int get level;

  /// Whether its events are input that a tape replays.
  bool get isInput;

  /// Starts recording into [recorder]. Called once per start; a source
  /// that is already running ignores it.
  void start(TraceRecorder recorder);

  /// Stops and gives back every slot and listener it took.
  void stop();
}

/// A source that also does work once after each frame the app draws: it
/// reads a value and records a change, or writes what it counted during
/// the frame.
mixin FrameWork on TraceSource {
  /// Called after each frame while the source runs, outside the build
  /// phase.
  void afterFrame();
}
