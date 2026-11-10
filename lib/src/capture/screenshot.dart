import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

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

/// The outline's colour in the screenshot.
const Color outlineColor = Color(0xFFFF3B30);

/// The outline's stroke in image pixels: 2 logical pixels, at least 1 image
/// pixel.
double outlineWidthFor(double pixelRatio) => math.max(2 * pixelRatio, 1);

/// A PNG crop of the app with the target outlined.
class Screenshot {
  const Screenshot({required this.png, required this.plan, required this.crop});

  final Uint8List png;
  final CapturePlan plan;

  /// [CapturePlan.crop] in global logical pixels.
  final Rect crop;
}

/// Captures [target] (global logical pixels) from the app's [boundary] at
/// [pixelRatio], with the outline drawn on. Null when the target is not on
/// the boundary.
///
/// The boundary holds only the app. Pinpoint's highlight and panel sit
/// beside it (engineering rule 6), so the image is clean.
Future<Screenshot?> captureScreenshot(
  RenderRepaintBoundary boundary,
  Rect target, {
  required double pixelRatio,
}) async {
  // toImage asserts that nothing needs paint. A change since the last frame
  // has scheduled one; wait for it. With nothing scheduled, no frame is
  // forced.
  final scheduler = SchedulerBinding.instance;
  if (scheduler.hasScheduledFrame ||
      scheduler.schedulerPhase != SchedulerPhase.idle) {
    await scheduler.endOfFrame;
  }
  if (!boundary.attached || !boundary.hasSize) return null;

  // Global to the boundary's own logical pixels. Today the boundary fills
  // the view from the origin, so this is the identity. With a what-if
  // viewport (Milestone 9) the boundary moves and scales; converting here
  // keeps the crop on the target either way.
  final toGlobal = boundary.getTransformTo(null);
  final toLocal = Matrix4.tryInvert(toGlobal);
  if (toLocal == null) return null;
  final local = MatrixUtils.transformRect(toLocal, target);
  final plan = planCapture(local, boundary.size, pixelRatio);
  if (plan == null) return null;

  final full = await boundary.toImage(pixelRatio: plan.pixelRatio);
  // ui.Image is not garbage collected promptly: dispose every image and
  // picture made here, on every path.
  try {
    // Clamp again to the image as it came: the plan assumed toImage rounds
    // up, and drawImageRect must never sample outside the image.
    final source = plan.source.intersect(
      Offset.zero & Size(full.width.toDouble(), full.height.toDouble()),
    );
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawImageRect(
        full,
        source,
        Offset.zero & source.size,
        Paint()..filterQuality = FilterQuality.none,
      )
      ..drawRect(
        plan.outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = outlineWidthFor(plan.pixelRatio)
          ..color = outlineColor,
      );
    final picture = recorder.endRecording();
    final ui.Image out;
    try {
      out = await picture.toImage(plan.width, plan.height);
    } finally {
      picture.dispose();
    }
    try {
      final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      return Screenshot(
        png: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        plan: plan,
        crop: MatrixUtils.transformRect(toGlobal, plan.crop),
      );
    } finally {
      out.dispose();
    }
  } finally {
    full.dispose();
  }
}
