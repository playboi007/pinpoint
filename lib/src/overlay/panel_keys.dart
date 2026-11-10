import 'package:flutter/material.dart';

/// Keeps keys inside one of Pinpoint's panels, which sit above the
/// Navigator and below the app's own `Shortcuts`.
///
/// Its own focus scope: Tab moves between the panel's controls and wraps
/// around inside it, never onto an app widget behind it.
class PanelKeyScope extends StatelessWidget {
  const PanelKeyScope({
    super.key,
    this.shortcuts = const <ShortcutActivator, Intent>{},
    this.actions = const <Type, Action<Intent>>{},
    required this.child,
  });

  /// Added to `WidgetsApp.defaultShortcuts`.
  final Map<ShortcutActivator, Intent> shortcuts;

  /// Added to `WidgetsApp.defaultActions`.
  final Map<Type, Action<Intent>> actions;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        // Keys from the panel stop here, so they never reach the app's
        // Shortcuts above the wrapper or the focus holder, which would
        // swallow them. Unlike `handled`, this still lets the platform act
        // on the key: the browser types the character, an input method
        // composes.
        onKeyEvent: (node, event) => KeyEventResult.skipRemainingHandlers,
        // The same stack WidgetsApp puts above the app, which the barrier
        // above cuts off: Tab, Enter and Space for the controls, then text
        // editing keys for the fields (which hand Enter and Space to the
        // input method).
        child: Shortcuts(
          shortcuts: {...WidgetsApp.defaultShortcuts, ...shortcuts},
          child: DefaultTextEditingShortcuts(
            child: Actions(
              actions: {
                ...WidgetsApp.defaultActions,
                // EditableText passes Esc on when no text menu is open; in
                // the app a route takes it. Here the HardwareKeyboard
                // handler already acts on Esc, so nothing else must.
                DismissIntent: DoNothingAction(consumesKey: false),
                ...actions,
              },
              // Text selection handles and the context menu render in the
              // Overlay that InspectorOverlay provides around this layer.
              child: FocusTraversalGroup(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
