import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_theme.dart';
import '../../theme/pinpoint_tokens.dart';
import 'flights.dart';

/// Pinpoint's own [Theme], in the palette the user picked, with the ink
/// wipe of a switch.
///
/// A switch rebuilds only what reads the theme under here, never the host
/// app, and the overlay's own tree is passed in as [child], so it is not
/// rebuilt as a whole either.
///
/// The wipe: when the user picks a palette (the theme menu asks through
/// [PinPointFlights.inkWipe], with the swatch it was clicked from), a
/// picture of Pinpoint's UI as it is now is taken at once. The new palette
/// is applied at once too, as before; the old picture is laid over it and
/// a circle grows from the swatch, over [PinPointMotion.expressive], that
/// shows the new UI through it. The picture holds Pinpoint's pixels only,
/// so nothing ever draws over the host app. A hard band of the new accent
/// runs along the edge, only where the old UI is.
///
/// With reduced motion, or when the engine cannot make the picture, the
/// palette just changes.
class PaletteInk extends StatefulWidget {
  const PaletteInk({
    super.key,
    required this.palette,
    required this.flights,
    required this.child,
  });

  static const Key wipeKey = ValueKey<String>('pinpoint.inkWipe');

  final ValueListenable<PinPointPalette> palette;
  final PinPointFlights flights;
  final Widget child;

  @override
  State<PaletteInk> createState() => _PaletteInkState();
}

class _PaletteInkState extends State<PaletteInk>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spread = AnimationController(vsync: this);
  final GlobalKey _boundary = GlobalKey(debugLabel: 'pinpoint ink boundary');

  /// Pinpoint's UI before the switch; null when no wipe plays.
  ui.Image? _old;
  Offset _origin = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.flights.onInkWipe = _begin;
    _spread.addStatusListener((status) {
      if (status == AnimationStatus.completed) _end();
    });
  }

  @override
  void didUpdateWidget(PaletteInk old) {
    super.didUpdateWidget(old);
    if (old.flights == widget.flights) return;
    if (old.flights.onInkWipe == _begin) old.flights.onInkWipe = null;
    widget.flights.onInkWipe = _begin;
  }

  @override
  void dispose() {
    if (widget.flights.onInkWipe == _begin) widget.flights.onInkWipe = null;
    _spread.dispose();
    _old?.dispose();
    super.dispose();
  }

  /// Takes the picture of the UI as it is, before the palette changes.
  bool _begin(Offset globalOrigin) {
    final motion = PinPointMotion.of(context);
    if (motion.reduced) return false;
    final box = _boundary.currentContext?.findRenderObject();
    if (box is! _RenderInkBoundary || !box.hasSize) return false;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final image = box.snapshot(ratio);
    if (image == null) return false;
    _old?.dispose();
    _spread.stop();
    setState(() {
      _old = image;
      _origin = box.globalToLocal(globalOrigin);
    });
    _spread.duration = motion.expressive;
    _spread.forward(from: 0);
    return true;
  }

  void _end() {
    if (_old == null) return;
    setState(() {
      _old!.dispose();
      _old = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final old = _old;
    return ValueListenableBuilder<PinPointPalette>(
      valueListenable: widget.palette,
      builder: (context, palette, child) => Theme(
        data: pinPointThemeData(palette),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            _InkBoundary(key: _boundary, child: child!),
            if (old != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _spread,
                    builder: (context, _) => CustomPaint(
                      key: PaletteInk.wipeKey,
                      painter: _InkPainter(
                        image: old,
                        origin: _origin,
                        progress: PinPointMotion.move.transform(_spread.value),
                        band: palette.tokens.accent,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      child: widget.child,
    );
  }
}

/// A repaint boundary that can make a picture of itself on the spot.
class _InkBoundary extends SingleChildRenderObjectWidget {
  const _InkBoundary({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderInkBoundary();
}

class _RenderInkBoundary extends RenderProxyBox {
  @override
  bool get isRepaintBoundary => true;

  /// The last painted frame of this box, or null when there is none or the
  /// engine cannot make it. The picture is made now, so a change that comes
  /// after this call is not in it.
  ui.Image? snapshot(double pixelRatio) {
    final layer = this.layer;
    if (layer is! OffsetLayer) return null;
    try {
      return layer.toImageSync(Offset.zero & size, pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }
}

/// Lays the old picture over the new UI, except inside the circle.
class _InkPainter extends CustomPainter {
  _InkPainter({
    required this.image,
    required this.origin,
    required this.progress,
    required this.band,
  });

  /// How wide the accent band at the edge is.
  static const double bandWidth = 5;

  final ui.Image image;
  final Offset origin;
  final double progress;
  final Color band;

  /// The radius at which the circle covers [size] from [origin].
  static double reach(Offset origin, Size size) => [
    origin,
    origin - Offset(size.width, 0),
    origin - Offset(0, size.height),
    origin - Offset(size.width, size.height),
  ].map((p) => p.distance).reduce(math.max);

  @override
  void paint(Canvas canvas, Size size) {
    final radius = (reach(origin, size) + bandWidth) * progress;
    final bounds = Offset.zero & size;
    final inside = Path()
      ..addOval(Rect.fromCircle(center: origin, radius: radius));
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      inside,
    );
    // One layer, so the band lands only on the old UI's own pixels.
    canvas.saveLayer(bounds, Paint());
    canvas.clipPath(outside);
    canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      bounds,
      Paint(),
    );
    canvas.drawPath(
      Path()
        ..addOval(Rect.fromCircle(center: origin, radius: radius + bandWidth))
        ..addOval(Rect.fromCircle(center: origin, radius: radius))
        ..fillType = PathFillType.evenOdd,
      Paint()
        ..color = band
        ..blendMode = BlendMode.srcATop,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InkPainter old) =>
      old.image != image ||
      old.origin != origin ||
      old.progress != progress ||
      old.band != band;
}
