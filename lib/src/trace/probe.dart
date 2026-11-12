import 'package:flutter/foundation.dart';

import '../model/annotation.dart' show clipText;
import '../model/trace_event.dart';
import 'trace_session.dart';

/// Pinpoint's entry points for app code (PLAN-v2, "Public surface added").
abstract final class PinPoint {
  /// Records [values] each time this line runs, as a `probe` event named
  /// [name]:
  ///
  /// ```dart
  /// PinPoint.probe('existing.ensureLoaded', {
  ///   'type': type,
  ///   'loaded': _loadedForType,
  /// });
  /// ```
  ///
  /// A probe reads what diagnostics cannot show, such as a private field.
  /// The agent adds probes, hot reloads, reads them with `get_trace`, and
  /// removes them; `list_probes` finds the ones left in `lib/`.
  ///
  /// Values pass through the same clipping as a state dump: strings to
  /// 200 characters, lists and maps to 20 entries, other objects as their
  /// text. Does nothing when Pinpoint or the recorder is off, and in
  /// release builds.
  static void probe(String name, [Map<String, Object?> values = const {}]) {
    if (kReleaseMode) return;
    final session = TraceSession.current;
    if (session == null) return;
    try {
      session.recorder.add(
        TraceKind.probe,
        data: {'name': clipText(name, 80), 'values': traceValues(values)},
      );
    } catch (error) {
      // The recorder only observes (rule 11): a probe never throws into
      // app code.
      debugPrint('pinpoint: probe $name failed: $error');
    }
  }
}
