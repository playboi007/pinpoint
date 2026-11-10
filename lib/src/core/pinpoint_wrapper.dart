import 'package:flutter/widgets.dart';

import '../overlay/inspector_overlay.dart';
import 'pinpoint_config.dart';
import 'pinpoint_controller.dart';

/// Hosts Pinpoint around an app.
///
/// Put it in `MaterialApp.builder`:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => PinPointWrapper(child: child),
/// )
/// ```
///
/// The builder sits above the Navigator, so dialogs, sheets and pushed routes
/// all render beneath Pinpoint's layer and its pointer trap. Moved below the
/// Navigator (for example into `home`), dialogs would escape the trap.
class PinPointWrapper extends StatefulWidget {
  const PinPointWrapper({
    super.key,
    required this.child,
    this.config = const PinPointConfig(),
    this.controller,
  });

  /// The app. Nullable because `MaterialApp.builder` passes null when the app
  /// has no `home`, `routes` or `onGenerateRoute`.
  final Widget? child;

  final PinPointConfig config;

  /// Optional external control. When null, the wrapper owns a controller.
  final PinPointController? controller;

  @override
  State<PinPointWrapper> createState() => _PinPointWrapperState();
}

class _PinPointWrapperState extends State<PinPointWrapper> {
  final GlobalKey _appKey = GlobalKey(debugLabel: 'pinpoint app');
  PinPointController? _ownController;

  PinPointController get _controller =>
      widget.controller ?? (_ownController ??= PinPointController());

  @override
  void didUpdateWidget(PinPointWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && _ownController != null) {
      _ownController!.dispose();
      _ownController = null;
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    // Held selections (Elements from Milestone 2 on) can go stale across hot
    // reload.
    _controller.clearSelection();
  }

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.child ?? const SizedBox.shrink();
    if (!widget.config.enabled) return app;

    // The shape of this tree never changes between modes (engineering rule
    // 5). Adding or removing a wrapper around the app would remount it and
    // lose its state.
    return Stack(
      // Tight constraints, as the Navigator gets without Pinpoint. With the
      // default loose fit the Navigator still fills the screen, but anything
      // that reads its incoming constraints would see different values.
      fit: StackFit.expand,
      // Not directional, so the wrapper works without a Directionality.
      alignment: Alignment.topLeft,
      children: [
        RepaintBoundary(key: _appKey, child: app),
        InspectorOverlay(
          controller: _controller,
          appKey: _appKey,
          config: widget.config,
        ),
      ],
    );
  }
}
