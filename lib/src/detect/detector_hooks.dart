import 'package:flutter/rendering.dart';

import '../core/hook_registry.dart';
import 'detector.dart';
import 'error_capture.dart';
import 'findings_controller.dart';
import 'image_detector.dart';

/// The detectors that work through global hooks, installed and removed as
/// [findings] turns them on and off. Every hook goes through the
/// wrapper's [HookRegistry] (engineering rule 1).
class DetectorHooks {
  DetectorHooks({
    required HookRegistry registry,
    required this.findings,
    required RenderObject? Function() appRoot,
    required FindingLocator Function() locator,
  }) : errors = ErrorCapture(
         registry: registry,
         onFindings: findings.addCaptured,
         locator: locator,
       ),
       images = ImagePaintRecorder(
         registry: registry,
         onFindings: findings.addCaptured,
         appRoot: appRoot,
       ) {
    findings.addListener(_apply);
    _apply();
  }

  final FindingsController findings;
  final ErrorCapture errors;
  final ImagePaintRecorder images;

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
  }

  /// Removes every hook. The registry restores the slots on its own
  /// dispose too; this also stops queued work from reaching [findings].
  void dispose() {
    findings.removeListener(_apply);
    errors.uninstall();
    images.uninstall();
  }
}
