import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_config.dart';
import '../core/pinpoint_controller.dart';
import 'highlight_painter.dart';
import 'pick_tracker.dart';
import 'toolbar.dart';

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

  /// Key of the `CustomPaint` that draws the hover and selection outlines.
  static const Key highlightKey = ValueKey<String>('pinpoint.highlight');

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

  /// Holds primary focus while a mode is active, so no app widget gets keys.
  final FocusNode _holder = FocusNode(
    debugLabel: 'pinpoint focus holder',
    skipTraversal: true,
  );

  /// The app's focus when the mode became active, restored on return to idle.
  FocusNode? _appFocus;
  bool _wasActive = false;

  late PickTracker _tracker = _newTracker();

  PickTracker _newTracker() =>
      PickTracker(controller: widget.controller, appKey: widget.appKey);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(InspectorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.appKey != widget.appKey) {
      _tracker.dispose();
      _tracker = _newTracker();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _onControllerChanged();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _tracker.dispose();
    _holder.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final active = widget.controller.isActive;
    if (active == _wasActive) return;
    _wasActive = active;
    if (active) {
      _takeFocus();
    } else {
      _restoreFocus();
    }
  }

  // A HardwareKeyboard handler sees every key but cannot stop the focused
  // field from getting it (docs/api-notes.md, item 6). Moving primary focus
  // to the holder can. Plain unfocus() is not enough: focus would move to the
  // enclosing scope and the app's Shortcuts (Tab, arrows) would still fire.
  void _takeFocus() {
    final current = FocusManager.instance.primaryFocus;
    _appFocus = identical(current, _holder) ? null : current;
    _holder.requestFocus();
  }

  void _restoreFocus() {
    final app = _appFocus;
    _appFocus = null;
    if (!_holder.hasFocus) return; // someone else moved focus; leave it
    // Restore only if the app's field is still in the tree. FocusNode.context
    // stays set after the node detaches, so check that it is still mounted.
    if (app != null && (app.context?.mounted ?? false) && app.canRequestFocus) {
      app.requestFocus();
    } else {
      _holder.unfocus();
    }
  }

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
          child: Focus(
            focusNode: _holder,
            // Every key that reaches the holder stops here while a mode is
            // active, so it never bubbles up to the app's Shortcuts. Pinpoint's
            // own keys arrive through the HardwareKeyboard handler instead.
            // Milestone 5: the comment form needs its own traversal shortcuts,
            // because Tab stops here too.
            onKeyEvent: (node, event) => widget.controller.isActive
                ? KeyEventResult.handled
                : KeyEventResult.ignored,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => Stack(
                fit: StackFit.expand,
                children: [
                  // The trap stays while commenting and sending, so a stray
                  // click never reaches the app behind the panel.
                  if (widget.controller.isActive)
                    _PointerTrap(tracker: _tracker),
                  IgnorePointer(
                    child: Builder(
                      builder: (paintContext) => CustomPaint(
                        key: InspectorOverlay.highlightKey,
                        painter: HighlightPainter(
                          hovered: widget.controller.hovered,
                          selected: widget.controller.selection,
                          origin: () => _originOf(paintContext),
                        ),
                      ),
                    ),
                  ),
                  // Above the trap, so it can always stop picking. Always
                  // offered by default: some shortcuts never reach Flutter.
                  if (widget.config.showLauncher)
                    LauncherLayer(
                      controller: widget.controller,
                      shortcutLabel: widget.config.shortcut.label,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Global position of the render object built at [context].
Offset _originOf(BuildContext context) {
  final box = context.findRenderObject();
  return box is RenderBox && box.attached
      ? box.localToGlobal(Offset.zero)
      : Offset.zero;
}

/// Covers the app and takes every pointer event, so none reaches the app,
/// its dialogs or its routes. The wrapper sits above the Navigator, which is
/// what puts this trap above dialogs.
class _PointerTrap extends StatelessWidget {
  const _PointerTrap({required this.tracker});

  final PickTracker tracker;

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: InspectorOverlay.trapKey,
      behavior: HitTestBehavior.opaque,
      onPointerHover: (event) => tracker.hoverAt(event.position),
      // Select on pointer down, not on hover: touch devices have no hover,
      // so a tap alone must select.
      onPointerDown: (event) {
        if (event.buttons & kPrimaryButton == 0) return;
        tracker.selectAt(event.position);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        // A stale outline must not stay on screen after the pointer leaves
        // the window (or moves onto Pinpoint's own panel).
        onExit: (_) => tracker.hoverAt(null),
        child: const SizedBox.expand(),
      ),
    );
  }
}
