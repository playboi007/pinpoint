import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../capture/context_collector.dart';
import '../capture/screenshot.dart';
import '../core/note_sync.dart';
import '../core/pinpoint_config.dart';
import '../core/pinpoint_controller.dart';
import '../detect/a11y_audit.dart';
import '../detect/detector.dart';
import '../detect/detector_hooks.dart';
import '../detect/image_detector.dart';
import '../detect/overflow_detector.dart';
import '../detect/truncation_detector.dart';
import '../model/annotation.dart';
import '../search/pick_result.dart';
import '../search/render_search.dart';
import '../search/source_resolver.dart';
import '../sink/bridge_client.dart';
import '../sink/http_sink.dart';
import '../sink/markdown_formatter.dart';
import '../sink/pinpoint_sink.dart';
import '../tweak/tweak_scope.dart';
import '../tweak/tweak_session.dart';
import 'environment_panel.dart';
import 'findings_panel.dart';
import 'highlight_painter.dart';
import 'info_panel.dart';
import 'note_view.dart';
import 'pick_tracker.dart';
import 'pin_marker.dart';
import 'pin_tracker.dart';
import 'ruler_painter.dart';
import 'toast_layer.dart';
import 'toolbar.dart';
import 'tweak_panel.dart';

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
    this.detectors,
  });

  /// Key of the pointer trap that covers the app while a mode is active.
  static const Key trapKey = ValueKey<String>('pinpoint.trap');

  /// Key of the `CustomPaint` that draws the hover and selection outlines.
  static const Key highlightKey = ValueKey<String>('pinpoint.highlight');

  /// Key of the `CustomPaint` that draws the rulers.
  static const Key rulerKey = ValueKey<String>('pinpoint.rulers');

  /// Key of the `CustomPaint` that outlines the hovered finding.
  static const Key findingKey = ValueKey<String>('pinpoint.finding');

  /// Key of the `CustomPaint` that outlines tweaked widgets.
  static const Key tweakOutlineKey = ValueKey<String>('pinpoint.tweakOutline');

  final PinPointController controller;

  /// Key of the app's `RepaintBoundary`.
  final GlobalKey appKey;

  /// Key of the element directly above the app's own widgets.
  final GlobalKey contentKey;

  final PinPointConfig config;

  /// The hook-based detectors, for rebuild heat in a scan. Null in tests
  /// that build the overlay alone.
  final DetectorHooks? detectors;

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

  /// The HTTP sinks that did not answer their health check, for the badge.
  final ValueNotifier<List<HttpSink>> _offline = ValueNotifier<List<HttpSink>>(
    const <HttpSink>[],
  );

  /// Whether the what-if panel is open. It closes when the mode goes idle.
  final ValueNotifier<bool> _environmentPanel = ValueNotifier<bool>(false);

  /// Whether the findings list is open. It takes turns with the what-if
  /// panel, in the same place, and closes when the mode goes idle.
  final ValueNotifier<bool> _findingsPanel = ValueNotifier<bool>(false);

  /// Whether a rescan waits for the end of the frame.
  bool _rescanQueued = false;

  /// Counts health checks, so an older one never overwrites a newer one.
  int _healthCheck = 0;

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

  late PinTracker _pins = _newPins();

  PinTracker _newPins() => PinTracker(
    notes: widget.controller.notes,
    contentKey: widget.contentKey,
    resolver: SourceResolver.forConfig(widget.config),
  );

  /// The bridge sync, or null without a bridge.
  NoteSync? _sync;

  /// Holds a draft's edits for a moment, so the bridge gets one PATCH per
  /// pause in typing, not one per key.
  Timer? _editTimer;

  NoteSync? _newSync() {
    final client = BridgeClient.find(
      url: widget.config.bridgeUrl,
      sinks: widget.config.sinks,
    );
    if (client == null) return null;
    return NoteSync(
      client: client,
      notes: widget.controller.notes,
      // Two tabs of different apps can poll one bridge. Each loads only
      // the notes written on its own origin.
      origin: NoteSync.pageOrigin(),
      onAgentChange: (note) {
        if (!mounted) return;
        final number = widget.controller.notes.numberOf(note.id);
        _toasts.show(
          'Note ${number ?? ''} is ${PinMarker.label(note.status)}'
          '${note.messages.isEmpty ? '' : ': ${_short(note.messages.last.text)}'}',
        );
      },
      onError: (message) {
        if (mounted) _toasts.show(_short(message), error: true);
      },
    );
  }

  late final NoteActions _noteActions = NoteActions(
    send: (id) => unawaited(_sendNotes([id])),
    sendAll: () => unawaited(
      _sendNotes([for (final n in widget.controller.notes.drafts) n.id]),
    ),
    delete: _deleteNote,
    accept: (id) => _setStatus(id, NoteStatus.verified),
    reopen: (id) => _setStatus(id, NoteStatus.submitted),
    edit: _editNote,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.controller.environment.addListener(_onEnvironmentChanged);
    _tab.addListener(_syncFocus);
    _environmentPanel.addListener(() {
      if (_environmentPanel.value) _findingsPanel.value = false;
    });
    _findingsPanel.addListener(() {
      if (_findingsPanel.value) _environmentPanel.value = false;
    });
    _startSync();
  }

  /// Loads the pins once: a restarted app gets them back. One request, not
  /// a poll; the poll runs only while the overlay is active.
  void _startSync() {
    _sync = _newSync();
    final sync = _sync;
    if (sync == null) return;
    unawaited(sync.load());
    sync.active = widget.controller.isActive;
  }

  @override
  void didUpdateWidget(InspectorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.appKey != widget.appKey ||
        oldWidget.contentKey != widget.contentKey) {
      _tracker.dispose();
      _tracker = _newTracker();
      _pins.dispose();
      _pins = _newPins();
    } else if (oldWidget.config.projectRoot != widget.config.projectRoot ||
        !listEquals(
          oldWidget.config.localPathHints,
          widget.config.localPathHints,
        )) {
      _tracker.resolver = SourceResolver.forConfig(widget.config);
      _pins.resolver = SourceResolver.forConfig(widget.config);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.environment.removeListener(_onEnvironmentChanged);
      widget.controller.addListener(_onControllerChanged);
      widget.controller.environment.addListener(_onEnvironmentChanged);
      _onControllerChanged();
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.config.bridgeUrl != widget.config.bridgeUrl ||
        !listEquals(oldWidget.config.sinks, widget.config.sinks)) {
      _sync?.dispose();
      _startSync();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    // After a hot reload held elements may be stale and lines may have
    // moved: every pin is looked up again.
    _pins.reset();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.environment.removeListener(_onEnvironmentChanged);
    _tracker.dispose();
    _pins.dispose();
    _sync?.dispose();
    _editTimer?.cancel();
    _holder.dispose();
    _commentFocus.dispose();
    _tab.dispose();
    _toasts.dispose();
    _offline.dispose();
    _environmentPanel.dispose();
    _findingsPanel.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final mode = widget.controller.mode;
    final previous = _lastMode;
    if (mode == previous) return;
    _lastMode = mode;
    // Polls only while active: an idle overlay must not keep the network
    // busy or the tab awake.
    _sync?.active = widget.controller.isActive;
    if (mode == PinPointMode.idle) {
      _environmentPanel.value = false;
      _findingsPanel.value = false;
    }
    if (previous == PinPointMode.idle) {
      _saveAppFocus();
      // Once per start, never per frame (rule 2), and never while idle.
      unawaited(_checkBridges());
    }
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
      if (!mounted) return;
      if (!(_commentFocus.context?.mounted ?? false)) {
        // A sent note shows no field. Keys must still stay away from the
        // app.
        if (widget.controller.isActive) _holder.requestFocus();
        return;
      }
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

  /// Asks each HTTP sink's bridge for its health, all at once, and keeps
  /// the ones that did not answer for the badge.
  Future<void> _checkBridges() async {
    final sinks = widget.config.sinks.whereType<HttpSink>().toList();
    final check = ++_healthCheck;
    if (sinks.isEmpty) {
      _offline.value = const <HttpSink>[];
      return;
    }
    final reachable = await Future.wait([
      for (final sink in sinks) sink.isReachable(),
    ]);
    if (!mounted || check != _healthCheck) return;
    _offline.value = [
      for (final (i, sink) in sinks.indexed)
        if (!reachable[i]) sink,
    ];
  }

  /// The note for the selection with the draft's comment and intent, or null
  /// after a toast that says why not.
  Annotation? _collect() {
    final controller = widget.controller;
    final selection = controller.selection.value;
    if (selection == null) return null;
    try {
      // Pinpoint's own context: the page is read above the app.
      final note = _collector.collect(
        selection,
        controller.draft.text.text,
        controller.draft.intent,
        context: context,
        environment: controller.environment.toJson(),
      );
      // Every edit on screen, not only the selected widget's: the note says
      // how the screen should look.
      final tweaks = controller.tweaks;
      if (tweaks.isEmpty) return note;
      final cut = tweaks.length > TweakSession.maxInNote;
      final withTweaks = note.copyWith(tweaks: tweaks.toJson());
      return cut
          ? withTweaks.copyWith(truncated: [...withTweaks.truncated, 'tweaks'])
          : withTweaks;
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
    final selection = controller.selection.value!;
    if (!controller.submit()) return;
    var note = _collect()?.withStatus(NoteStatus.submitted);
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
      note = await _withScreenshot(note, pair: note.tweaks.isNotEmpty);
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
      _pin(note, selection);
      draft.text.clear();
      controller.sendSucceeded();
    } else {
      controller.sendFailed();
      // The bridge may have stopped since picking started.
      unawaited(_checkBridges());
    }
  }

  /// Keeps the comment as a draft pin: collected and captured now, while
  /// the widget looks the way the comment means, but sent to no agent.
  /// Back to picking, for the next widget.
  Future<void> _saveDraft() async {
    final controller = widget.controller;
    final draft = controller.draft;
    final selection = controller.selection.value;
    if (selection == null || !draft.hasText) return;
    if (!controller.submit()) return;
    var note = _collect();
    if (note == null) {
      controller.sendFailed();
      return;
    }
    if (draft.includeScreenshot) {
      note = await _withScreenshot(note, pair: note.tweaks.isNotEmpty);
      if (!mounted) return;
    }
    _pin(note, selection);
    draft.text.clear();
    controller.draftSaved();
    _toasts.show(
      'Saved as draft ${controller.notes.numberOf(note.id) ?? ''}. '
      'The agent sees it once you send it.',
    );
    // On the bridge too, so it survives a restart. Drafts go to a folder
    // no agent reads.
    unawaited(_sync?.save(note));
  }

  /// Shows [note] as a pin on [selection]'s widget.
  void _pin(Annotation note, PickResult selection) {
    _pins.seed(note.id, selection.element);
    widget.controller.notes.put(note);
  }

  /// Opens the note [id] in the panel, on its pin's widget.
  void _openPin(String id) {
    final element = _pins.elementOf(id);
    final root = widget.appKey.currentContext;
    final boundary = widget.contentKey.currentContext;
    if (element == null || root is! Element) return;
    final pick = PickResult.forElement(
      element,
      rootElement: root,
      chainBoundary: boundary is Element ? boundary : null,
      resolver: _tracker.resolver,
    );
    if (pick == null) return;
    _tab.value = PanelTab.comment;
    widget.controller.openPin(id, pick);
  }

  /// Submits the notes [ids] (drafts) to every sink, one after another.
  /// A note that every sink took becomes submitted; one that failed stays
  /// a draft, with a toast that says why.
  Future<void> _sendNotes(List<String> ids) async {
    final notes = widget.controller.notes;
    final sinks = widget.config.sinks;
    if (sinks.isEmpty) {
      _toasts.show('No sink is set up in PinPointConfig.sinks.', error: true);
      return;
    }
    var sent = 0;
    for (final id in ids) {
      final note = notes.byId(id);
      if (note == null || note.status != NoteStatus.draft) continue;
      if (note.comment.trim().isEmpty) continue;
      final submitted = note.withStatus(NoteStatus.submitted);
      final results = await sendToSinks(submitted, sinks);
      if (!mounted) return;
      final failed = results.where((r) => !r.ok).toList();
      if (failed.isEmpty) {
        notes.put(submitted);
        sent++;
      } else {
        for (final result in failed) {
          _toasts.show(
            'Note ${notes.numberOf(id) ?? ''}: ${result.sink} failed: '
            '${_short(result.error!)}',
            error: true,
          );
        }
      }
    }
    if (sent > 0) {
      _toasts.show(sent == 1 ? 'Sent 1 note' : 'Sent $sent notes');
    }
  }

  /// Deletes the note, and closes the panel: there is nothing left to show
  /// on that widget.
  void _deleteNote(String id) {
    final controller = widget.controller;
    controller.clearSelection();
    controller.notes.remove(id);
    unawaited(_sync?.delete(id));
  }

  void _setStatus(String id, NoteStatus status) {
    final notes = widget.controller.notes;
    final note = notes.byId(id);
    if (note == null) return;
    // Accepted: the pin goes, and so does the panel.
    if (status == NoteStatus.verified) widget.controller.clearSelection();
    notes.put(note.withStatus(status));
    unawaited(_sync?.update(id, status: status));
  }

  void _editNote(String id, String comment) {
    final notes = widget.controller.notes;
    final note = notes.byId(id);
    if (note == null || note.status != NoteStatus.draft) return;
    notes.put(note.copyWith(comment: comment));
    _editTimer?.cancel();
    _editTimer = Timer(const Duration(milliseconds: 600), () {
      final latest = notes.byId(id);
      if (latest == null || latest.status != NoteStatus.draft) return;
      unawaited(_sync?.update(id, comment: latest.comment));
    });
  }

  /// Sets a value from the Tweak tab, with a toast when it did not take.
  bool _applyTweak(TweakTarget target, String property, Object? value) {
    final ok = widget.controller.tweaks.apply(target, property, value);
    if (!ok) {
      _toasts.show(
        'Could not set $property here; change it in source.',
        error: true,
      );
    }
    return ok;
  }

  /// Runs the scan-type detectors over the app as it is on screen now.
  void _scanFindings() {
    final root = widget.appKey.currentContext?.findRenderObject();
    if (root == null) return;
    final locator = _locator();
    final result = scanTree(root, [
      const OverflowDetector(),
      const TruncationDetector(),
      ImageDetector(devicePixelRatio: MediaQuery.devicePixelRatioOf(context)),
    ], locator: locator);
    widget.controller.findings.setScanned([
      ...result.findings,
      // Source locations of hot spots are resolved here, when the list
      // asks, never in the rebuild hook.
      ...?widget.detectors?.rebuildFindings(locator),
    ]);
  }

  FindingLocator _locator() {
    final content = widget.contentKey.currentContext;
    return FindingLocator(
      resolver: _tracker.resolver,
      boundary: content is Element ? content : null,
    );
  }

  /// Runs the accessibility audit: semantics on for one frame, then a
  /// capture for contrast.
  Future<void> _auditAccessibility() async {
    final findings = widget.controller.findings;
    final root = widget.appKey.currentContext?.findRenderObject();
    if (root == null || findings.auditing) return;
    findings.auditing = true;
    try {
      final result = await runAccessibilityAudit(
        root,
        locator: _locator(),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
      if (!mounted) return;
      findings.setAudited(result);
      if (result.isEmpty) _toasts.show('No accessibility problems found');
    } catch (error) {
      if (mounted) {
        _toasts.show('Audit failed: ${_short(error)}', error: true);
      }
    } finally {
      if (mounted) findings.auditing = false;
    }
  }

  /// A what-if change moves the layout: while the list is open, scan again
  /// once the frame that lays out the change is done. That frame is drawn
  /// anyway; this adds none (engineering rule 2).
  void _onEnvironmentChanged() {
    if (!_findingsPanel.value || _rescanQueued) return;
    _rescanQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _rescanQueued = false;
      if (mounted && _findingsPanel.value) _scanFindings();
    }, debugLabel: 'pinpoint.rescanFindings');
  }

  /// Makes [finding] a draft note on its nearest local widget, with the
  /// summary as the comment, the matching check for Milestone 12, and the
  /// current environment. The mode and the list stay, for the next one.
  Future<void> _noteFromFinding(Finding finding) async {
    final element = finding.element;
    final root = widget.appKey.currentContext;
    final boundary = widget.contentKey.currentContext;
    var pick = element == null || !element.mounted || root is! Element
        ? null
        : PickResult.forElement(
            element,
            rootElement: root,
            chainBoundary: boundary is Element ? boundary : null,
            resolver: _tracker.resolver,
          );
    if (pick == null) {
      _toasts.show('The widget is gone. Scan this screen again.', error: true);
      return;
    }
    // The widget written in this project, not the framework's render
    // widget inside it (RichText inside Text).
    final local = pick.chain.defaultIndex;
    if (local != null) pick = pick.selecting(local);
    final controller = widget.controller;
    Annotation note;
    try {
      note = _collector
          .collect(
            pick,
            finding.summary,
            finding.severity == Severity.info
                ? AnnotationIntent.improve
                : AnnotationIntent.bug,
            context: context,
            environment: controller.environment.toJson(),
          )
          .copyWith(
            finding: () => finding.toJson(),
            checks: checksFor(finding),
          );
    } catch (error) {
      _toasts.show('Could not build the note: ${_short(error)}', error: true);
      return;
    }
    if (controller.draft.includeScreenshot) {
      note = await _withScreenshot(note, target: pick.renderObject);
      if (!mounted) return;
    }
    _pin(note, pick);
    _toasts.show(
      'Saved as draft ${controller.notes.numberOf(note.id) ?? ''}. '
      'The agent sees it once you send it.',
    );
    unawaited(_sync?.save(note));
  }

  /// [note] with a screenshot of the selection. When the capture fails, the
  /// note goes without one, names `screenshot` in its errors, and a toast
  /// says why: the comment matters more than the image.
  ///
  /// With [pair], the image is the crop without the tweaks on the left and
  /// with them on the right (plan Milestone 11, step 11).
  Future<Annotation> _withScreenshot(
    Annotation note, {
    RenderObject? target,
    bool pair = false,
  }) async {
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
      final shown = target ?? selection?.renderObject;
      final rect = shown == null ? null : RenderSearch.globalRectOf(shown);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      if (pair && rect != null && shown != null) {
        final paired = await _captureTweakPair(boundary, shown, rect, ratio);
        if (!mounted) return note;
        if (paired != null) return _noteWithShot(note, paired, watch);
      }
      final shot = rect == null
          ? null
          : await captureScreenshot(
              boundary,
              rect,
              pixelRatio: ratio,
              maxWidth: widget.config.maxScreenshotWidth,
            ).timeout(const Duration(seconds: 5));
      if (shot == null) {
        if (mounted) {
          _toasts.show('No screenshot: the widget is off screen', error: true);
        }
        return note.withError('screenshot');
      }
      return _noteWithShot(note, (
        shot,
        shot.png,
        shot.plan.width,
        shot.plan.height,
        false,
      ), watch);
    } catch (error) {
      if (mounted) {
        _toasts.show('No screenshot: ${_short(error)}', error: true);
      }
      return note.withError('screenshot');
    }
  }

  /// [note] with [taken] as its screenshot: the capture, the PNG to send,
  /// its size, and whether it is a before and after pair.
  Annotation _noteWithShot(
    Annotation note,
    (Screenshot, Uint8List, int, int, bool) taken,
    Stopwatch watch,
  ) {
    final (shot, png, width, height, beforeAfter) = taken;
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
        width: width,
        height: height,
        crop: PayloadRect(crop.left, crop.top, crop.width, crop.height),
        hasPlatformViews: views ?? false,
        debugPaint: debugPaintFlagsOn(),
        beforeAfter: beforeAfter,
        png: png,
      ),
    );
    if (views == null) {
      result = result.withError('screenshot.hasPlatformViews');
    }
    _printTiming(watch.elapsed, shot);
    return result;
  }

  /// The crop around [shown] without the tweaks, then with them, side by
  /// side. Null when either capture fails; the caller then takes one
  /// image as usual.
  ///
  /// The tweaks come off for one frame and go back on whatever happens.
  /// Both halves use one crop: the union of the widget's rect before and
  /// after, so a tweak that moves it keeps both in view.
  Future<(Screenshot, Uint8List, int, int, bool)?> _captureTweakPair(
    RenderRepaintBoundary boundary,
    RenderObject shown,
    Rect after,
    double ratio,
  ) async {
    final tweaks = widget.controller.tweaks;
    final maxHalf =
        ((widget.config.maxScreenshotWidth - pairGap * maxPixelRatio) / 2)
            .floor();
    if (maxHalf < 1) return null;
    Screenshot? before;
    Rect crop = after;
    // Changes render objects: from this async handler, never during a
    // frame (the session asserts it).
    tweaks.suspend();
    try {
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return null;
      crop = after.expandToInclude(RenderSearch.globalRectOf(shown) ?? after);
      before = await captureScreenshot(
        boundary,
        crop,
        pixelRatio: ratio,
        maxWidth: maxHalf,
      ).timeout(const Duration(seconds: 5));
    } finally {
      tweaks.resume();
    }
    if (before == null || !mounted) return null;
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return null;
    final now = await captureScreenshot(
      boundary,
      crop,
      pixelRatio: ratio,
      maxWidth: maxHalf,
    ).timeout(const Duration(seconds: 5));
    if (now == null) return null;
    final joined = await sideBySide(
      before.png,
      now.png,
      gap: pairGap * now.plan.pixelRatio,
    );
    if (joined == null) return null;
    final (png, width, height) = joined;
    return (now, png, width, height, true);
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
    // The app's Material version, found as a widget: no dependency.
    final material3 =
        context.findAncestorWidgetOfExactType<Theme>()?.data.useMaterial3 ??
        true;
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
                            CustomPaint(
                              key: InspectorOverlay.tweakOutlineKey,
                              painter: TweakOutlinePainter(
                                outlines: widget.controller.tweaks.outlines,
                                origin: () => _originOf(paintContext),
                              ),
                            ),
                            CustomPaint(
                              key: InspectorOverlay.findingKey,
                              painter: FindingPainter(
                                findings: widget.controller.findings,
                                origin: () => _originOf(paintContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Above the trap, so a click on a pin opens its note
                    // instead of picking. In every mode, idle included.
                    PinLayer(placements: _pins.placements, onOpen: _openPin),
                    // Above the trap, so clicks on the panel never pick.
                    InfoPanelLayer(
                      controller: widget.controller,
                      tab: _tab,
                      commentFocus: _commentFocus,
                      onSend: _send,
                      onSaveDraft: _saveDraft,
                      onCopy: _copy,
                      noteActions: _noteActions,
                      onTweak: _applyTweak,
                    ),
                    // Above the trap, so clicks on it never pick.
                    EnvironmentPanelLayer(
                      controller: widget.controller,
                      panelOpen: _environmentPanel,
                      themeVariants: widget.config.themeVariants.keys.toList(),
                      material3: material3,
                    ),
                    // Above the trap, so clicks on it never pick.
                    FindingsPanelLayer(
                      controller: widget.controller,
                      panelOpen: _findingsPanel,
                      onScan: _scanFindings,
                      onAudit: () => unawaited(_auditAccessibility()),
                      onMakeNote: (finding) =>
                          unawaited(_noteFromFinding(finding)),
                    ),
                    FindingsButton(
                      controller: widget.controller,
                      panelOpen: _findingsPanel,
                    ),
                    // In idle too while any tweak is active.
                    TweakChip(session: widget.controller.tweaks),
                    // In idle too while an override is active.
                    EnvironmentBar(
                      controller: widget.controller,
                      panelOpen: _environmentPanel,
                    ),
                    if (widget.controller.isActive)
                      ValueListenableBuilder<List<HttpSink>>(
                        valueListenable: _offline,
                        builder: (context, offline, _) => offline.isEmpty
                            ? const SizedBox.shrink()
                            : BridgeBadge(
                                offline: [
                                  for (final sink in offline)
                                    '${sink.name} offline: '
                                        '${sink.url.authority}',
                                ],
                              ),
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
