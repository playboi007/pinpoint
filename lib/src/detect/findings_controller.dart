import 'package:flutter/foundation.dart';

import 'debug_paint.dart';
import 'detector.dart';

/// The findings on the current screen, and which detectors are on.
///
/// Three sources feed it: a scan ("Scan this screen") replaces the
/// scanned findings, the accessibility audit replaces the audited ones,
/// and the hooks (errors, images painted too large) add captured ones as
/// they happen. All are deduplicated by [Finding.key], a scanned finding
/// first, so a re-scan never piles up copies.
class FindingsController extends ChangeNotifier {
  /// At most this many captured findings are kept, newest last.
  static const int maxCaptured = 100;

  /// The finding under the pointer in the list; its rect is outlined.
  final ValueNotifier<Finding?> hovered = ValueNotifier<Finding?>(null);

  List<Finding> _scanned = const <Finding>[];
  List<Finding> _audited = const <Finding>[];
  final List<Finding> _captured = <Finding>[];
  List<Finding>? _merged;
  bool _hasScanned = false;

  /// Every finding, deduplicated: the last scan's, the last audit's, then
  /// the captured ones.
  List<Finding> get findings => _merged ??= List<Finding>.unmodifiable(
    dedupeFindings([..._scanned, ..._audited, ..._captured]),
  );

  /// Whether a scan has run since the last [clear].
  bool get hasScanned => _hasScanned;

  /// The findings of the last scan replace the earlier scan's.
  void setScanned(List<Finding> findings) {
    _scanned = List<Finding>.unmodifiable(findings);
    _hasScanned = true;
    _changed();
  }

  /// The findings of the last accessibility audit replace the earlier
  /// audit's.
  void setAudited(List<Finding> findings) {
    _audited = List<Finding>.unmodifiable(findings);
    _changed();
  }

  bool _auditing = false;

  /// Whether an accessibility audit is running.
  bool get auditing => _auditing;
  set auditing(bool value) {
    if (value == _auditing) return;
    _auditing = value;
    notifyListeners();
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
    _audited = const <Finding>[];
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

  bool _trackRebuilds = false;
  bool _rebuildsTakenOver = false;

  /// Whether `debugOnRebuildDirtyWidget` counts rebuilds per element. Off
  /// by default: the hook runs on every rebuild.
  bool get trackRebuilds => _trackRebuilds;
  set trackRebuilds(bool value) {
    if (value == _trackRebuilds) return;
    _trackRebuilds = value;
    if (value) _rebuildsTakenOver = false;
    notifyListeners();
  }

  /// Whether DevTools held or took the rebuild hook, so tracking stopped.
  bool get rebuildsTakenOver => _rebuildsTakenOver;

  /// Records that the rebuild hook was taken, and turns tracking off.
  void rebuildsWereTakenOver() {
    _rebuildsTakenOver = true;
    _trackRebuilds = false;
    notifyListeners();
  }

  Set<DebugPaintFlag> _debugPaint = const <DebugPaintFlag>{};

  /// The debug paint flags turned on from the list.
  Set<DebugPaintFlag> get debugPaint => _debugPaint;

  void setDebugPaint(DebugPaintFlag flag, {required bool on}) {
    if (_debugPaint.contains(flag) == on) return;
    _debugPaint = Set<DebugPaintFlag>.unmodifiable(
      on ? {..._debugPaint, flag} : (_debugPaint.toSet()..remove(flag)),
    );
    notifyListeners();
  }

  void _changed() {
    _merged = null;
    final shown = hovered.value;
    if (shown != null && !findings.any((f) => identical(f, shown))) {
      hovered.value = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    hovered.dispose();
    super.dispose();
  }
}
