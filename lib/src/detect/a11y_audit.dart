import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../info/widget_info.dart' show formatColor;
import '../search/render_search.dart';
import 'detector.dart';

/// The smallest tap target, in logical pixels (Android's guideline).
const double minTapTarget = 48;

/// Runs the accessibility audit on the app under [root]: actions without
/// a label, tap targets under 48 x 48, and (with [contrast]) text under
/// the WCAG contrast ratio.
///
/// Semantics are turned on for the audit only: on web they build a
/// parallel DOM tree that costs performance (watch out for). The handle is
/// disposed on every path, which turns them off again unless something
/// else (a screen reader) holds them.
Future<List<Finding>> runAccessibilityAudit(
  RenderObject root, {
  required FindingLocator locator,
  required double devicePixelRatio,
  bool contrast = true,
}) async {
  final handle = SemanticsBinding.instance.ensureSemantics();
  try {
    // The semantics tree is built in the next frame. The audit is on
    // demand, so forcing that one frame is fine (engineering rule 2).
    await SchedulerBinding.instance.endOfFrame;
    if (!root.attached) return const <Finding>[];
    final findings = semanticsFindings(
      root,
      locator: locator,
      devicePixelRatio: devicePixelRatio,
    );
    if (contrast && root is RenderRepaintBoundary) {
      findings.addAll(
        await contrastFindings(root, visibleParagraphs(root), locator: locator),
      );
    }
    return dedupeFindings(findings);
  } finally {
    handle.dispose();
  }
}

/// The semantics checks on every node the app's visible render objects
/// own. Needs semantics on (see [runAccessibilityAudit]).
List<Finding> semanticsFindings(
  RenderObject root, {
  required FindingLocator locator,
  required double devicePixelRatio,
}) {
  // Each node once, with the render object that owns it. Walking the
  // render tree, not the semantics tree, keeps Pinpoint's own UI and
  // offstage routes out.
  final nodes = Map<SemanticsNode, RenderObject>.identity();
  RenderSearch.visitVisible(root, (node, rect, visible) {
    final semantics = node.debugSemantics;
    if (semantics != null) nodes.putIfAbsent(semantics, () => node);
  });
  final findings = <Finding>[];
  for (final MapEntry(key: node, value: owner) in nodes.entries) {
    try {
      findings.addAll(_check(node, owner, locator, devicePixelRatio));
    } catch (_) {
      // One node that cannot be read does not stop the audit.
    }
  }
  return findings;
}

Iterable<Finding> _check(
  SemanticsNode node,
  RenderObject owner,
  FindingLocator locator,
  double devicePixelRatio,
) sync* {
  // A merged node's label and actions are its parent's.
  if (node.isMergedIntoParent) return;
  final data = node.getSemanticsData();
  if (data.flagsCollection.isHidden) return;
  final tappable =
      data.hasAction(ui.SemanticsAction.tap) ||
      data.hasAction(ui.SemanticsAction.longPress);
  if (!tappable) return;

  final place = locator.locate(owner);
  final element = place.element;
  final widget = element == null ? null : locator.widgetNameOf(element);
  final name = widget ?? 'A control';
  final rect = _globalRect(node, devicePixelRatio);
  Finding finding(String kind, String summary, Map<String, Object?> data) =>
      Finding(
        kind: kind,
        severity: Severity.warning,
        summary: summary,
        element: element,
        rect: rect,
        source: place.source,
        route: place.route,
        data: {'widget': ?widget, ...data},
      );

  if (data.label.trim().isEmpty && data.tooltip.trim().isEmpty) {
    yield finding(
      'unlabeled_action',
      '$name has an action but no label for screen readers',
      const {},
    );
  }
  // Links in running text may be smaller (WCAG 2.5.8).
  if (data.flagsCollection.isLink || rect == null) return;
  final width = (rect.width * 10).roundToDouble() / 10;
  final height = (rect.height * 10).roundToDouble() / 10;
  const tolerance = 0.01;
  if (width < minTapTarget - tolerance || height < minTapTarget - tolerance) {
    final w = _number(width);
    final h = _number(height);
    yield finding(
      'small_tap_target',
      '$name tap target is ${w}x$h, under '
          '${_number(minTapTarget)}x${_number(minTapTarget)}',
      {'width': w, 'height': h, 'min': _number(minTapTarget)},
    );
  }
}

/// [node]'s rect in global logical pixels: through every transform up to
/// the root (which scales to physical pixels), then back by the ratio, as
/// Flutter's own tap target guideline does. Null for a node partly
/// scrolled out of view or at the window's edge: its size there says
/// nothing.
Rect? _globalRect(SemanticsNode node, double devicePixelRatio) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) rect = MatrixUtils.transformRect(transform, rect);
    if (current.flagsCollection.hasImplicitScrolling &&
        _atEdge(rect, current.rect)) {
      return null;
    }
    current = current.parent;
  }
  final logical = Rect.fromLTRB(
    rect.left / devicePixelRatio,
    rect.top / devicePixelRatio,
    rect.right / devicePixelRatio,
    rect.bottom / devicePixelRatio,
  );
  return logical.isFinite ? logical : null;
}

bool _atEdge(Rect child, Rect parent) {
  const gap = 0.001;
  return child.left - parent.left <= gap ||
      parent.right - child.right <= gap ||
      child.top - parent.top <= gap ||
      parent.bottom - child.bottom <= gap;
}

/// [value] as an int when it is whole: `24`, `47.5`.
Object _number(double value) =>
    value == value.roundToDouble() ? value.round() : value;

/// Every visible paragraph under [root], with the part of it on screen.
List<(RenderParagraph, Rect)> visibleParagraphs(RenderObject root) {
  final found = <(RenderParagraph, Rect)>[];
  RenderSearch.visitVisible(root, (node, rect, visible) {
    if (node is RenderParagraph && visible.width > 0 && visible.height > 0) {
      found.add((node, visible));
    }
  });
  return found;
}

/// WCAG relative luminance contrast, from 1 (none) to 21 (black on
/// white).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Text under the WCAG AA contrast ratio: 4.5:1, or 3:1 for large text
/// (24 px, or 18.66 px bold).
///
/// Takes one capture of [boundary] and, for each paragraph, compares its
/// text color with the most common color in a 3 px ring around its rect.
/// That is an estimate (watch out for): text over an image or a gradient
/// has no one background, so when the most common color covers under 60%
/// of the ring the finding says `confidence: low`. The measured ratio is
/// always reported.
Future<List<Finding>> contrastFindings(
  RenderRepaintBoundary boundary,
  List<(RenderParagraph, Rect)> paragraphs, {
  required FindingLocator locator,
}) async {
  if (paragraphs.isEmpty || !boundary.attached || !boundary.hasSize) {
    return const <Finding>[];
  }
  final toLocal = Matrix4.tryInvert(boundary.getTransformTo(null));
  if (toLocal == null) return const <Finding>[];
  // Logical pixels are enough to tell a background from a text color.
  final image = await boundary.toImage();
  try {
    final bytes = await image.toByteData();
    if (bytes == null) return const <Finding>[];
    final findings = <Finding>[];
    for (final (paragraph, visible) in paragraphs) {
      try {
        final finding = _contrast(
          paragraph,
          visible,
          MatrixUtils.transformRect(toLocal, visible),
          bytes,
          image.width,
          image.height,
          locator,
        );
        if (finding != null) findings.add(finding);
      } catch (_) {
        // A paragraph that cannot be read is skipped.
      }
    }
    return findings;
  } finally {
    image.dispose();
  }
}

Finding? _contrast(
  RenderParagraph paragraph,
  Rect global,
  Rect local,
  ByteData pixels,
  int width,
  int height,
  FindingLocator locator,
) {
  final style = paragraph.text.style;
  final color = style?.color;
  // Gradient or shader text has no one color.
  if (color == null || style?.foreground != null) return null;
  final left = math.max(0, local.left.floor());
  final top = math.max(0, local.top.floor());
  final right = math.min(width, local.right.ceil());
  final bottom = math.min(height, local.bottom.ceil());
  if (right <= left || bottom <= top) return null;

  final textRgb = color.toARGB32() & 0xFFFFFF;
  int rgbAt(int x, int y) {
    final offset = (y * width + x) * 4;
    return pixels.getUint8(offset) << 16 |
        pixels.getUint8(offset + 1) << 8 |
        pixels.getUint8(offset + 2);
  }

  // Is the text painted in its style's color at all? Not under an Opacity,
  // a color filter or a running transition: the declared color says
  // nothing then, so the paragraph is skipped rather than given a made-up
  // ratio.
  var painted = 0;
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      if (_near(rgbAt(x, y), textRgb)) painted++;
    }
  }
  if (painted == 0) return null;

  // The background is read from a thin ring just outside the paragraph,
  // where no glyph is drawn. Inside the rect, glyphs of a see-through or
  // anti-aliased text would pass for it.
  const ring = 3;
  final counts = <int, int>{};
  var others = 0;
  for (
    var y = math.max(0, top - ring);
    y < math.min(height, bottom + ring);
    y++
  ) {
    for (
      var x = math.max(0, left - ring);
      x < math.min(width, right + ring);
      x++
    ) {
      if (x >= left && x < right && y >= top && y < bottom) continue;
      // Nothing painted there inside the app's boundary: what shows is
      // not known from the capture.
      if (pixels.getUint8((y * width + x) * 4 + 3) < 0xFF) continue;
      final rgb = rgbAt(x, y);
      if (_near(rgb, textRgb)) continue;
      counts[rgb] = (counts[rgb] ?? 0) + 1;
      others++;
    }
  }
  if (others == 0) return null;
  final (background, share) = counts.entries.fold<(int, int)>((
    0,
    0,
  ), (best, e) => e.value > best.$2 ? (e.key, e.value) : best);
  final back = Color(0xFF000000 | background);
  // A see-through text color shows the background through it.
  final fore = Color.alphaBlend(color, back);
  final ratio = contrastRatio(fore, back);
  final size = paragraph.textScaler.scale(style?.fontSize ?? 14);
  final bold = (style?.fontWeight?.value ?? 400) >= 700;
  final large = size >= 24 || (bold && size >= 18.66);
  final required = large ? 3.0 : 4.5;
  if (ratio >= required) return null;

  final place = locator.locate(paragraph);
  final element = place.element;
  final widget = element == null ? null : locator.widgetNameOf(element);
  final rounded = (ratio * 100).roundToDouble() / 100;
  return Finding(
    kind: 'low_contrast',
    severity: Severity.warning,
    summary:
        '${widget ?? 'Text'} contrast is $rounded:1, under '
        '${required == 3 ? '3' : '4.5'}:1',
    element: element,
    rect: global,
    source: place.source,
    route: place.route,
    data: {
      'widget': ?widget,
      'ratio': rounded,
      'required': required,
      'foreground': formatColor(fore),
      'background': formatColor(back),
      'confidence': share / others >= 0.6 ? 'high' : 'low',
    },
  );
}

/// Whether two RGB colors are within 8 per channel: a text pixel.
bool _near(int a, int b) =>
    ((a >> 16 & 0xFF) - (b >> 16 & 0xFF)).abs() <= 8 &&
    ((a >> 8 & 0xFF) - (b >> 8 & 0xFF)).abs() <= 8 &&
    ((a & 0xFF) - (b & 0xFF)).abs() <= 8;
