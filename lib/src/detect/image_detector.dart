import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../core/hook_registry.dart';
import '../search/render_search.dart';
import 'detector.dart';

/// Whether an image decoded at [decoded] pixels wastes memory when shown
/// at [displayed] physical pixels: more than twice the area.
bool isOversized(Size decoded, Size displayed) {
  final shown = displayed.width * displayed.height;
  if (shown < 1) return false;
  return decoded.width * decoded.height > 2 * shown;
}

/// Finds images decoded much larger than they are shown: every visible
/// `RenderImage` whose decoded pixels are more than twice its displayed
/// pixels.
///
/// It reads the decoded size straight from the render object, so it finds
/// a steady image every time. [ImagePaintRecorder] covers the images no
/// `RenderImage` paints (decoration images).
class ImageDetector extends Detector {
  const ImageDetector({required this.devicePixelRatio});

  /// Displayed sizes are compared in physical pixels, as Flutter's own
  /// `debugOnPaintImage` does.
  final double devicePixelRatio;

  @override
  String get kind => 'oversized_image';

  @override
  Iterable<Finding> scan(RenderObject renderObject, ScanContext context) {
    if (renderObject is! RenderImage || !renderObject.hasSize) {
      return const <Finding>[];
    }
    final image = renderObject.image;
    if (image == null) return const <Finding>[];
    final decoded = Size(image.width.toDouble(), image.height.toDouble());
    // Layout size, not the on-screen rect: a what-if viewport scaled down
    // to fit the window would make every image look oversized.
    final displayed = renderObject.size * devicePixelRatio;
    if (!isOversized(decoded, displayed)) return const <Finding>[];
    return [
      context.finding(
        renderObject,
        kind: kind,
        severity: Severity.warning,
        summary: _summary(decoded, displayed, renderObject.debugImageLabel),
        data: _data(decoded, displayed, renderObject.debugImageLabel),
      ),
    ];
  }
}

String _summary(Size decoded, Size displayed, String? label) =>
    'Image${label == null ? '' : ' "$label"'} decoded at ${_size(decoded)} '
    'is shown at ${_size(displayed)} px '
    '(${_ratio(decoded, displayed)}x the pixels)';

Map<String, Object?> _data(Size decoded, Size displayed, String? label) => {
  'decoded': _size(decoded),
  'displayed': _size(displayed),
  'ratio': _ratio(decoded, displayed),
  'label': ?label,
};

String _size(Size size) => '${size.width.round()}x${size.height.round()}';

double _ratio(Size decoded, Size displayed) =>
    (decoded.width * decoded.height / (displayed.width * displayed.height) * 10)
        .roundToDouble() /
    10;

/// Records images painted much smaller than they were decoded, through
/// `debugOnPaintImage`, for the ones [ImageDetector] cannot see.
///
/// Flutter calls the hook once per new size, not every frame
/// (docs/api-notes.md, item 8), so a steady image is reported once: the
/// hook stays installed from the start and keeps its own record.
class ImagePaintRecorder {
  ImagePaintRecorder({
    required HookRegistry registry,
    required this.onFindings,
    required this.appRoot,
  }) : _slot = registry.slot<PaintImageCallback?>(
         key: #pinpointDebugOnPaintImage,
         read: () => debugOnPaintImage,
         write: (value) => debugOnPaintImage = value,
       );

  /// At most this many reports wait for one frame's end.
  static const int maxPending = 50;

  /// Gets findings for oversized images no `RenderImage` shows.
  final void Function(List<Finding> findings) onFindings;

  /// The app's boundary, to look for a `RenderImage` with the report's
  /// label. Null while the app is not built.
  final RenderObject? Function() appRoot;

  final GlobalSlot<PaintImageCallback?> _slot;
  late final PaintImageCallback _hook = _onPaint;
  final List<ImageSizeInfo> _pending = <ImageSizeInfo>[];
  bool _scheduled = false;
  bool _installed = false;

  bool get installed => _installed;

  void install() {
    if (_installed) return;
    _installed = true;
    _slot.set(_hook);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _slot.release();
    _pending.clear();
  }

  // Runs during paint. Only append here; findings are made after the frame
  // (watch out for: never touch widgets inside debugOnPaintImage).
  void _onPaint(ImageSizeInfo info) {
    _slot.previous?.call(info);
    if (!_installed || _pending.length >= maxPending) return;
    if (!isOversized(info.imageSize, info.displaySize)) return;
    _pending.add(info);
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => _process(),
      debugLabel: 'pinpoint.imageReports',
    );
  }

  void _process() {
    _scheduled = false;
    if (!_installed) return;
    final reports = <String, ImageSizeInfo>{
      for (final info in _pending) info.source ?? '': info,
    };
    _pending.clear();
    try {
      // An image a RenderImage shows is left to the scan, which has its
      // widget.
      final root = appRoot();
      if (root != null) {
        RenderSearch.visitVisible(root, (node, rect, visible) {
          if (node is RenderImage) reports.remove(node.debugImageLabel);
        });
      }
      if (reports.isEmpty) return;
      onFindings([
        for (final info in reports.values)
          Finding(
            kind: 'oversized_image',
            severity: Severity.warning,
            summary: _summary(info.imageSize, info.displaySize, info.source),
            data: _data(info.imageSize, info.displaySize, info.source),
          ),
      ]);
    } catch (error) {
      debugPrint('pinpoint: image report failed: $error');
    }
  }
}
