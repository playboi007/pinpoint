import 'dart:async';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../model/annotation.dart' show clipText;
import '../search/render_search.dart';
import 'detector.dart';
import 'overflow_detector.dart' show formatPixels;

/// Captures errors as findings: chains `FlutterError.onError` and
/// `PlatformDispatcher.onError` through [HookRegistry], and always calls
/// the previous handler.
///
/// An overflow error names its render object, so the finding has the exact
/// widget and Flutter's amount. Any other error keeps its text, the first
/// eight stack frames, and the widget named in its diagnostics.
class ErrorCapture {
  ErrorCapture({
    required HookRegistry registry,
    required this.onFindings,
    required this.locator,
  }) : _flutter = registry.slot<FlutterExceptionHandler?>(
         key: #pinpointFlutterOnError,
         read: () => FlutterError.onError,
         write: (value) => FlutterError.onError = value,
       ),
       _platform = registry.slot<ErrorCallback?>(
         key: #pinpointPlatformOnError,
         read: () => PlatformDispatcher.instance.onError,
         write: (value) => PlatformDispatcher.instance.onError = value,
       );

  /// Makes the next error fail inside Pinpoint's handler, to test that it
  /// only prints.
  @visibleForTesting
  static bool debugFailHandler = false;

  /// At most this many errors wait for one drain; more are dropped (an
  /// error in every frame of an animation).
  static const int maxPending = 50;

  /// Gets the findings, after the frame the errors happened in.
  final void Function(List<Finding> findings) onFindings;

  /// A locator for the app as it is now.
  final FindingLocator Function() locator;

  final GlobalSlot<FlutterExceptionHandler?> _flutter;
  final GlobalSlot<ErrorCallback?> _platform;

  // The values written, kept so the slot can tell them apart.
  late final FlutterExceptionHandler _flutterHandler = _onFlutterError;
  late final ErrorCallback _platformHandler = _onPlatformError;

  final List<_Captured> _pending = <_Captured>[];
  Timer? _drainTimer;
  bool _installed = false;

  /// Whether the handlers are installed.
  bool get installed => _installed;

  void install() {
    if (_installed) return;
    _installed = true;
    _flutter.set(_flutterHandler);
    _platform.set(_platformHandler);
  }

  /// Puts the previous handlers back, unless someone else wrote the slots
  /// after us.
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _flutter.release();
    _platform.release();
    _pending.clear();
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  // Runs during build, layout or paint. Never touch widgets or call
  // setState here: queue, and turn the queue into findings after the frame
  // (watch out for). An error inside this handler would come back to it
  // and loop, so its body only prints (watch out for).
  void _onFlutterError(FlutterErrorDetails details) {
    if (_installed) {
      try {
        if (debugFailHandler) throw StateError('debugFailHandler');
        _enqueue(_Captured(details: details));
      } catch (error) {
        debugPrint('pinpoint: error capture failed: $error');
      }
    }
    // Someone who wrote the slot after us and chained to us still reaches
    // the handler from before us.
    _flutter.previous?.call(details);
  }

  bool _onPlatformError(Object error, StackTrace stack) {
    if (_installed) {
      try {
        if (debugFailHandler) throw StateError('debugFailHandler');
        _enqueue(_Captured(error: error, stack: stack));
      } catch (failure) {
        debugPrint('pinpoint: error capture failed: $failure');
      }
    }
    return _platform.previous?.call(error, stack) ?? false;
  }

  void _enqueue(_Captured captured) {
    if (_pending.length >= maxPending) return;
    _pending.add(captured);
    // A one-shot timer runs after the current frame; it forces no frame
    // (engineering rule 2).
    _drainTimer ??= Timer(Duration.zero, _drain);
  }

  void _drain() {
    _drainTimer = null;
    if (!_installed) return;
    final batch = List<_Captured>.of(_pending);
    _pending.clear();
    final findings = <Finding>[];
    try {
      final place = locator();
      for (final captured in batch) {
        try {
          final finding = captured.details != null
              ? findingForError(captured.details!, place)
              : findingForUncaught(captured.error!, captured.stack);
          if (finding != null) findings.add(finding);
        } catch (error) {
          debugPrint('pinpoint: error capture failed: $error');
        }
      }
    } catch (error) {
      debugPrint('pinpoint: error capture failed: $error');
    }
    if (findings.isNotEmpty) onFindings(findings);
  }
}

class _Captured {
  _Captured({this.details, this.error, this.stack});

  final FlutterErrorDetails? details;
  final Object? error;
  final StackTrace? stack;
}

/// Longest exception text kept (engineering rule 9).
const int _maxText = 300;

/// Longest stack frame kept.
const int _maxFrame = 200;

final RegExp _overflow = RegExp(
  r'overflowed by ([\d.]+) pixels on the (left|right|top|bottom)',
);

/// The finding for a reported error, or null for an error in Pinpoint's
/// own UI.
@visibleForTesting
Finding? findingForError(FlutterErrorDetails details, FindingLocator locator) {
  final message = details.exceptionAsString();
  // There is no DiagnosticsProperty<RenderObject> (docs/api-notes.md, item
  // 10): the render object is the value of the `describeForError` node,
  // and the element comes with DiagnosticsDebugCreator.
  var info = const <DiagnosticsNode>[];
  try {
    info = details.informationCollector?.call().toList() ?? info;
  } catch (_) {
    // A collector that throws: the exception text is still worth keeping.
  }
  RenderObject? renderObject;
  Element? element;
  for (final node in info) {
    final value = node.value;
    if (element == null && value is DebugCreator) element = value.element;
    if (renderObject == null && value is RenderObject) renderObject = value;
  }
  final place = renderObject == null ? null : locator.locate(renderObject);
  element ??= place?.element;
  if (element != null && !locator.isInApp(element)) return null;
  final widget = element == null ? null : _typeOf(element);

  final overflow = _overflow.firstMatch(message);
  if (overflow != null && renderObject != null) {
    final amount = double.parse(overflow[1]!);
    final side = overflow[2]!;
    final horizontal = side == 'left' || side == 'right';
    final name = widget ?? renderObject.runtimeType.toString();
    return Finding(
      kind: 'overflow',
      severity: Severity.error,
      summary:
          '$name overflows by ${formatPixels(amount)} px '
          '${horizontal ? 'on the' : 'at the'} $side',
      element: element,
      rect: RenderSearch.globalRectOf(renderObject),
      source: place?.source,
      route: place?.route,
      data: {
        'widget': name,
        'overflow': amount,
        'side': side,
        'axis': horizontal ? 'horizontal' : 'vertical',
        'captured': true,
      },
    );
  }

  final type = details.exception.runtimeType.toString();
  return Finding(
    kind: 'exception',
    severity: Severity.error,
    summary:
        '$type${widget == null ? '' : ' in $widget'}: '
        '${clipText(message.split('\n').first, 120)}',
    element: element,
    rect: renderObject == null ? null : RenderSearch.globalRectOf(renderObject),
    source:
        place?.source ?? (element == null ? null : locator.sourceOf(element)),
    route: place?.route,
    data: {
      'exception': clipText(message, _maxText),
      'stack': _frames(details.stack),
      'widget': ?widget,
      'library': ?details.library,
      if (details.context case final context?)
        'context': clipText(context.toDescription(), _maxFrame),
    },
  );
}

/// The finding for an error nothing caught, from `PlatformDispatcher`.
@visibleForTesting
Finding findingForUncaught(Object error, StackTrace? stack) {
  final message = error.toString();
  return Finding(
    kind: 'exception',
    severity: Severity.error,
    summary:
        'Uncaught ${error.runtimeType}: '
        '${clipText(message.split('\n').first, 120)}',
    data: {'exception': clipText(message, _maxText), 'stack': _frames(stack)},
  );
}

/// The first eight frames of [stack], each cut to 200 characters.
List<String> _frames(StackTrace? stack) {
  if (stack == null) return const <String>[];
  return [
    for (final line in stack.toString().split('\n').take(40))
      if (line.trim().isNotEmpty) clipText(line.trim(), _maxFrame),
  ].take(8).toList();
}

String? _typeOf(Element element) {
  try {
    return element.widget.runtimeType.toString();
  } catch (_) {
    return null;
  }
}
