import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../detect/detector.dart';
import '../detect/detector_hooks.dart';
import '../detect/findings_controller.dart';
import '../env/environment_controller.dart';
import '../env/environment_host.dart';
import '../overlay/inspector_overlay.dart';
import '../search/source_resolver.dart';
import 'app_semantics.dart';
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

  /// Directly above the app's own widgets, below Pinpoint's wrappers. A
  /// picked widget's chain stops here.
  late final GlobalKey _contentKey = GlobalKey(
    debugLabel: 'pinpoint app content',
  );
  PinPointController? _ownController;
  HookRegistry? _hooks;

  /// Sets platform and slow motion; null while disabled.
  EnvironmentGlobals? _globals;

  /// The environment [_applyEnvironment] listens to.
  EnvironmentController? _environment;

  /// The hook-based detectors (errors, images); null while disabled.
  DetectorHooks? _detectors;

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
      _unwatchEnvironment();
      _ownController!.dispose();
      _ownController = null;
    }
    if (widget.config.enabled != oldWidget.config.enabled) {
      _uninstallHooks();
      if (widget.config.enabled) {
        _installHooks();
      } else {
        _controller.stop();
      }
    } else if (widget.config.enabled) {
      // The controller, and with it the environment, may have changed.
      _watchEnvironment();
      _watchFindings();
    }
  }

  /// Installs the hook-based detectors for the controller's findings,
  /// again when the controller changed.
  void _watchFindings() {
    final hooks = _hooks;
    final FindingsController findings = _controller.findings;
    if (hooks == null || identical(_detectors?.findings, findings)) return;
    _detectors?.dispose();
    _detectors = DetectorHooks(
      registry: hooks,
      findings: findings,
      appRoot: () => _appKey.currentContext?.findRenderObject(),
      locator: () => FindingLocator(
        resolver: SourceResolver.forConfig(widget.config),
        boundary: _contentKey.currentContext as Element?,
      ),
    );
  }

  void _installHooks() {
    final hooks = _hooks = HookRegistry()..addKeyHandler(_handleKey);
    _globals = EnvironmentGlobals(hooks);
    _watchEnvironment();
    _watchFindings();
  }

  /// Restores every global slot, the environment's and the detectors'
  /// included.
  void _uninstallHooks() {
    _unwatchEnvironment();
    _detectors?.dispose();
    _detectors = null;
    _globals = null;
    final platform = debugDefaultTargetPlatformOverride;
    _hooks?.dispose();
    _hooks = null;
    // The widgets still on screen were built for the overridden platform.
    // Rebuild them for the real one, so they never disagree with
    // defaultTargetPlatform (for example a wrapper that owned its
    // controller, mounted again by a platform switch outside web).
    if (debugDefaultTargetPlatformOverride != platform) {
      EnvironmentGlobals.reassemble();
    }
  }

  void _watchEnvironment() {
    final environment = _controller.environment;
    if (!identical(environment, _environment)) {
      _unwatchEnvironment();
      _environment = environment..addListener(_applyEnvironment);
    }
    _applyEnvironment();
  }

  void _unwatchEnvironment() {
    _environment?.removeListener(_applyEnvironment);
    _environment = null;
  }

  void _applyEnvironment() => _globals?.apply(_controller.environment.value);

  bool _handleKey(KeyEvent event) {
    // Esc stops the agent's running command and turns control off, in any
    // mode, idle included: the user must always be able to take the app
    // back. The key still goes on to Pinpoint's own Esc below and to the
    // app.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _controller.agent.enabled) {
      _controller.agent.abort();
    }
    // Alt alone is not claimed: it only switches the rulers to measuring
    // the gap between the selection and the hovered widget.
    _controller.setMeasuring(HardwareKeyboard.instance.isAltPressed);
    final editingText = _editingText();
    // While reviewing, the app has its keys unless the focus is in
    // Pinpoint's panel: arrows must not move the selection while the user
    // works in the app.
    final mode = _controller.reviewing && !_focusInPinpoint()
        ? PinPointMode.idle
        : _controller.mode;
    final action = keyActionFor(
      event,
      mode: mode,
      shortcut: widget.config.shortcut,
      modifiers: modifiersOf(HardwareKeyboard.instance),
      editingText: editingText,
      composing: editingText && _controller.draft.composing,
    );
    if (action == null) return false;
    // Act once per press, except navigation, which a held key repeats.
    // Repeats are claimed either way, below.
    if (event is KeyDownEvent || (event is KeyRepeatEvent && action.repeats)) {
      switch (action) {
        case KeyAction.toggle:
          _controller.toggle();
        case KeyAction.back:
          _controller.back();
        case KeyAction.freeze:
          _controller.toggleFreeze();
        case KeyAction.chainUp:
          _controller.stepSelection(up: true);
        case KeyAction.chainDown:
          _controller.stepSelection(up: false);
        case KeyAction.chainUpAll:
          _controller.stepSelection(up: true, localOnly: false);
        case KeyAction.chainDownAll:
          _controller.stepSelection(up: false, localOnly: false);
      }
    }
    // True only for Pinpoint's own keys. It does not stop the app's focused
    // widget from getting the key (the focus holder in InspectorOverlay does
    // that). It tells the embedder the key was handled, which on web can
    // stop the browser's default action for it.
    return true;
  }

  /// Whether primary focus is in a text field. While a mode is active the
  /// app cannot have focus (InspectorOverlay holds it), so this is
  /// Pinpoint's own comment field.
  /// Whether the primary focus is in Pinpoint's overlay, not in the app.
  static bool _focusInPinpoint() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return false;
    // Not `.of`: nothing here may subscribe an element (engineering rule 3).
    return context.findAncestorWidgetOfExactType<InspectorOverlay>() != null;
  }

  static bool _editingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return false;
    // Not `.of`: nothing here may subscribe an element (engineering rule 3).
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  void reassemble() {
    super.reassemble();
    // Held elements in the hover and selection can go stale across hot
    // reload.
    _controller.clearSelection();
  }

  @override
  void dispose() {
    // Puts timeDilation and the platform override back.
    _uninstallHooks();
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
    final environment = _controller.environment;
    return Stack(
      // Tight constraints, as the Navigator gets without Pinpoint. With the
      // default loose fit the Navigator still fills the screen, but anything
      // that reads its incoming constraints would see different values.
      fit: StackFit.expand,
      // Not directional, so the wrapper works without a Directionality.
      alignment: Alignment.topLeft,
      children: [
        // With no viewport the frame passes the Stack's constraints
        // straight on. With one, the app's boundary is no longer at the
        // screen origin and may be scaled: every rect is global and goes
        // through the frame's paint transform (engineering rule 7).
        ListenableBuilder(
          listenable: environment,
          builder: (context, child) => ViewportFrame(
            viewport: environment.value.viewport,
            keyboardHeight: environment.value.keyboardHeight ?? 0,
            child: child,
          ),
          child: RepaintBoundary(
            key: _appKey,
            // Inside the boundary, so screenshots show the overridden app,
            // and above the content key, so its widgets never appear in a
            // picked widget's chain.
            child: ListenableBuilder(
              listenable: environment,
              builder: (context, child) => EnvironmentHost(
                environment: environment.value,
                themeVariants: widget.config.themeVariants,
                child: child!,
              ),
              child: ListenableBuilder(
                listenable: _controller,
                // Always present; only `enabled` changes. TickerMode mutes
                // the app's tickers, so no frames are drawn for them while
                // frozen. It does not pause Timer or Future based logic. A
                // muted ticker keeps its start time, so on resume an
                // animation jumps ahead by the frozen time: a spinner looks
                // continuous, a one-shot transition may finish at once.
                builder: (context, child) => TickerMode(
                  enabled: !_controller.frozen,
                  // Always present too; only `excluding` changes. While a
                  // mode is active the app has no semantics, so a quick
                  // click on web is a pointer event the trap takes, not a
                  // semantics tap sent past it (see AppSemantics). Readers
                  // of the app's semantics show them again for their read.
                  child: ValueListenableBuilder<int>(
                    valueListenable: AppSemantics.readers,
                    builder: (context, readers, child) => ExcludeSemantics(
                      // Kept while reviewing: there is no trap, and the
                      // app must take its clicks.
                      excluding:
                          _controller.isActive &&
                          !_controller.reviewing &&
                          readers == 0,
                      child: child!,
                    ),
                    child: child,
                  ),
                ),
                // Innermost, so Pinpoint's wrappers stay out of the chain.
                child: KeyedSubtree(key: _contentKey, child: app),
              ),
            ),
          ),
        ),
        // Beside the app's TickerMode, not inside it: the comment field's
        // caret and the panel's animations keep running while the app is
        // frozen.
        InspectorOverlay(
          controller: _controller,
          appKey: _appKey,
          contentKey: _contentKey,
          config: widget.config,
          detectors: _detectors,
        ),
      ],
    );
  }
}
