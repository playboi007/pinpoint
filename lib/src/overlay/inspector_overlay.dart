import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_config.dart';
import '../core/pinpoint_controller.dart';

/// Pinpoint's own UI layer, painted above the app.
///
/// It sits beside the app's `RepaintBoundary`, never inside it, so it is
/// never picked or captured (engineering rule 6).
class InspectorOverlay extends StatefulWidget {
  const InspectorOverlay({
    super.key,
    required this.controller,
    required this.appKey,
    required this.config,
  });

  /// Key of the pointer trap that covers the app while a mode is active.
  static const Key trapKey = ValueKey<String>('pinpoint.trap');

  final PinPointController controller;

  /// Key of the app's `RepaintBoundary`.
  final GlobalKey appKey;

  final PinPointConfig config;

  @override
  State<InspectorOverlay> createState() => _InspectorOverlayState();
}

class _InspectorOverlayState extends State<InspectorOverlay> {
  /// A fixed theme keeps the tool readable whatever the app's theme is.
  static final ThemeData _theme = ThemeData(
    colorSchemeSeed: const Color(0xFF2962FF),
    brightness: Brightness.light,
  );

  @override
  Widget build(BuildContext context) {
    // `MaterialApp.builder` sits above the Navigator, so there is no Overlay
    // ancestor here. Text fields and tooltips in Pinpoint's UI need one.
    return Theme(
      data: _theme,
      child: Overlay.wrap(
        child: Material(
          // Transparency does not absorb hits, so in idle mode every pointer
          // event outside Pinpoint's own controls falls through to the app.
          type: MaterialType.transparency,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => Stack(
              fit: StackFit.expand,
              children: [
                // The trap stays while commenting and sending, so a stray
                // click never reaches the app behind the panel.
                if (widget.controller.isActive)
                  _PointerTrap(controller: widget.controller),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Covers the app and takes every pointer event, so none reaches the app,
/// its dialogs or its routes. The wrapper sits above the Navigator, which is
/// what puts this trap above dialogs.
class _PointerTrap extends StatelessWidget {
  const _PointerTrap({required this.controller});

  final PinPointController controller;

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: InspectorOverlay.trapKey,
      behavior: HitTestBehavior.opaque,
      onPointerHover: (event) => controller.hover(event.position),
      // Select on pointer down, not on hover: touch devices have no hover,
      // so a tap alone must select.
      onPointerDown: (event) {
        if (event.buttons & kPrimaryButton == 0) return;
        controller.select(event.position);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        // A stale outline must not stay on screen after the pointer leaves.
        onExit: (_) => controller.hover(null),
        child: const SizedBox.expand(),
      ),
    );
  }
}
