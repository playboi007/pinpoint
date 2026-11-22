part of 'pin_marker.dart';

/// The badges on a pin's corners.
extension _PinMarkerBadges on _PinMarkerState {
  /// A 13 px square badge on a corner: top-right (accent, white glyph) while
  /// the agent works, bottom-right (paper) for the rest.
  Widget _statusBadge(PinPointTokens tokens, IconData icon) {
    final status = widget.status;
    final working = status == NoteStatus.inProgress;
    // CSS puts the badge 8 px past the padding edge: 6.5 px past the box.
    const out = -6.5;
    final glyph = Icon(
      icon,
      size: 11,
      color: switch (status) {
        NoteStatus.inProgress => tokens.onAccent,
        NoteStatus.fixed => tokens.ok,
        _ => tokens.ink,
      },
    );
    return Positioned(
      right: out,
      top: working ? out : null,
      bottom: working ? null : out,
      width: PinMarker.badgeSize,
      height: PinMarker.badgeSize,
      child: DecoratedBox(
        key: PinMarker.badgeKey,
        decoration: BoxDecoration(
          color: working ? tokens.accent : tokens.paper,
          border: Border.all(color: tokens.ink),
        ),
        child: Center(
          child: status == NoteStatus.fixed ? _tickGlyph(tokens, glyph) : glyph,
        ),
      ),
    );
  }

  /// While the agent's fix lands, the tick draws itself; at rest it is the
  /// plain glyph.
  Widget _tickGlyph(PinPointTokens tokens, Widget glyph) => AnimatedBuilder(
    animation: _fixed,
    child: glyph,
    builder: (context, child) => _fixed.value >= 1
        ? child!
        : CustomPaint(
            size: const Size.square(11),
            painter: TickPainter(
              progress: PinMoments.tick(_fixed.value),
              color: tokens.ok,
            ),
          ),
  );

  /// A 15 px badge at the top-right: round and green for a pass, square and
  /// red with "!" for a fail. It lands like a rubber stamp when it appears.
  Widget _checksBadge(PinPointTokens tokens, {required bool passed}) {
    const out = -7.5;
    return Positioned(
      right: out,
      top: out,
      width: PinMarker.checksSize,
      height: PinMarker.checksSize,
      child: AnimatedBuilder(
        animation: _stamp,
        child: _checksShape(tokens, passed: passed),
        builder: (context, child) {
          final t = _stamp.value;
          if (t >= 1) return child!;
          return _stamping(tokens, t, child!, passed: passed);
        },
      ),
    );
  }

  Widget _checksShape(PinPointTokens tokens, {required bool passed}) =>
      DecoratedBox(
        key: PinMarker.checksKey,
        decoration: BoxDecoration(
          shape: passed ? BoxShape.circle : BoxShape.rectangle,
          color: passed ? tokens.ok : tokens.err,
          border: Border.all(color: tokens.paper),
        ),
        child: Center(
          child: passed
              ? Icon(PinPointIcons.check, size: 11, color: tokens.onAccent)
              : Text(
                  '!',
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: tokens.onAccent,
                    decoration: TextDecoration.none,
                  ),
                ),
        ),
      );

  Widget _stamping(
    PinPointTokens tokens,
    double t,
    Widget child, {
    required bool passed,
  }) {
    final stamped = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..rotateZ(PinMoments.stampAngle(t))
        ..scaleByDouble(PinMoments.stampSize(t), PinMoments.stampSize(t), 1, 1),
      child: child,
    );
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        CustomPaint(
          painter: DustRingPainter(
            progress: PinMoments.dust(t),
            round: passed,
            color: tokens.muted,
          ),
        ),
        Opacity(opacity: PinMoments.stampOpacity(t), child: stamped),
      ],
    );
  }
}

/// The canvas "selected" outline around a pin: 2 px `accent`, 1 px `paper`
/// and 1 px `ink`, all outside the pin so its own border stays visible.
class _SelectedPinPainter extends CustomPainter {
  const _SelectedPinPainter({required this.selected, required this.tokens});

  final bool selected;
  final PinPointTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    if (!selected) return;
    paintSelected(canvas, (Offset.zero & size).inflate(2), tokens);
  }

  @override
  bool shouldRepaint(_SelectedPinPainter old) =>
      old.selected != selected || old.tokens != tokens;
}
