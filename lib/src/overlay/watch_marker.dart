import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../theme/marks.dart';
import '../theme/pinpoint_tokens.dart';

/// Paints the marker of watch mode (state lens): a thin dashed `accent`
/// outline on the watched widget's rect, and a small caps tag "WATCHING" at
/// its top-left corner.
///
/// Driven by [rect] through `repaint`. The rect is set after frames the app
/// draws anyway (`WatchSession`), so this painter asks for no frame of its
/// own. A null rect paints nothing: the target is unmounted, scrolled away
/// or not watched. It must sit inside an `IgnorePointer`.
class WatchMarkerPainter extends CustomPainter {
  WatchMarkerPainter({
    required this.rect,
    required this.origin,
    this.tokens = PinPointTokens.redline,
  }) : super(repaint: rect);

  /// The tag's words.
  static const String tag = 'WATCHING';

  /// Height of the tag, and the padding inside it.
  static const double tagHeight = 16;
  static const double tagPadding = 5;

  final ValueListenable<Rect?> rect;

  /// This layer's top-left in global logical pixels (picks and rects are
  /// global, engineering rule 7). Read at paint time.
  final ValueGetter<Offset> origin;

  final PinPointTokens tokens;

  /// Where the tag goes for [target] inside [canvas]: on the top edge's
  /// outside when there is room above, else inside the corner.
  static Rect tagRect(Rect target, Size tagSize, Size canvas) {
    final top = target.top - tagSize.height >= 0
        ? target.top - tagSize.height
        : target.top;
    final maxLeft = canvas.width - tagSize.width;
    final left = maxLeft <= 0 ? 0.0 : target.left.clamp(0, maxLeft).toDouble();
    return Offset(left, top) & tagSize;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final value = rect.value;
    if (value == null) return;
    final target = value.shift(-origin());
    strokeHalo(
      canvas,
      Path()..addRect(target.deflate(0.75)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = tokens.accent,
      tokens,
      dash: const [6, 3],
    );
    final text = TextPainter(
      text: TextSpan(
        text: tag,
        style: tokens.caps.copyWith(color: tokens.onAccent),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final box = tagRect(
      target,
      Size(text.width + 2 * tagPadding, tagHeight),
      size,
    );
    canvas.drawRect(box, Paint()..color = tokens.accent);
    text.paint(canvas, Offset(box.left + tagPadding, box.top + 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(WatchMarkerPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.tokens != tokens;
}
