import 'dart:async';
import 'dart:ui' show KeyData, PointerDataPacket;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../model/annotation.dart' show clipText;
import '../model/trace_event.dart';
import '../tape/tape_boot.dart';
import 'cause_zone.dart';
import 'sources/error_source.dart';
import 'trace_config.dart';
import 'trace_session.dart';

/// Pinpoint's entry points for app code (PLAN-v2, "Public surface added").
abstract final class PinPoint {
  /// Runs [body] in Pinpoint's zone, so every recorded event names the
  /// entry that started it (a tap, a frame, a key) and errors nobody caught
  /// are recorded (PLAN-v2 Milestone 14):
  ///
  /// ```dart
  /// void main() => PinPoint.run(() => runApp(const MyApp()));
  /// ```
  ///
  /// Optional: everything else works without it. Wrap both the binding's
  /// set-up and `runApp`: Flutter prints "Zone mismatch" when the binding
  /// is set up in one zone and `runApp` runs in another
  /// (`foundation/binding.dart:438`). So call it first in `main`, around
  /// `WidgetsFlutterBinding.ensureInitialized()` too. When the binding
  /// already exists, it runs [body] with no zone, records no causes, and
  /// prints one hint.
  ///
  /// [trace] should be the config given to `PinPointConfig.trace`:
  /// `TraceConfig(causes: false)` or `enabled: false` runs [body] with no
  /// zone. Outside debug builds it only calls [body].
  ///
  /// Limits: a post-frame callback is stored with no zone
  /// (`scheduler/binding.dart:818`), so it runs with the cause of the frame
  /// that calls it. A stream or a periodic timer keeps the cause of the
  /// moment it was listened to or made, for as long as it runs.
  static R run<R>(
    R Function() body, {
    TraceConfig trace = const TraceConfig(),
  }) {
    // A replay restarted this page (PLAN-v2 Milestone 15, step 7): load
    // the tape before the app starts, so the network source can answer the
    // app's first request from it. Only for a body that returns nothing
    // (`runApp`), whose result nobody waits for.
    if (kDebugMode && trace.enabled && null is R && TapeBoot.flag != null) {
      return _inZone(() {
        unawaited(
          TapeBoot.load(restoreStorage: trace.storage).then((tape) {
            TapeBoot.loadedBeforeApp = tape != null;
            body();
          }),
        );
        return null as R;
      }, trace);
    }
    return _inZone(body, trace);
  }

  static R _inZone<R>(R Function() body, TraceConfig trace) {
    if (!kDebugMode || !trace.enabled || !trace.causes) return body();
    if (CauseZone.current != null) return body();
    if (BindingBase.debugBindingType() != null) {
      // Watch out for: the binding is already set up in another zone, so
      // a zone now would give "Zone mismatch" at runApp. Record no causes.
      if (CauseZone.unavailable == null) {
        CauseZone.unavailable =
            'the binding existed before PinPoint.run; call PinPoint.run '
            'first in main';
        debugPrint(
          'pinpoint: no causes. The Flutter binding existed before '
          'PinPoint.run, so the app runs without its zone. Call '
          'PinPoint.run first in main, around ensureInitialized and runApp.',
        );
      }
      return body();
    }
    final zone = CauseZone(
      kindOf: _kindOf,
      inFrame: _inFrame,
      ready: _ready,
      onUncaught: (error, stack, cause) => ErrorSource.uncaught(error, cause),
    );
    return zone.run(body);
  }

  static String? _kindOf(Object? argument) => switch (argument) {
    PointerDataPacket() => CauseKind.pointer,
    // `onBeginFrame` takes the frame's time stamp.
    Duration() => CauseKind.frame,
    KeyData() => CauseKind.key,
    _ => null,
  };

  // `onDrawFrame` is called while the phase is still the one
  // `handleBeginFrame` left (`scheduler/binding.dart`, handleDrawFrame).
  static bool _inFrame() =>
      SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.midFrameMicrotasks;

  // The app runs once `runApp` attached its root. Until then the binding's
  // zone must stay the current one for `runApp` (watch out for).
  static bool _ready() {
    if (BindingBase.debugBindingType() == null) return false;
    try {
      return WidgetsBinding.instance.rootElement != null;
    } catch (_) {
      return false;
    }
  }

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
