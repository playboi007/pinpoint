import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../model/trace_event.dart';
import '../search/source_resolver.dart';
import '../trace/cause_zone.dart';
import '../trace/state_flow.dart';
import '../trace/trace_recorder.dart';

/// Names a hover cause (PLAN-v3 Milestone 21b, "Story view").
///
/// The pointer source does not record hover moves (hundreds a second), so a
/// state change that a hover makes has a cause with no input to name it.
/// While the lens is armed this adds one global pointer route. It does
/// nothing for a hover move unless a state event happened in the same
/// pointer packet (the mouse tracker calls `onEnter` and `onExit` before the
/// route runs). Only then it runs a hit test, and it records an
/// `input.pointer` event with phase `hover` only when the local widget under
/// the pointer is not the one found the last time: an enter or a leave,
/// never every move.
///
/// Without a cause zone (no `PinPoint.run`) a state event cannot be tied to
/// a pointer packet, so nothing is named.
///
/// The route runs inside the pointer dispatch (engineering rule 11): it
/// never throws and never awaits.
class HoverNamer {
  HoverNamer({
    required this.recorder,
    required this.resolver,
    required this.content,
  });

  final TraceRecorder recorder;
  final SourceResolver resolver;

  /// The element directly above the app's own widgets.
  final Element? Function() content;

  /// Widgets that only lay out or paint something: a hover is not "over a
  /// Padding". The widget that is named is the nearest local one that is not
  /// in this list (a row, a button, a card the app made). One constant
  /// list, like `frameworkInheritedWidgets`.
  static const Set<String> layoutWidgets = <String>{
    'Text',
    'RichText',
    'Icon',
    'Image',
    'SizedBox',
    'Padding',
    'Align',
    'Center',
    'Container',
    'DecoratedBox',
    'ColoredBox',
    'ConstrainedBox',
    'Expanded',
    'Flexible',
    'Positioned',
    'Opacity',
    'Transform',
    'Column',
    'Row',
    'Stack',
    'Wrap',
    'ListView',
    'GridView',
    'SingleChildScrollView',
    'SafeArea',
    'MouseRegion',
    'Listener',
    'Builder',
    'LayoutBuilder',
    'ValueListenableBuilder',
    'ListenableBuilder',
    'AnimatedBuilder',
    'StreamBuilder',
    'FutureBuilder',
    'AnimatedContainer',
    'AnimatedOpacity',
  };

  bool _on = false;
  int _seen = 0;
  Element? _lastElement;
  String? _last;
  late final PointerRoute _route = _onPointer;

  /// Whether the route is on.
  bool get running => _on;

  /// Routes added and not removed, for tests.
  @visibleForTesting
  static int debugInstalled = 0;

  void start() {
    if (_on) return;
    try {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
    } catch (_) {
      // No binding (a plain Dart test).
      return;
    }
    _on = true;
    debugInstalled++;
    _seen = recorder.nextSeq;
    _last = null;
    _lastElement = null;
  }

  void stop() {
    if (!_on) return;
    _on = false;
    debugInstalled--;
    try {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    } catch (_) {
      // Already gone.
    }
  }

  void _onPointer(PointerEvent event) {
    if (!_on) return;
    try {
      if (event is! PointerHoverEvent) return;
      final from = _seen;
      _seen = recorder.nextSeq;
      if (!recorder.causesRecorded) return;
      final cause = CauseZone.currentCause;
      if (cause == null || cause.internal) return;
      var changed = false;
      for (var seq = from; seq < _seen; seq++) {
        final e = recorder.at(seq);
        if (e == null || e.cause != cause.id) continue;
        if ((e.kind == TraceKind.stateNotify ||
                e.kind == TraceKind.stateSetState) &&
            !isNoiseSetState(e)) {
          changed = true;
          break;
        }
      }
      if (!changed) return;
      final now = _widgetAt(event);
      final before = _last;
      final sameElement =
          identical(now?.element, _lastElement) &&
          (_lastElement?.mounted ?? true);
      if (sameElement) return;
      _lastElement = now?.element;
      _last = now?.name;
      recorder.add(
        TraceKind.pointer,
        widget: now?.name,
        data: {
          'phase': 'hover',
          'x': event.position.dx.round(),
          'y': event.position.dy.round(),
          'device': event.kind.name,
          'left': ?before,
        },
      );
    } catch (_) {
      // The lens only observes.
    }
  }

  // The widget under [event]: the nearest local widget above the first
  // render object that is not a layout widget ([layoutWidgets]), with the
  // words on it when it is small. Null when the pointer is on no widget of
  // the app (Pinpoint's own surfaces are not under the app's content).
  ({Element element, String name})? _widgetAt(PointerEvent event) {
    final root = content();
    if (root == null || !root.mounted) return null;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      final creator = target.debugCreator;
      if (creator is! DebugCreator) continue;
      Element? found;
      String? name;
      var underApp = false;
      bool visit(Element e) {
        if (identical(e, root)) {
          underApp = true;
          return false;
        }
        if (found == null) {
          final chain = resolver.entryOf(e);
          if (chain.isLocal &&
              !layoutWidgets.contains(chain.name.split('<').first)) {
            found = e;
            name = chain.name;
          }
        }
        return true;
      }

      if (visit(creator.element)) creator.element.visitAncestorElements(visit);
      final element = found;
      if (!underApp || element == null) return null;
      return (element: element, name: name!);
    }
    return null;
  }
}
