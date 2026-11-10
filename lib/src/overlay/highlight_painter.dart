import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../search/pick_result.dart';

/// Colors of the outlines. Fixed, so they read on any app theme.
abstract final class HighlightColors {
  static const Color hover = Color(0xFF2962FF);
  static const Color selected = Color(0xFFFF6D00);
  static const Color labelText = Color(0xFFFFFFFF);
}

/// The label pill text: widget name and size, for example
/// `RichText 120.0 x 16.0`.
String highlightLabel(PickResult pick) {
  final size = pick.globalRect.size;
  return '${pick.element.widget.runtimeType} '
      '${size.width.toStringAsFixed(1)} x ${size.height.toStringAsFixed(1)}';
}

/// Where a label of [label] size goes for [target], inside [canvas].
///
/// Above the target when there is room, else below it, else inside its top
/// edge. Kept inside the canvas horizontally.
Rect labelRect(Rect target, Size label, Size canvas, {double gap = 4}) {
  final double top;
  if (target.top - gap - label.height >= 0) {
    top = target.top - gap - label.height;
  } else if (target.bottom + gap + label.height <= canvas.height) {
    top = target.bottom + gap;
  } else {
    top = (target.top + gap).clamp(0, canvas.height - label.height).toDouble();
  }
  final maxLeft = canvas.width - label.width;
  final left = maxLeft <= 0 ? 0.0 : target.left.clamp(0, maxLeft).toDouble();
  return Offset(left, top) & label;
}

/// Paints the hover and selection outlines: a translucent fill, a 1.5 px
/// border and a label pill.
///
/// Driven by the controller's notifiers through `repaint`, so a pointer move
/// repaints this layer only. It must sit inside an `IgnorePointer`.
class HighlightPainter extends CustomPainter {
  HighlightPainter({
    required this.hovered,
    required this.selected,
    required this.origin,
  }) : super(repaint: Listenable.merge([hovered, selected]));

  final ValueListenable<PickResult?> hovered;
  final ValueListenable<PickResult?> selected;

  /// This layer's top-left in global logical pixels. Picks are global
  /// (engineering rule 7); this converts them at the edge. Read at paint
  /// time, when layout is done.
  final ValueGetter<Offset> origin;

  static const double borderWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final selection = selected.value;
    final hover = hovered.value;
    final shift = -origin();
    if (hover != null &&
        !identical(hover.renderObject, selection?.renderObject)) {
      _paintPick(canvas, size, hover, shift, HighlightColors.hover);
    }
    if (selection != null) {
      _paintPick(canvas, size, selection, shift, HighlightColors.selected);
    }
  }

  void _paintPick(
    Canvas canvas,
    Size size,
    PickResult pick,
    Offset shift,
    Color color,
  ) {
    final rect = pick.globalRect.shift(shift);
    canvas
      ..drawRect(rect, Paint()..color = color.withValues(alpha: 0.12))
      ..drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderWidth
          ..color = color,
      );

    final text = TextPainter(
      text: TextSpan(
        text: highlightLabel(pick),
        style: const TextStyle(
          color: HighlightColors.labelText,
          fontSize: 11,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: size.width);
    const padding = EdgeInsets.symmetric(horizontal: 6, vertical: 2);
    final pill = labelRect(
      rect,
      Size(text.width + padding.horizontal, text.height + padding.vertical),
      size,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, const Radius.circular(4)),
      Paint()..color = color,
    );
    text
      ..paint(canvas, pill.topLeft + padding.topLeft)
      ..dispose();
  }

  @override
  bool shouldRepaint(HighlightPainter oldDelegate) =>
      oldDelegate.hovered != hovered || oldDelegate.selected != selected;
}
