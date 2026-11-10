import 'dart:math' as math;
import 'dart:ui';

/// Logical pixels kept around the target on each side.
const double cropMargin = 48;

/// The smallest crop, in logical pixels, so a small widget keeps its
/// surroundings.
const Size minCropSize = Size(320, 200);

/// The part of the app to capture for [target], in the boundary's logical
/// pixels: [target] with [cropMargin] around it, at least [minCropSize],
/// inside `Offset.zero & bounds`.
///
/// A crop that would leave the boundary moves inside it first, so a widget
/// at the screen edge keeps a full-size crop. Only a crop larger than the
/// boundary is cut. Empty when [target] is not on the boundary at all.
Rect cropFor(Rect target, Size bounds) {
  final screen = Offset.zero & bounds;
  if (!target.isFinite || !screen.overlaps(target)) return Rect.zero;
  final inflated = target.inflate(cropMargin);
  final size = Size(
    math.max(inflated.width, minCropSize.width),
    math.max(inflated.height, minCropSize.height),
  );
  final crop = Rect.fromCenter(
    center: inflated.center,
    width: size.width,
    height: size.height,
  );
  double inside(double start, double length, double limit) =>
      length >= limit ? 0 : start.clamp(0, limit - length);
  return Rect.fromLTWH(
    inside(crop.left, crop.width, bounds.width),
    inside(crop.top, crop.height, bounds.height),
    crop.width,
    crop.height,
  ).intersect(screen);
}

/// [logical] scaled by [ratio] to whole image pixels, rounded outward and
/// clamped to `Offset.zero & image`.
///
/// A fractional ratio (1.25, 2.625) puts the scaled edges between pixels.
/// Rounding outward keeps all of [logical]; clamping keeps `drawImageRect`
/// from sampling outside the image.
Rect pixelRectFor(Rect logical, double ratio, Size image) {
  // The slack keeps a float error (200 * 1.1 is 220.00000000000003) from
  // adding a pixel.
  const slack = 1e-6;
  double down(double v) => (v * ratio + slack).floorToDouble();
  double up(double v) => (v * ratio - slack).ceilToDouble();
  return Rect.fromLTRB(
    down(logical.left).clamp(0, image.width),
    down(logical.top).clamp(0, image.height),
    up(logical.right).clamp(0, image.width),
    up(logical.bottom).clamp(0, image.height),
  );
}

/// The size of `RenderRepaintBoundary.toImage` for [bounds] at [ratio]:
/// `OffsetLayer.toImage` rounds up.
Size fullImageSize(Size bounds, double ratio) => Size(
  (bounds.width * ratio).ceilToDouble(),
  (bounds.height * ratio).ceilToDouble(),
);

/// Where one screenshot comes from and where its outline goes.
class CapturePlan {
  const CapturePlan({
    required this.crop,
    required this.pixelRatio,
    required this.source,
    required this.outline,
  });

  /// The captured part, in the boundary's logical pixels, on whole image
  /// pixels: exactly [source] divided by [pixelRatio].
  final Rect crop;

  /// Image pixels per logical pixel.
  final double pixelRatio;

  /// [crop] in the full capture's image pixels. Whole numbers.
  final Rect source;

  /// The target in the output image's pixels.
  final Rect outline;

  /// The output image's width in pixels.
  int get width => source.width.round();

  /// The output image's height in pixels.
  int get height => source.height.round();
}

/// The plan for [target] (the boundary's logical pixels) on a boundary of
/// [bounds] at [pixelRatio], or null when nothing of it can be captured.
CapturePlan? planCapture(Rect target, Size bounds, double pixelRatio) {
  if (!pixelRatio.isFinite || pixelRatio <= 0) return null;
  final crop = cropFor(target, bounds);
  if (crop.isEmpty) return null;
  final source = pixelRectFor(
    crop,
    pixelRatio,
    fullImageSize(bounds, pixelRatio),
  );
  if (source.isEmpty) return null;
  return CapturePlan(
    crop: Rect.fromLTRB(
      source.left / pixelRatio,
      source.top / pixelRatio,
      source.right / pixelRatio,
      source.bottom / pixelRatio,
    ),
    pixelRatio: pixelRatio,
    source: source,
    outline: Rect.fromLTRB(
      target.left * pixelRatio - source.left,
      target.top * pixelRatio - source.top,
      target.right * pixelRatio - source.left,
      target.bottom * pixelRatio - source.top,
    ),
  );
}
