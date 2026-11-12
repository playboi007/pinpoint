import 'package:flutter/foundation.dart';

import '../../detect/error_capture.dart';
import '../../model/annotation.dart' show clipText;
import '../../model/trace_event.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `error` events (level 1), from `ErrorCapture` of Milestone 10 while the
/// user has "Capture errors" on (the default). It adds no handler of its
/// own: `ErrorCapture` tells it of each error inside its guarded handler.
class ErrorSource extends TraceSource {
  TraceRecorder? _recorder;
  late final ErrorListener _listener = _onError;

  @override
  String get name => 'error';

  @override
  int get level => 1;

  @override
  bool get isInput => false;

  @override
  void start(TraceRecorder recorder) {
    _recorder = recorder;
    if (!ErrorCapture.listeners.contains(_listener)) {
      ErrorCapture.listeners.add(_listener);
    }
  }

  @override
  void stop() {
    _recorder = null;
    ErrorCapture.listeners.remove(_listener);
  }

  // Runs inside the error handler, which ErrorCapture guards.
  void _onError(Object error, String? library) {
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
      },
    );
  }
}
