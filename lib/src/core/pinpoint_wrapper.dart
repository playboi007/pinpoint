import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../overlay/inspector_overlay.dart';
import 'hook_registry.dart';
import 'keymap.dart';
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
  // Late, so a disabled wrapper (release builds) never creates it.
  late final GlobalKey _appKey = GlobalKey(debugLabel: 'pinpoint app');
  PinPointController? _ownController;
  HookRegistry? _hooks;

  PinPointController get _controller =>
      widget.controller ?? (_ownController ??= PinPointController());

  @override
  void initState() {
    super.initState();
    if (widget.config.enabled) _installHooks();
  }

  @override
  void didUpdateWidget(PinPointWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && _ownController != null) {
      _ownController!.dispose();
      _ownController = null;
    }
    if (widget.config.enabled != oldWidget.config.enabled) {
      _hooks?.dispose();
      _hooks = null;
      if (widget.config.enabled) {
        _installHooks();
      } else {
        _controller.stop();
      }
    }
  }

  void _installHooks() {
    _hooks = HookRegistry()..addKeyHandler(_handleKey);
  }

  bool _handleKey(KeyEvent event) {
    final action = keyActionFor(
      event,
      mode: _controller.mode,
      shortcut: widget.config.shortcut,
      modifiers: modifiersOf(HardwareKeyboard.instance),
    );
    if (action == null) return false;
    // Act once per press; repeats are still claimed below.
    if (event is KeyDownEvent) {
      switch (action) {
        case KeyAction.toggle:
          _controller.toggle();
        case KeyAction.back:
          _controller.back();
        case KeyAction.freeze:
          _controller.toggleFreeze();
      }
    }
    // True only for Pinpoint's own keys. It does not stop the app's focused
    // widget from getting the key (the focus holder in InspectorOverlay does
    // that). It tells the embedder the key was handled, which on web can
    // stop the browser's default action for it.
    return true;
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
    _hooks?.dispose();
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
        RepaintBoundary(
          key: _appKey,
          child: ListenableBuilder(
            listenable: _controller,
            // Always present; only `enabled` changes. TickerMode mutes the
            // app's tickers, so no frames are drawn for them while frozen.
            // It does not pause Timer or Future based logic. A muted ticker
            // keeps its start time, so on resume an animation jumps ahead by
            // the frozen time: a spinner looks continuous, a one-shot
            // transition may finish at once.
            builder: (context, child) =>
                TickerMode(enabled: !_controller.frozen, child: child!),
            child: app,
          ),
        ),
        InspectorOverlay(
          controller: _controller,
          appKey: _appKey,
          config: widget.config,
        ),
      ],
    );
  }
}
