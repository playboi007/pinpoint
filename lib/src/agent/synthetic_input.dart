import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'agent_control.dart';

/// Taps and long presses made up by Pinpoint, sent through the same
/// pipeline as real pointer events (plan Milestone 12, step 4).
abstract final class SyntheticInput {
  /// The first device id Pinpoint uses: far above the ids the engine gives
  /// real devices, so a synthetic pointer never collides with one.
  static const int deviceBase = 0x50504E00;

  /// Down to up for a tap.
  static const Duration tapHold = Duration(milliseconds: 50);

  /// Down to up for a long press: past [kLongPressTimeout].
  static const Duration longPressHold = Duration(milliseconds: 650);

  static int _next = 0;

  /// A clock for the events' time stamps: increasing, as the gesture
  /// recognizers expect.
  static final Stopwatch _clock = Stopwatch()..start();

  static Duration _last = Duration.zero;

  /// The next time stamp: now, at least [after], and always later than the
  /// one before.
  static Duration _stamp([Duration after = Duration.zero]) {
    var next = _clock.elapsed;
    if (next < after) next = after;
    if (next <= _last) next = _last + const Duration(microseconds: 1);
    return _last = next;
  }

  /// What would take a pointer at [position] (global logical pixels)
  /// instead of [target]: null when [target] or one of its descendants is
  /// on the hit path there, else a short name for what is on top.
  ///
  /// The real hit test, Pinpoint's own layers included: a pin or the
  /// launcher over the widget would take the tap too.
  static String? obscuredBy(
    RenderObject target,
    Offset position, {
    required int viewId,
    required String Function(RenderObject renderObject) describe,
  }) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, position, viewId);
    RenderObject? top;
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is! RenderObject) continue;
      top ??= hit;
      if (_isAtOrBelow(hit, target)) return null;
    }
    return top == null ? 'nothing' : describe(top);
  }

  static bool _isAtOrBelow(RenderObject node, RenderObject target) {
    RenderObject? current = node;
    for (var steps = 0; current != null && steps < 512; steps++) {
      if (identical(current, target)) return true;
      current = current.parent;
    }
    return false;
  }

  /// Presses at [position] for [hold], then lifts: added, down, up,
  /// removed, through `GestureBinding.handlePointerEvent`.
  ///
  /// Stopped by [cancel] while held, it sends a cancel instead of the up,
  /// so no gesture is left half done.
  static Future<void> press(
    Offset position, {
    required int viewId,
    required AgentCancel cancel,
    Duration hold = tapHold,
  }) async {
    final id = deviceBase + (_next++ % 0xFF);
    // Touch, not mouse: a tap is all most checks need. Hover and focus
    // effects need mouse-kind events and a PointerHoverEvent, which touch
    // skips (watch out for); a check on a hover state needs a hover tool
    // later.
    const kind = PointerDeviceKind.touch;
    final binding = GestureBinding.instance;
    Duration now() => _stamp();
    binding.handlePointerEvent(
      PointerAddedEvent(
        viewId: viewId,
        timeStamp: now(),
        kind: kind,
        device: id,
        position: position,
      ),
    );
    final down = now();
    binding.handlePointerEvent(
      PointerDownEvent(
        viewId: viewId,
        timeStamp: down,
        pointer: id,
        kind: kind,
        device: id,
        position: position,
      ),
    );
    var lifted = false;
    try {
      await Future<void>.delayed(hold);
      cancel.check();
      binding.handlePointerEvent(
        PointerUpEvent(
          viewId: viewId,
          // At least the hold after the down, also on a clock that did not
          // move (a test's fake time).
          timeStamp: _stamp(down + hold),
          pointer: id,
          kind: kind,
          device: id,
          position: position,
        ),
      );
      lifted = true;
    } finally {
      if (!lifted) {
        binding.handlePointerEvent(
          PointerCancelEvent(
            viewId: viewId,
            timeStamp: now(),
            pointer: id,
            kind: kind,
            device: id,
            position: position,
          ),
        );
      }
      binding.handlePointerEvent(
        PointerRemovedEvent(
          viewId: viewId,
          timeStamp: now(),
          kind: kind,
          device: id,
          position: position,
        ),
      );
    }
  }

  /// The id of the view [renderObject] is drawn in. Pinpoint assumes a
  /// single view (PLAN.md risks).
  static int viewIdOf(RenderObject renderObject) {
    RenderObject? current = renderObject;
    while (current != null) {
      if (current is RenderView) return current.flutterView.viewId;
      current = current.parent;
    }
    return WidgetsBinding.instance.platformDispatcher.implicitView?.viewId ?? 0;
  }
}
