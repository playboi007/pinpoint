import 'package:flutter/rendering.dart';

import '../core/hook_registry.dart';
import '../core/rebuild_hook.dart';
import 'debug_paint.dart';
import 'detector.dart';
import 'error_capture.dart';
import 'findings_controller.dart';
import 'image_detector.dart';
import 'rebuild_tracker.dart';

/// The detectors that work through global hooks, installed and removed as
/// [findings] turns them on and off. Every hook goes through the
/// wrapper's [HookRegistry] (engineering rule 1).
class DetectorHooks {
  DetectorHooks({
    required HookRegistry registry,
    required this.findings,
    required RenderObject? Function() appRoot,
    required FindingLocator Function() locator,
    RebuildHook? rebuildHook,
  }) : errors = ErrorCapture(
         registry: registry,
         onFindings: findings.addCaptured,
         locator: locator,
       ),
       images = ImagePaintRecorder(
         registry: registry,
         onFindings: findings.addCaptured,
         appRoot: appRoot,
       ),
       rebuilds = RebuildTracker(
         registry: registry,
         hook: rebuildHook ?? RebuildHook(registry),
       ),
       paint = DebugPaintToggles(registry) {
    findings.addListener(_apply);
    _apply();
  }

  final FindingsController findings;
  final ErrorCapture errors;
  final ImagePaintRecorder images;
  final RebuildTracker rebuilds;
  final DebugPaintToggles paint;

  void _apply() {
    if (findings.captureErrors) {
      errors.install();
    } else {
      errors.uninstall();
    }
    if (findings.trackImages) {
      images.install();
    } else {
      images.uninstall();
    }
    if (findings.trackRebuilds) {
      // Shares a slot DevTools holds (RebuildHook). Fails only when another
      // tool wrote over Pinpoint's hook: say so, and leave it to that tool.
      if (!rebuilds.install()) findings.rebuildsWereTakenOver();
    } else if (rebuilds.installed) {
      rebuilds.uninstall();
    }
    paint.apply(findings.debugPaint);
  }

  /// The rebuild hot spots, when tracking is on. A slot DevTools cleared
  /// since (it turned its tracking off) is taken back; one another tool
  /// wrote over the hook is left to it, and tracking turns off (watch out
  /// for: DevTools replaces or clears the hook).
  List<Finding> rebuildFindings(FindingLocator locator) {
    if (!rebuilds.installed) return const <Finding>[];
    if (rebuilds.takenOver && !rebuilds.reclaim()) {
      findings.rebuildsWereTakenOver();
      return const <Finding>[];
    }
    return rebuilds.findings(locator: locator);
  }

  /// Removes every hook. The registry restores the slots on its own
  /// dispose too; this also stops queued work from reaching [findings].
  void dispose() {
    findings.removeListener(_apply);
    errors.uninstall();
    images.uninstall();
    rebuilds.uninstall();
    paint.apply(const <DebugPaintFlag>{});
  }
}
