import 'package:flutter/foundation.dart';

import '../../detect/error_capture.dart';
import '../../model/annotation.dart' show clipText;
import '../../model/trace_event.dart';
import '../cause_zone.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `error` events (level 1), from `ErrorCapture` while the
/// user has "Capture errors" on (the default). It adds no handler of its
/// own: `ErrorCapture` tells it of each error inside its guarded handler.
///
/// With `PinPoint.run`, the cause zone also reports errors nobody caught
/// ([uncaught]): an `async` handler that nobody awaits fails there, and on
/// web those errors otherwise show only in the browser console (api-notes
/// item 29).
class ErrorSource extends TraceSource {
  TraceRecorder? _recorder;
  late final ErrorListener _listener = _onError;

  /// The running error source, for the cause zone's handler.
  static ErrorSource? _running;

  /// The last error [uncaught] recorded. Outside web the same error then
  /// reaches `PlatformDispatcher.onError`, and `ErrorCapture` reports it
  /// again; it is recorded once.
  Object? _lastUncaught;

  /// Records an error that no zone handled, with the [cause] it happened
  /// in. Called from the cause zone's error handler, which guards it.
  static void uncaught(Object error, TraceCause? cause) {
    final source = _running;
    if (source == null) return;
    source._lastUncaught = error;
    source._record(error, null, cause: cause, uncaught: true);
  }

  /// Reports [error] as `ErrorCapture` would, for tests.
  @visibleForTesting
  void debugReport(Object error) => _onError(error, null);

  @override
  String get name => 'error';

  @override
  int get level => 1;

  @override
  bool get isInput => false;

  @override
  void start(TraceRecorder recorder) {
    _recorder = recorder;
    _running = this;
    if (!ErrorCapture.listeners.contains(_listener)) {
      ErrorCapture.listeners.add(_listener);
    }
  }

  @override
  void stop() {
    _recorder = null;
    if (identical(_running, this)) _running = null;
    ErrorCapture.listeners.remove(_listener);
  }

  // Runs inside the error handler, which ErrorCapture guards.
  void _onError(Object error, String? library) {
    if (identical(error, _lastUncaught)) return;
    _record(error, library);
  }

  void _record(
    Object error,
    String? library, {
    TraceCause? cause,
    bool uncaught = false,
  }) {
    final recorder = _recorder;
    if (recorder == null) return;
    String message;
    try {
      message = error is FlutterError
          ? error.message.split('\n').first
          : '$error'.split('\n').first;
    } catch (_) {
      message = '';
    }
    recorder.add(
      TraceKind.error,
      data: {
        'type': error.runtimeType.toString(),
        'message': clipText(message, 160),
        'library': ?library,
        if (uncaught) 'uncaught': true,
      },
      cause: cause,
    );
  }
}
