import 'package:flutter/foundation.dart';

import 'detector.dart';

/// The findings on the current screen, and which detectors are on.
///
/// Two sources feed it: a scan ("Scan this screen") replaces the scanned
/// findings, and the hooks (errors, images painted too large) add captured
/// ones as they happen. Both are deduplicated by [Finding.key], a scanned
/// finding first, so a re-scan never piles up copies.
class FindingsController extends ChangeNotifier {
  /// At most this many captured findings are kept, newest last.
  static const int maxCaptured = 100;

  List<Finding> _scanned = const <Finding>[];
  final List<Finding> _captured = <Finding>[];
  List<Finding>? _merged;
  bool _hasScanned = false;

  /// Every finding, deduplicated: the last scan's, then the captured ones.
  List<Finding> get findings => _merged ??= List<Finding>.unmodifiable(
    dedupeFindings([..._scanned, ..._captured]),
  );

  /// Whether a scan has run since the last [clear].
  bool get hasScanned => _hasScanned;

  /// The findings of the last scan replace the earlier scan's.
  void setScanned(List<Finding> findings) {
    _scanned = List<Finding>.unmodifiable(findings);
    _hasScanned = true;
    _changed();
  }

  /// Adds findings from a hook. One with the key of an earlier one
  /// replaces it, so the newest text is kept.
  void addCaptured(Iterable<Finding> findings) {
    for (final finding in findings) {
      _captured
        ..removeWhere((f) => f.key == finding.key)
        ..add(finding);
    }
    if (_captured.length > maxCaptured) {
      _captured.removeRange(0, _captured.length - maxCaptured);
    }
    _changed();
  }

  /// Drops every finding, scanned and captured.
  void clear() {
    _scanned = const <Finding>[];
    _captured.clear();
    _hasScanned = false;
    _changed();
  }

  bool _captureErrors = true;
  bool _trackImages = true;

  /// Whether `FlutterError.onError` and `PlatformDispatcher.onError` are
  /// chained to record errors. On by default: errors happen before anyone
  /// opens the findings list, and the hook costs nothing until one does.
  bool get captureErrors => _captureErrors;
  set captureErrors(bool value) {
    if (value == _captureErrors) return;
    _captureErrors = value;
    notifyListeners();
  }

  /// Whether `debugOnPaintImage` records images painted much smaller than
  /// they were decoded. On by default: Flutter reports a steady image once
  /// only, so a hook installed later misses it.
  bool get trackImages => _trackImages;
  set trackImages(bool value) {
    if (value == _trackImages) return;
    _trackImages = value;
    notifyListeners();
  }

  void _changed() {
    _merged = null;
    notifyListeners();
  }
}
