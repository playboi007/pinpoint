import 'package:flutter/material.dart';

import '../../theme/controls.dart';
import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_tokens.dart';

/// The place of the `BRIDGE OFFLINE` badge, and of what happens when the
/// bridge comes back.
///
/// While a sink is offline it shows [builder]'s badge. When the lines go
/// away while Pinpoint stays active, the bridge is back: the badge's broken
/// link snaps together (two halves slide in, 250 ms, with a small
/// overshoot), the words change to `BRIDGE ONLINE`, the badge stays a beat
/// and fades out. That is 1.1 s in all, and it only runs then: not when
/// Pinpoint stops (the badge is just hidden), not at rest. With reduced
/// motion the badge simply goes.
class BridgeBadgeSlot extends StatefulWidget {
  const BridgeBadgeSlot({
    super.key,
    required this.offline,
    required this.active,
    required this.builder,
    this.gapAbove = false,
  });

  static const Key onlineKey = ValueKey<String>('pinpoint.bridgeOnline');

  /// How long the two halves take to meet.
  static const Duration snapBase = Duration(milliseconds: 250);

  /// How long the badge stays, joined, before it fades out.
  static const Duration holdBase = Duration(milliseconds: 600);

  /// The lines of the sinks that are offline now. Empty when all answer.
  final List<String> offline;

  /// Whether Pinpoint is active. The lines are empty while it is not, and
  /// that is no news from the bridge.
  final bool active;

  /// The badge for [offline]: it is not empty.
  final Widget Function(List<String> offline) builder;

  /// Whether another badge sits above: leave 6 px.
  final bool gapAbove;

  @override
  State<BridgeBadgeSlot> createState() => _BridgeBadgeSlotState();
}

class _BridgeBadgeSlotState extends State<BridgeBadgeSlot>
    with SingleTickerProviderStateMixin {
  /// 0 at the start of the reconnect, 1 when the badge is gone. Runs only
  /// then.
  late final AnimationController _back = AnimationController(vsync: this);

  /// Whether the reconnect plays now.
  bool _reconnecting = false;

  @override
  void initState() {
    super.initState();
    _back.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted && _reconnecting) {
        setState(() => _reconnecting = false);
      }
    });
  }

  @override
  void didUpdateWidget(BridgeBadgeSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.offline.isNotEmpty) {
      // Offline again: a reconnect in progress gives way.
      if (_reconnecting) {
        _back.stop();
        _reconnecting = false;
      }
      return;
    }
    final cameBack =
        oldWidget.offline.isNotEmpty && widget.active && oldWidget.active;
    if (!cameBack) {
      _back.stop();
      _reconnecting = false;
      return;
    }
    final motion = PinPointMotion.of(context);
    if (motion.reduced) return;
    final whole =
        BridgeBadgeSlot.snapBase +
        BridgeBadgeSlot.holdBase +
        PinPointMotion.moderateBase;
    _back.duration = motion.scaled(whole);
    _reconnecting = true;
    _back.forward(from: 0);
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (widget.offline.isNotEmpty) {
      child = widget.builder(widget.offline);
    } else if (_reconnecting) {
      child = _OnlineBadge(run: _back);
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(top: widget.gapAbove ? 6 : 0),
      child: child,
    );
  }
}

/// The badge while the bridge is back: dashed with the halves apart, then
/// solid with the link whole.
class _OnlineBadge extends StatelessWidget {
  const _OnlineBadge({required this.run});

  final Animation<double> run;

  static Duration get _whole =>
      BridgeBadgeSlot.snapBase +
      BridgeBadgeSlot.holdBase +
      PinPointMotion.moderateBase;

  /// Where in the run the halves have met, and where the fade starts.
  static double get _snapEnd =>
      BridgeBadgeSlot.snapBase.inMicroseconds / _whole.inMicroseconds;
  static double get _fadeStart =>
      (BridgeBadgeSlot.snapBase + BridgeBadgeSlot.holdBase).inMicroseconds /
      _whole.inMicroseconds;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final snapEnd = _snapEnd;
    final fadeStart = _fadeStart;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: 'Bridge online',
        excludeSemantics: true,
        child: AnimatedBuilder(
          animation: run,
          builder: (context, _) {
            final v = run.value;
            final snap = (v / snapEnd).clamp(0.0, 1.0);
            final fade = v <= fadeStart
                ? 1.0
                : 1 - (v - fadeStart) / (1 - fadeStart);
            return Opacity(
              key: BridgeBadgeSlot.onlineKey,
              opacity: fade.clamp(0.0, 1.0),
              child: _badge(tokens, snap),
            );
          },
        ),
      ),
    );
  }

  /// The 22 px badge: dashed while the halves are apart, solid once joined.
  Widget _badge(PinPointTokens tokens, double snap) {
    final joined = snap >= 1;
    final content = _content(tokens, snap, joined: joined);
    return SizedBox(
      height: 22,
      child: joined
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.paper,
                border: Border.all(color: tokens.ink),
              ),
              child: Center(widthFactor: 1, child: content),
            )
          : DashedBox(
              color: tokens.ink,
              fill: tokens.paper,
              child: Center(widthFactor: 1, child: content),
            ),
    );
  }

  Widget _content(PinPointTokens tokens, double snap, {required bool joined}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SplitLink(
              // 1 while the halves are apart, 0 when they meet; the
              // spring overshoots, so they press into each other.
              apart: 1 - PinPointMotion.spring.transform(snap),
              color: tokens.ink,
            ),
            const SizedBox(width: 5),
            Text(
              joined ? 'BRIDGE ONLINE' : 'BRIDGE OFFLINE',
              style: tokens.caps.copyWith(color: tokens.ink),
            ),
          ],
        ),
      );
}

/// The `link` glyph cut in two across the middle. [apart] is 1 with the
/// halves [gap] px away from where they meet, 0 when they meet, and below 0
/// when they press into each other.
class _SplitLink extends StatelessWidget {
  const _SplitLink({required this.apart, required this.color});

  static const double size = 14;

  /// How far each half is from its place at [apart] 1, in px.
  static const double gap = 5;

  final double apart;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final shift = apart * gap;
    Widget half({required bool left}) => Transform.translate(
      offset: Offset(left ? -shift : shift, 0),
      child: ClipRect(
        clipper: _HalfClipper(left: left),
        child: Icon(PinPointIcons.link, size: size, color: color),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [half(left: true), half(left: false)],
      ),
    );
  }
}

class _HalfClipper extends CustomClipper<Rect> {
  const _HalfClipper({required this.left});

  final bool left;

  @override
  Rect getClip(Size size) => left
      ? Rect.fromLTRB(0, 0, size.width / 2, size.height)
      : Rect.fromLTRB(size.width / 2, 0, size.width, size.height);

  @override
  bool shouldReclip(_HalfClipper old) => old.left != left;
}
