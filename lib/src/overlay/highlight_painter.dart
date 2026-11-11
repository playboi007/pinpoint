import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../info/widget_info.dart';
import '../search/pick_result.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_tokens.dart';

/// The selected widget and the local widgets above it, for example
/// `SaveBar > ElevatedButton > Text`.
String breadcrumbLabel(PickResult pick) =>
    pick.chain.breadcrumb(pick.chainIndex).map((e) => e.name).join(' > ');

/// Where the selected widget was created, relative to the project root,
/// for example `lib/widgets/save_bar.dart:42`. Null when unknown.
String? locationLabel(PickResult pick) {
  final location = pick.entry.location;
  return location == null ? null : pick.chain.resolver.paths.label(location);
}

/// The label text: breadcrumb, size and location, for example
/// `Row > ElevatedButton > Text  48.0 x 20.0  lib/widgets/save_bar.dart:42`.
String highlightLabel(PickResult pick) => [
  breadcrumbLabel(pick),
  formatSize(pick.globalRect.size),
  ?locationLabel(pick),
].join('  ');

/// The widget name on the selection's label pill: `Container`.
String pillName(PickResult pick) => pick.entry.name;

/// The size on the selection's label pill: `440 × 44`.
String pillSize(PickResult pick) {
  final size = pick.globalRect.size;
  return '${formatNumber(size.width)} × ${formatNumber(size.height)}';
}

/// The location on the selection's label pill: the file name and line only,
/// for example `save_bar.dart:42`. Null when unknown.
String? pillLocation(PickResult pick) {
  final label = locationLabel(pick);
  return label?.substring(label.lastIndexOf('/') + 1);
}

/// Where a label pill of [label] size goes for [target], inside [canvas].
///
/// Below the target when there is room, else above it, else inside its
/// bottom edge. [gap] is the space between the target's edge and the pill:
/// the selected outline takes 2 px, so the default leaves 1 px of paper.
/// Kept inside the canvas horizontally. The painter does not know where the
/// info panel is, so the canvas is the only limit.
Rect labelRect(Rect target, Size label, Size canvas, {double gap = 3}) {
  final double top;
  if (target.bottom + gap + label.height <= canvas.height) {
    top = target.bottom + gap;
  } else if (target.top - gap - label.height >= 0) {
    top = target.top - gap - label.height;
  } else {
    top = (target.bottom - gap - label.height)
        .clamp(0, canvas.height - label.height)
        .toDouble();
  }
  final maxLeft = canvas.width - label.width;
  final left = maxLeft <= 0 ? 0.0 : target.left.clamp(0, maxLeft).toDouble();
  return Offset(left, top) & label;
}

/// Paints the hover and selection outlines of the Drafting design, and the
/// selection's label pill.
///
/// Hover is a dashed `ink` outline; the selection is a solid `accent` one
/// (see `paintHover` and `paintSelected`). Neither has a fill. Driven by the
/// controller's notifiers through `repaint`, so a pointer move repaints this
/// layer only. It must sit inside an `IgnorePointer`.
class HighlightPainter extends CustomPainter {
  HighlightPainter({
    required this.hovered,
    required this.selected,
    required this.origin,
    this.tokens = PinPointTokens.redline,
  }) : super(repaint: Listenable.merge([hovered, selected]));

  final ValueListenable<PickResult?> hovered;
  final ValueListenable<PickResult?> selected;

  /// This layer's top-left in global logical pixels. Picks are global
  /// (engineering rule 7); this converts them at the edge. Read at paint
  /// time, when layout is done.
  final ValueGetter<Offset> origin;

  /// The colours of the current palette.
  final PinPointTokens tokens;

  /// Height of the label pill, border included.
  static const double pillHeight = 18;

  /// Space between the pill's border and its text, left and right.
  static const double pillPadding = 7;

  /// Space between the parts of the label.
  static const double pillGap = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final selection = selected.value;
    final hover = hovered.value;
    final shift = -origin();
    if (hover != null &&
        !identical(hover.renderObject, selection?.renderObject)) {
      paintHover(canvas, hover.globalRect.shift(shift), tokens);
    }
    if (selection != null) {
      final rect = selection.globalRect.shift(shift);
      paintSelected(canvas, rect, tokens);
      _paintPill(canvas, size, selection, rect);
    }
  }

  TextPainter _text(String text, Color color, {FontWeight? weight}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: tokens.value.copyWith(
          fontSize: 11,
          height: 16 / 11,
          color: color,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
  }

  void _paintPill(Canvas canvas, Size size, PickResult pick, Rect rect) {
    final location = pillLocation(pick);
    final name = _text(pillName(pick), tokens.accent, weight: FontWeight.w500)
      ..layout();
    final dims = _text(pillSize(pick), tokens.ink)..layout();
    // The border, the padding, and a gap between the parts. The location is
    // last and the only part that gives way when the viewport is narrow.
    final fixed =
        2 +
        2 * pillPadding +
        name.width +
        dims.width +
        pillGap * (location == null ? 1 : 2);
    final path = location == null
        ? null
        : (_text(location, tokens.muted)
            ..layout(maxWidth: (size.width - fixed).clamp(0, double.infinity)));
    final pill = labelRect(
      rect,
      Size(fixed + (path?.width ?? 0), pillHeight),
      size,
    );

    // A 1 px halo ring (elevation 1), then paper, then the 1 px ink border.
    canvas
      ..drawRect(
        pill.inflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tokens.halo,
      )
      ..drawRect(pill, Paint()..color = tokens.paper)
      ..drawRect(
        pill.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tokens.ink,
      );
    var x = pill.left + 1 + pillPadding;
    for (final part in [name, dims, ?path]) {
      part.paint(canvas, Offset(x, pill.top + 1));
      x += part.width + pillGap;
      part.dispose();
    }
  }

  @override
  bool shouldRepaint(HighlightPainter oldDelegate) =>
      oldDelegate.hovered != hovered ||
      oldDelegate.selected != selected ||
      oldDelegate.tokens != tokens;
}
