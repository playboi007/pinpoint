import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';

/// A small vertical dial for the widgets under one spot, in the info panel's
/// header.
///
/// A drum seen from the side: one short tick per candidate, the current one
/// in the middle, longest and boldest in the accent. Ticks away from the
/// middle get shorter, thinner and fainter, and crowd together toward the top
/// and bottom edge, so the set reads as a curved surface. A tick exists only
/// for a real candidate: the ends of the list show no tick beyond them.
///
/// Candidates are ordered inner to outer: index 0 is the innermost widget
/// (the smallest one under the pointer), the last is the outermost. Up is the
/// outer side, down is the inner side. The counter `N/M` in the header counts
/// the same way, so "up" is the direction in which N grows.
///
/// Input (each step calls [onSelect] with the new index):
///
/// - Drag: the drum follows the finger, [dragSpacing] px per detent. Dragging
///   up turns the drum up, so the widget below comes to the middle: the inner
///   one. The selection follows each detent and snaps to a candidate on
///   release.
/// - Wheel or trackpad scroll over the dial: one candidate per step. Scrolling
///   down moves like a drag up: to the inner widget.
/// - Click: upper half to the outer widget, lower half to the inner one.
/// - Screen reader: a slider whose "increase" goes outer, so the value `N of
///   M` grows.
///
/// The ticks roll only in answer to these inputs, over [PinPointMotion.quick];
/// with reduced motion they jump. At rest nothing animates.
class CandidateDial extends StatefulWidget {
  const CandidateDial({
    super.key,
    required this.count,
    required this.index,
    required this.onSelect,
    this.describeNeighbours,
  });

  /// Width of the dial.
  static const double width = 24;

  /// Height of the dial: a little less than the header (40).
  static const double height = 34;

  /// Pixels of drag per candidate.
  static const double dragSpacing = 6;

  /// Wheel movement, in logical pixels, that makes one step.
  static const double wheelStep = 30;

  /// Ticks shown on each side of the middle one.
  static const int ticksEachSide = 4;

  /// Number of candidates (at least 1).
  final int count;

  /// The chosen candidate, 0 innermost.
  final int index;

  /// Asks for candidate `index`. Returns whether the selection changed; when
  /// it did not, the dial rolls back to [index].
  final bool Function(int index) onSelect;

  /// The tooltip text, such as `↑ Positioned  ↓ Semantics`. Called when the
  /// pointer enters the dial and when the index changes while it is inside.
  final String Function()? describeNeighbours;

  /// Indices of the candidates that get a tick when the dial is turned to
  /// [position] (fractional while rolling): only real candidates, within
  /// [ticksEachSide] and a bit more.
  static List<int> visibleTicks(int count, double position) {
    const reach = ticksEachSide + _fadeOut;
    final first = math.max(0, (position - reach).ceil());
    final last = math.min(count - 1, (position + reach).floor());
    return <int>[for (var i = first; i <= last; i++) i];
  }

  // Past the last full tick the surface turns away; the next tick is edge-on.
  static const double _fadeOut = 0.6;

  @override
  State<CandidateDial> createState() => _CandidateDialState();
}

class _CandidateDialState extends State<CandidateDial>
    with SingleTickerProviderStateMixin {
  // The drum position in candidate units. Unbounded: it never leaves
  // [0, count - 1], but the controller needs no limits for that.
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );

  // The index last asked of the parent. A rebuild with another index came
  // from elsewhere (a new pick, the same spot clicked again): jump there.
  late int _requested = widget.index;
  bool _dragging = false;
  double _wheel = 0;
  String? _tip;

  bool get _active => widget.count > 1;

  @override
  void didUpdateWidget(CandidateDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragging) return;
    if (widget.index != _requested || widget.count != oldWidget.count) {
      _position.stop();
      _position.value = widget.index.toDouble();
      _requested = widget.index;
    }
    if (_tip != null && widget.index != oldWidget.index) {
      _tip = widget.describeNeighbours?.call();
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  /// Asks the parent for [target]; rolls the drum there, or back when the
  /// parent keeps the old index.
  void _go(int target) {
    final clamped = math.max(0, math.min(widget.count - 1, target));
    if (!_active || clamped == _requested) return;
    final changed = widget.onSelect(clamped);
    _requested = changed ? clamped : widget.index;
    _roll(_requested);
  }

  void _roll(int target) {
    _position.animateTo(
      target.toDouble(),
      duration: PinPointMotion.of(context).quick,
      curve: PinPointMotion.enter,
    );
  }

  /// One step toward the outer widget (up) or the inner one (down).
  void _step({required bool outer}) => _go(_requested + (outer ? 1 : -1));

  void _onDragStart(DragStartDetails details) {
    if (!_active) return;
    _dragging = true;
    _position.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    // The drum follows the finger: up turns its front up, so the position
    // (candidates above the middle are outer) falls.
    final next =
        (_position.value + details.delta.dy / CandidateDial.dragSpacing).clamp(
          0.0,
          (widget.count - 1).toDouble(),
        );
    _position.value = next;
    final detent = next.round();
    if (detent != _requested) {
      final changed = widget.onSelect(detent);
      if (changed) _requested = detent;
    }
  }

  void _onDragEnd([DragEndDetails? details]) {
    if (!_dragging) return;
    _dragging = false;
    // Snap to the last candidate the parent accepted.
    _roll(_requested);
  }

  void _onTapUp(TapUpDetails details) {
    _step(outer: details.localPosition.dy < CandidateDial.height / 2);
  }

  void _onSignal(PointerSignalEvent event) {
    if (!_active || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      _wheel += (event as PointerScrollEvent).scrollDelta.dy;
      if (_wheel.abs() < CandidateDial.wheelStep) return;
      // Scrolling down moves like a drag up: to the inner widget.
      _step(outer: _wheel < 0);
      _wheel = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final count = widget.count;
    final index = widget.index;
    final canOuter = _active && index < count - 1;
    final canInner = _active && index > 0;
    Widget dial = SizedBox(
      width: CandidateDial.width,
      height: CandidateDial.height,
      child: AnimatedBuilder(
        animation: _position,
        builder: (context, _) => CustomPaint(
          painter: _DialPainter(
            position: _position.value,
            count: count,
            ink: tokens.muted,
            faint: tokens.faint,
            accent: tokens.accent,
            active: _active,
          ),
        ),
      ),
    );
    if (_active) {
      dial = GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The panel's own drag is a pan; count the movement from pointer
        // down so the dial turns at once and the panel stays.
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        onVerticalDragCancel: _onDragEnd,
        onTapUp: _onTapUp,
        child: Listener(onPointerSignal: _onSignal, child: dial),
      );
      final describe = widget.describeNeighbours;
      if (describe != null) {
        dial = Tooltip(
          message: _tip ?? 'Widgets under the pointer',
          child: dial,
        );
      }
      dial = MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        onEnter: describe == null
            ? null
            : (_) => setState(() => _tip = describe()),
        child: dial,
      );
    }
    return Semantics(
      container: true,
      slider: true,
      label: 'Widget under the pointer',
      value: '${index + 1} of $count',
      increasedValue: canOuter ? '${index + 2} of $count' : null,
      decreasedValue: canInner ? '$index of $count' : null,
      onIncrease: canOuter ? () => _step(outer: true) : null,
      onDecrease: canInner ? () => _step(outer: false) : null,
      child: dial,
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.position,
    required this.count,
    required this.ink,
    required this.faint,
    required this.accent,
    required this.active,
  });

  final double position;
  final int count;
  final Color ink;
  final Color faint;
  final Color accent;
  final bool active;

  static const double _minLength = 4;
  static const double _sideLength = 15;
  static const double _centreLength = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = cy - 2;
    // The last full tick sits at 4 steps; the surface turns edge-on half a
    // step later. Spacing falls with the cosine: a convex drum.
    const edge = CandidateDial.ticksEachSide + CandidateDial._fadeOut;
    const stepAngle = (math.pi / 2) / edge;
    final paint = Paint()..strokeCap = StrokeCap.butt;
    for (final i in CandidateDial.visibleTicks(count, position)) {
      // Above the middle is the outer side: larger indices.
      final d = i - position;
      final angle = d * stepAngle;
      final c = math.cos(angle);
      if (c <= 0) continue;
      final near = (1 - d.abs()).clamp(0.0, 1.0);
      final side = _minLength + (_sideLength - _minLength) * c * c;
      final length = side + (_centreLength - side) * near;
      final y = cy - radius * math.sin(angle);
      final base = active
          ? Color.lerp(ink, accent, near)!
          : Color.lerp(faint, accent, near)!;
      paint
        ..strokeWidth = 1 + 1.5 * near
        ..color = base.withValues(alpha: base.a * (0.25 + 0.75 * c));
      canvas.drawLine(
        Offset(cx - length / 2, y),
        Offset(cx + length / 2, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.position != position ||
      old.count != count ||
      old.ink != ink ||
      old.faint != faint ||
      old.accent != accent ||
      old.active != active;
}
