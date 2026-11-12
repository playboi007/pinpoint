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
    this.causes = true,
    this.bodies = true,
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

  /// Whether events name the entry that started them (PLAN-v2 Milestone
  /// 14). Needs `PinPoint.run` around `runApp`; pass the same config there:
  ///
  /// ```dart
  /// const trace = TraceConfig();
  /// void main() => PinPoint.run(() => runApp(const MyApp()), trace: trace);
  /// ```
  ///
  /// The zone cannot start later, so it is the one costly part that runs
  /// for the whole run: one child zone per entry (a pointer packet, a
  /// frame). False: `PinPoint.run` calls its body with no zone, and events
  /// have no cause.
  final bool causes;

  /// Whether the network source reads answers (level 2): to hash them, so
  /// rules can tell a repeated answer, and to keep up to 256 KB each for a
  /// tape. Bodies hold personal data and cost memory; they stay in the app
  /// and never go into an event. False: no response is ever cloned, and
  /// events have no body hash.
  final bool bodies;
}
