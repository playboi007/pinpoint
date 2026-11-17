import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../../capture/screenshot.dart';

/// One PNG of exactly [target] (global logical pixels) from the app's
/// [boundary]: the picture that bounces in when a site is lifted. Null when
/// the target is not on the boundary.
///
/// Like [captureScreenshot] it waits only for a frame that is already
/// scheduled and forces none. The site is HTML, so it is not in the image.
Future<Uint8List?> captureRegion(
  RenderRepaintBoundary boundary,
  Rect target, {
  required double pixelRatio,
}) async {
  await paintSettled();
  if (!boundary.attached || !boundary.hasSize) return null;
  if (!pixelRatio.isFinite || pixelRatio <= 0) return null;
  final toLocal = Matrix4.tryInvert(boundary.getTransformTo(null));
  if (toLocal == null) return null;
  final local = MatrixUtils.transformRect(
    toLocal,
    target,
  ).intersect(Offset.zero & boundary.size);
  if (local.isEmpty) return null;

  final ratio = math.min(pixelRatio, maxPixelRatio);
  final source = pixelRectFor(
    local,
    ratio,
    fullImageSize(boundary.size, ratio),
  );
  if (source.isEmpty) return null;

  final full = await boundary.toImage(pixelRatio: ratio);
  // ui.Image is not garbage collected promptly: dispose every image and
  // picture made here, on every path.
  try {
    final inside = source.intersect(
      Offset.zero & Size(full.width.toDouble(), full.height.toDouble()),
    );
    if (inside.isEmpty) return null;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      full,
      inside,
      Offset.zero & inside.size,
      Paint()..filterQuality = FilterQuality.none,
    );
    final picture = recorder.endRecording();
    final ui.Image out;
    try {
      out = await picture.toImage(inside.width.round(), inside.height.round());
    } finally {
      picture.dispose();
    }
    try {
      final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      out.dispose();
    }
  } finally {
    full.dispose();
  }
}
