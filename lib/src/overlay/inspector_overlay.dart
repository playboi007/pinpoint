import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../capture/context_collector.dart';
import '../capture/screenshot.dart';
import '../core/pinpoint_config.dart';
import '../core/pinpoint_controller.dart';
import '../model/annotation.dart';
import '../search/render_search.dart';
import '../search/source_resolver.dart';
import '../sink/markdown_formatter.dart';
import '../sink/pinpoint_sink.dart';
import 'highlight_painter.dart';
import 'info_panel.dart';
import 'pick_tracker.dart';
import 'ruler_painter.dart';
import 'toast_layer.dart';
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
    required this.contentKey,
    required this.config,
  });

  /// Key of the pointer trap that covers the app while a mode is active.
  static const Key trapKey = ValueKey<String>('pinpoint.trap');

  /// Key of the `CustomPaint` that draws the hover and selection outlines.
  static const Key highlightKey = ValueKey<String>('pinpoint.highlight');

  /// Key of the `CustomPaint` that draws the rulers.
  static const Key rulerKey = ValueKey<String>('pinpoint.rulers');

  final PinPointController controller;

  /// Key of the app's `RepaintBoundary`.
  final GlobalKey appKey;

  /// Key of the element directly above the app's own widgets.
  final GlobalKey contentKey;

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

  /// The comment field's focus.
  final FocusNode _commentFocus = FocusNode(debugLabel: 'pinpoint comment');

  /// The info panel's tab. A new selection from picking opens Comment.
  final ValueNotifier<PanelTab> _tab = ValueNotifier<PanelTab>(
    PanelTab.comment,
  );

  final ContextCollector _collector = ContextCollector();

  final ToastController _toasts = ToastController();

  /// The app's focus when the mode became active, restored on return to idle.
  FocusNode? _appFocus;
  PinPointMode _lastMode = PinPointMode.idle;

  late PickTracker _tracker = _newTracker();

  PickTracker _newTracker() => PickTracker(
    controller: widget.controller,
    appKey: widget.appKey,
    contentKey: widget.contentKey,
    resolver: SourceResolver.forConfig(widget.config),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _tab.addListener(_syncFocus);
  }

  @override
  void didUpdateWidget(InspectorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.appKey != widget.appKey ||
        oldWidget.contentKey != widget.contentKey) {
      _tracker.dispose();
      _tracker = _newTracker();
    } else if (oldWidget.config.projectRoot != widget.config.projectRoot ||
        !listEquals(
          oldWidget.config.localPathHints,
          widget.config.localPathHints,
        )) {
      _tracker.resolver = SourceResolver.forConfig(widget.config);
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
    _commentFocus.dispose();
    _tab.dispose();
    _toasts.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final mode = widget.controller.mode;
    final previous = _lastMode;
    if (mode == previous) return;
    _lastMode = mode;
    if (previous == PinPointMode.idle) _saveAppFocus();
    if (mode == PinPointMode.commenting && previous == PinPointMode.picking) {
      // Notifies _syncFocus when the tab changes; it runs again below.
      _tab.value = PanelTab.comment;
    }
    _syncFocus();
  }

  /// Puts focus where the mode and tab want it:
  ///
  /// - idle: back to the app's field.
  /// - picking, or the Info tab: the holder, so keys reach no field and the
  ///   arrow keys navigate the chain.
  /// - commenting or sending on the Comment tab: the comment field.
  void _syncFocus() {
    switch (widget.controller.mode) {
      case PinPointMode.idle:
        _restoreFocus();
      case PinPointMode.picking:
        _holder.requestFocus();
      case PinPointMode.commenting:
      case PinPointMode.sending:
        if (_tab.value == PanelTab.comment) {
          _focusComment();
        } else {
          _holder.requestFocus();
        }
    }
  }

  // Autofocus by hand: TextField.autofocus acts only on the field's first
  // build, and the field stays built across Esc and a new selection. This
  // takes focus from the app, which _restoreFocus gives back.
  void _focusComment() {
    if (_commentFocus.context?.mounted ?? false) {
      _commentFocus.requestFocus();
      return;
    }
    // The panel builds in the frame the mode change already scheduled.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(_commentFocus.context?.mounted ?? false)) return;
      final mode = widget.controller.mode;
      if (_tab.value == PanelTab.comment &&
          (mode == PinPointMode.commenting || mode == PinPointMode.sending)) {
        _commentFocus.requestFocus();
      }
    }, debugLabel: 'pinpoint.focusComment');
  }

  // A HardwareKeyboard handler sees every key but cannot stop the focused
  // field from getting it (docs/api-notes.md, item 6). Moving primary focus
  // to the holder can. Plain unfocus() is not enough: focus would move to the
  // enclosing scope and the app's Shortcuts (Tab, arrows) would still fire.
  void _saveAppFocus() {
    final current = FocusManager.instance.primaryFocus;
    final ours =
        identical(current, _holder) || identical(current, _commentFocus);
    _appFocus = ours ? null : current;
  }

  void _restoreFocus() {
    final app = _appFocus;
    _appFocus = null;
    // The comment field is inside the holder, so this is true while it has
    // focus too.
    if (!_holder.hasFocus) return; // someone else moved focus; leave it
    // Restore only if the app's field is still in the tree. FocusNode.context
    // stays set after the node detaches, so check that it is still mounted.
    // On mobile web, focusing a field opens the on-screen keyboard again, so
    // a field that is gone must not be focused by mistake either.
    if (app != null && (app.context?.mounted ?? false) && app.canRequestFocus) {
      app.requestFocus();
    } else {
      _holder.unfocus();
    }
  }

  /// The note for the selection with the draft's comment and intent, or null
  /// after a toast that says why not.
  Annotation? _collect() {
    final controller = widget.controller;
    final selection = controller.selection.value;
    if (selection == null) return null;
    try {
      // Pinpoint's own context: the page is read above the app.
      return _collector.collect(
        selection,
        controller.draft.text.text,
        controller.draft.intent,
        context: context,
      );
    } catch (error) {
      _toasts.show('Could not build the note: ${_short(error)}', error: true);
      return null;
    }
  }

  /// Collects the note and gives it to every sink, in order, with a toast
  /// per sink. Goes idle and clears the comment when all of them took it;
  /// otherwise back to commenting with the comment kept, where Copy as
  /// Markdown still works, so the comment is never lost.
  Future<void> _send() async {
    final controller = widget.controller;
    final draft = controller.draft;
    if (controller.selection.value == null || !draft.hasText) return;
    if (!controller.submit()) return;
    var note = _collect();
    if (note == null) {
      controller.sendFailed();
      return;
    }
    // Before the capture: with no sink, nothing would take the image.
    final sinks = widget.config.sinks;
    if (sinks.isEmpty) {
      _toasts.show(
        'No sink is set up in PinPointConfig.sinks. Use Copy as Markdown.',
        error: true,
      );
      controller.sendFailed();
      return;
    }
    if (draft.includeScreenshot) {
      note = await _withScreenshot(note);
      if (!mounted) return;
    }
    final results = await sendToSinks(note, sinks);
    if (!mounted) return;
    for (final result in results) {
      if (result.ok) {
        _toasts.show('Sent to ${result.sink}');
      } else {
        _toasts.show(
          '${result.sink} failed: ${_short(result.error!)}',
          error: true,
        );
      }
    }
    if (results.every((result) => result.ok)) {
      draft.text.clear();
      controller.sendSucceeded();
    } else {
      controller.sendFailed();
    }
  }

  /// [note] with a screenshot of the selection. When the capture fails, the
  /// note goes without one, names `screenshot` in its errors, and a toast
  /// says why: the comment matters more than the image.
  Future<Annotation> _withScreenshot(Annotation note) async {
    final watch = Stopwatch()..start();
    try {
      final boundary = widget.appKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('the app boundary is missing');
      }
      // Read the rect from the frame that is captured.
      await paintSettled();
      if (!mounted) return note;
      final selection = widget.controller.selection.value;
      final rect = selection == null
          ? null
          : RenderSearch.globalRectOf(selection.renderObject);
      final ratio = math.min(
        MediaQuery.devicePixelRatioOf(context),
        maxPixelRatio,
      );
      final shot = rect == null
          ? null
          : await captureScreenshot(
              boundary,
              rect,
              pixelRatio: ratio,
            ).timeout(const Duration(seconds: 5));
      if (shot == null) {
        if (mounted) {
          _toasts.show('No screenshot: the widget is off screen', error: true);
        }
        return note.withError('screenshot');
      }
      // Read after the capture's awaits, so it is the tree just captured.
      final content = widget.contentKey.currentContext;
      bool? views;
      if (content != null && content.mounted) {
        views = platformViewsIn(content as Element, shot.crop);
      }
      final crop = shot.crop;
      var result = note.withScreenshot(
        ScreenshotInfo(
          file: '${note.id}.png',
          pixelRatio: shot.plan.pixelRatio,
          width: shot.plan.width,
          height: shot.plan.height,
          crop: PayloadRect(crop.left, crop.top, crop.width, crop.height),
          hasPlatformViews: views ?? false,
          debugPaint: debugPaintFlagsOn(),
          png: shot.png,
        ),
      );
      if (views == null) {
        result = result.withError('screenshot.hasPlatformViews');
      }
      _printTiming(watch.elapsed, shot);
      return result;
    } catch (error) {
      if (mounted) {
        _toasts.show('No screenshot: ${_short(error)}', error: true);
      }
      return note.withError('screenshot');
    }
  }

  static void _printTiming(Duration elapsed, Screenshot shot) {
    if (!kDebugMode) return;
    if (!debugPrintCaptureTimings && elapsed <= captureBudget) return;
    debugPrint(
      'pinpoint: screenshot ${shot.plan.width}x${shot.plan.height} '
      '(${(shot.png.length / 1024).toStringAsFixed(0)} KB) in '
      '${elapsed.inMilliseconds} ms',
    );
  }

  /// Puts the note on the clipboard as Markdown. Keeps the mode and the
  /// comment.
  Future<void> _copy() async {
    final note = _collect();
    if (note == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: markdownFor(note)));
      if (mounted) _toasts.show('Copied as Markdown');
    } catch (error) {
      if (mounted) _toasts.show('Copy failed: ${_short(error)}', error: true);
    }
  }

  static String _short(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length <= 160 ? text : '${text.substring(0, 159)}…';
  }

  @override
  Widget build(BuildContext context) {
    // `MaterialApp.builder` sits above the Navigator, so there is no Overlay
    // ancestor here. Text fields and tooltips in Pinpoint's UI need one.
    return Theme(
      data: _theme,
      // Fixed like the theme: the panel's header has a fixed height and
      // overflows at a large system text scale. The page context the
      // collector reads sits above this, so notes keep the real scale.
      child: MediaQuery.withNoTextScaling(
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
                        builder: (paintContext) => Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(
                              key: InspectorOverlay.rulerKey,
                              painter: RulerPainter(
                                selected: widget.controller.selection,
                                hovered: widget.controller.hovered,
                                measuring: widget.controller.measuring,
                                origin: () => _originOf(paintContext),
                              ),
                            ),
                            CustomPaint(
                              key: InspectorOverlay.highlightKey,
                              painter: HighlightPainter(
                                hovered: widget.controller.hovered,
                                selected: widget.controller.selection,
                                origin: () => _originOf(paintContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Above the trap, so clicks on the panel never pick.
                    InfoPanelLayer(
                      controller: widget.controller,
                      tab: _tab,
                      commentFocus: _commentFocus,
                      onSend: _send,
                      onCopy: _copy,
                    ),
                    ToastLayer(toasts: _toasts),
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
      // The trap takes the wheel too; pass it on so the app still scrolls.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) tracker.scrollAt(event);
      },
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
