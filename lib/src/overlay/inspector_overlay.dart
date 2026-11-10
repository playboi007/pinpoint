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
            builder: (context, _) => const Stack(
              fit: StackFit.expand,
              children: [],
            ),
          ),
        ),
      ),
    );
  }
}
