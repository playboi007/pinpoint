part of 'annotation.dart';

/// A PNG crop of the app around the target, with the target outlined.
class ScreenshotInfo {
  const ScreenshotInfo({
    required this.file,
    required this.pixelRatio,
    required this.width,
    required this.height,
    this.crop,
    this.hasPlatformViews = false,
    this.debugPaint = const <String>[],
    this.beforeAfter = false,
    this.png,
  });

  factory ScreenshotInfo._fromJson(Map<String, Object?> json) => ScreenshotInfo(
    file: asString(json['file']) ?? '',
    pixelRatio: asDouble(json['pixelRatio']) ?? 1,
    width: asInt(json['width']) ?? 0,
    height: asInt(json['height']) ?? 0,
    crop: PayloadRect._fromJson(json['crop']),
    hasPlatformViews: json['hasPlatformViews'] == true,
    debugPaint: asStrings(json['debugPaint']),
    beforeAfter: json['beforeAfter'] == true,
  );

  /// The file name the receiver writes the image to: `<id>.png`.
  final String file;

  /// Image pixels per logical pixel.
  final double pixelRatio;

  /// In image pixels.
  final int width;
  final int height;

  /// The captured part of the screen, in global logical pixels.
  final PayloadRect? crop;

  /// True when a platform view (`HtmlElementView`, a map, an iframe) is in
  /// the crop. On web those render as empty areas, so the image is partial.
  final bool hasPlatformViews;

  /// The debug paint flags that were on, for example
  /// `debugPaintSizeEnabled`. Their marks are in the image.
  final List<String> debugPaint;

  /// True when the image is two crops side by side: on the left the screen
  /// without the note's tweaks, on the right with them.
  final bool beforeAfter;

  /// The PNG bytes. Never in [toJson] unless asked for.
  final Uint8List? png;

  Map<String, Object?> toJson({bool includeData = false}) => {
    'file': file,
    'pixelRatio': jsonNumber(pixelRatio),
    'width': width,
    'height': height,
    'crop': crop?.toJson(),
    'hasPlatformViews': hasPlatformViews,
    'debugPaint': debugPaint,
    'beforeAfter': beforeAfter,
    if (includeData && png != null) 'data': base64Encode(png!),
  };
}

/// A rect in global logical pixels, without `dart:ui`.
class PayloadRect {
  const PayloadRect(this.x, this.y, this.w, this.h);

  static PayloadRect? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final x = asDouble(json['x']);
    final y = asDouble(json['y']);
    final w = asDouble(json['w']);
    final h = asDouble(json['h']);
    if (x == null || y == null || w == null || h == null) return null;
    return PayloadRect(x, y, w, h);
  }

  final double x;
  final double y;
  final double w;
  final double h;

  Map<String, Object?> toJson() => {
    'x': jsonNumber(x),
    'y': jsonNumber(y),
    'w': jsonNumber(w),
    'h': jsonNumber(h),
  };
}

/// A size in logical pixels, without `dart:ui`.
class PayloadSize {
  const PayloadSize(this.width, this.height);

  static PayloadSize? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final width = asDouble(json['width']);
    final height = asDouble(json['height']);
    if (width == null || height == null) return null;
    return PayloadSize(width, height);
  }

  final double width;
  final double height;

  Map<String, Object?> toJson() => {
    'width': jsonNumber(width),
    'height': jsonNumber(height),
  };
}
