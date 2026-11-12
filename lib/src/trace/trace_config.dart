import 'package:flutter/foundation.dart';

import 'trace_recorder.dart';
import 'trace_source.dart';

/// Settings for the flight recorder (PLAN-v2 Milestone 13), in
/// `PinPointConfig.trace`.
@immutable
class TraceConfig {
  const TraceConfig({
    this.enabled = true,
    this.maxEvents = TraceRecorder.defaultMaxEvents,
    this.maxBytes = TraceRecorder.defaultMaxBytes,
    this.sources = const <TraceSource>[],
  }) : assert(maxEvents > 0),
       assert(maxBytes > 0);

  /// The real off switch. False: no recorder, no source, no hook, and
  /// `PinPoint.probe` returns at its first line; v1 is as it was.
  ///
  /// The recorder changes timing a little, so a race that needs exact
  /// timing can hide while it runs. If a bug goes away with Pinpoint on,
  /// turn this off first.
  final bool enabled;

  /// Most events held; the oldest go first.
  final int maxEvents;

  /// Most bytes held, roughly; the oldest go first.
  final int maxBytes;

  /// The app's own sources, started with the built-in ones by their level.
  final List<TraceSource> sources;
}
