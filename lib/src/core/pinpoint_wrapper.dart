import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../capture/screenshot.dart';
import '../detect/detector.dart';
import '../detect/detector_hooks.dart';
import '../detect/findings_controller.dart';
import '../env/environment_controller.dart';
import '../env/environment_host.dart';
import '../model/tape.dart';
import '../overlay/inspector_overlay.dart';
import '../overlay/replay_blocker.dart';
import '../search/render_search.dart';
import '../search/source_resolver.dart';
import '../sink/bridge_client.dart';
import '../tape/browser_page.dart';
import '../tape/tape_player.dart';
import '../theme/pinpoint_theme.dart';
import '../theme/pinpoint_tokens.dart';
import '../trace/redact.dart';
import '../trace/sources/error_source.dart';
import '../trace/sources/finding_source.dart';
import '../trace/sources/key_source.dart';
import '../trace/sources/message_source.dart';
import '../trace/sources/network_source.dart';
import '../trace/sources/pointer_source.dart';
import '../trace/sources/route_source.dart';
import '../trace/sources/text_source.dart';
import '../trace/trace_session.dart';
import 'app_semantics.dart';
import 'hook_registry.dart';
import 'keymap.dart';
import 'pinpoint_config.dart';
import 'pinpoint_controller.dart';
import 'rebuild_hook.dart';

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

  /// The one `debugOnRebuildDirtyWidget` callback, shared by the rebuild
  /// heat detector and the trace's rebuild source.
  RebuildHook? _rebuildHook;

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
      if (widget.config.trace.enabled != oldWidget.config.trace.enabled) {
        TraceSession.stopOwnedBy(this);
        _startTrace();
      }
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
      rebuildHook: _rebuildHook,
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
    _rebuildHook = RebuildHook(hooks);
    _globals = EnvironmentGlobals(hooks);
    _watchEnvironment();
    _watchFindings();
    _startTrace();
  }

  /// Starts the flight recorder and its level 1 sources (PLAN-v2
  /// Milestone 13), unless `TraceConfig.enabled` is false. A wrapper
  /// mounted again keeps the record of the one before it.
  void _startTrace() {
    final hooks = _hooks;
    final rebuildHook = _rebuildHook;
    if (hooks == null || rebuildHook == null) return;
    if (!widget.config.trace.enabled) return;
    final resolver = SourceResolver.forConfig(widget.config);
    final routes = RouteSource(appKey: _appKey);
    final session = TraceSession(
      owner: this,
      config: widget.config.trace,
      rebuildHook: rebuildHook,
      content: () => _contentKey.currentContext as Element?,
      resolver: resolver,
      recorder: TraceSession.current?.recorder,
      tapes: TraceSession.current?.tapes,
      pageStart: _pageStart,
      hooks: hooks,
      adapters: () => widget.config.stateAdapters,
      builtIn: [
        PointerSource(
          appKey: _appKey,
          contentKey: _contentKey,
          resolver: resolver,
          onUp: routes.tapped,
        ),
        KeySource(),
        TextSource(
          contentKey: _contentKey,
          resolver: resolver,
          agentTyping: () => _controller.agent.driving == 'enter_text',
        ),
        routes,
        ErrorSource(),
        NetworkSource(
          hooks: hooks,
          bodies: widget.config.trace.bodies,
          redact: TraceRedact(widget.config.trace.redact),
          ignoreOrigins: _bridgeOrigins(),
        ),
        MessageSource(redact: TraceRedact(widget.config.trace.redact)),
        FindingSource(findings: () => _controller.findings, resolver: resolver),
      ],
    );
    session.thumbnail = _thumbnail;
    // A page a replay restarted: answer requests from the tape now, before
    // the app's first build makes any (PLAN-v2 Milestone 15, step 7).
    TapePlayer.bootNetwork(session, storage: widget.config.trace.storage);
  }

  /// The page now, for the start of a tape (PLAN-v2 Milestone 15, step 1).
  /// Storage is copied only at app start ([t] 0) and only with
  /// `TraceConfig.storage`: it holds session tokens.
  TapeStart _pageStart({required int t, required int seq}) {
    final dispatcher = PlatformDispatcher.instance;
    final view = dispatcher.implicitView;
    final ratio = view?.devicePixelRatio;
    final page = browserPage();
    final environment = _controller.environment.value;
    return TapeStart(
      t: t,
      seq: seq,
      wallTime: DateTime.now().toUtc().toIso8601String(),
      url: page.url,
      width: view == null ? null : view.physicalSize.width / ratio!,
      height: view == null ? null : view.physicalSize.height / ratio!,
      pixelRatio: ratio,
      locale: dispatcher.locale.toLanguageTag(),
      environment: environment.isEmpty ? null : environment.toJson(),
      storage: t == 0 && widget.config.trace.storage && page.available
          ? page.readStorage()
          : null,
    );
  }

  /// The bridge's origin: its traffic (pins, drafts, the long poll) is
  /// Pinpoint's own and never recorded (rule 14).
  Set<String> _bridgeOrigins() {
    final bridge = BridgeClient.find(
      url: widget.config.bridgeUrl,
      sinks: widget.config.sinks,
    );
    if (bridge == null) return const <String>{};
    final base = bridge.base;
    return {'${base.scheme}://${base.authority}'};
  }

  /// A 400 px wide image of the app, for a mark.
  Future<Uint8List?> _thumbnail() async {
    final boundary = _appKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.attached) return null;
    final rect = RenderSearch.globalRectOf(boundary);
    if (rect == null) return null;
    final shot = await captureScreenshot(
      boundary,
      rect,
      // Not View.of: this runs outside build and must subscribe nothing.
      pixelRatio:
          WidgetsBinding
              .instance
              .platformDispatcher
              .implicitView
              ?.devicePixelRatio ??
          1,
      maxWidth: 400,
      outline: false,
    );
    return shot?.png;
  }

  /// Restores every global slot, the environment's and the detectors'
  /// included.
  void _uninstallHooks() {
    _unwatchEnvironment();
    // Before the registry: the sources give their slots back first.
    TraceSession.stopOwnedBy(this);
    _detectors?.dispose();
    _detectors = null;
    _rebuildHook = null;
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
    // Esc ends a replay, also one that holds with no command running, and
    // the player puts input, environment and network back.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        TapePlayer.current != null) {
      TapePlayer.current!.stop(reason: 'Esc');
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
    // The key source shares this one handler (no second one). Pinpoint's
    // own keys, and keys typed into its fields, are not recorded.
    if (TraceSession.ownedBy(this)?.source('key') case final KeySource keys) {
      keys.record(event, ours: action != null || _focusInPinpoint());
    }
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
        case KeyAction.mark:
          TraceSession.ownedBy(this)?.mark();
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
        // Over the app, under Pinpoint's UI: takes real pointer input while
        // a replay runs (PLAN-v2 Milestone 15, step 17). Always present.
        // In the user's palette: it sits outside the overlay's own Theme.
        ValueListenableBuilder<PinPointPalette>(
          valueListenable: _controller.palette,
          builder: (context, palette, child) =>
              Theme(data: pinPointThemeData(palette), child: child!),
          child: const ReplayBlocker(),
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
