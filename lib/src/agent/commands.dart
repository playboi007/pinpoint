import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../capture/context_collector.dart';
import '../capture/screenshot.dart';
import '../core/pinpoint_controller.dart';
import '../detect/a11y_audit.dart';
import '../detect/detector.dart';
import '../detect/image_detector.dart';
import '../detect/overflow_detector.dart';
import '../detect/truncation_detector.dart';
import '../env/environment_controller.dart';
import '../model/annotation.dart';
import '../search/pick_result.dart';
import '../search/render_search.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';
import 'agent_control.dart';
import 'checks.dart';
import 'state_dump.dart';
import 'stress_matrix.dart';
import 'synthetic_input.dart';

/// A command failed for a reason the agent should read, for example
/// `stale handle h3`.
class AgentError implements Exception {
  const AgentError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How much a tool may return. Tool output is context the agent pays for
/// (watch out for): every list defaults to 20 items and every string to
/// 200 characters, with `limit` and `max_chars` to ask for more.
@immutable
class OutputLimits {
  const OutputLimits({this.items = defaultItems, this.chars = defaultChars});

  /// Reads `limit` and `max_chars` from [args].
  factory OutputLimits.from(Map<String, Object?> args) => OutputLimits(
    items: _clampInt(args['limit'], defaultItems, 1, maxItems),
    chars: _clampInt(args['max_chars'], defaultChars, 20, maxChars),
  );

  static const int defaultItems = 20;
  static const int defaultChars = 200;
  static const int maxItems = 200;
  static const int maxChars = 4000;

  final int items;
  final int chars;

  /// [text] cut to [chars].
  String clip(String text) => clipText(text, chars);

  static int _clampInt(Object? value, int fallback, int min, int max) {
    if (value is! num) return fallback;
    return value.round().clamp(min, max);
  }
}

/// One widget the agent can name: a short-lived handle.
class AgentHandle {
  AgentHandle(this.id, this.element, this.anchor, this.created);

  final String id;

  /// The element when the handle was made, or after the last re-resolve.
  Element element;

  /// What finds the widget again once [element] is gone.
  final NoteAnchor? anchor;

  final DateTime created;
}

/// The handles given out to the agent.
///
/// Handles hold elements, which die on rebuild (watch out for). On each
/// use a handle is checked against its anchor, re-resolved from it when
/// its element is gone, and refused as stale when that fails, never acted
/// on as another widget. A handle with no anchor to check (no source
/// location) cannot be checked, so it lives only [lifetime].
class HandleTable {
  HandleTable({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// How long a handle with no anchor can be used.
  static const Duration lifetime = Duration(seconds: 90);

  /// The most handles kept; the oldest go first.
  static const int maxHandles = 500;

  final DateTime Function() _clock;
  final Map<String, AgentHandle> _handles = <String, AgentHandle>{};
  int _next = 0;

  /// A new handle for [element].
  String add(Element element, NoteAnchor? anchor) {
    final id = 'h${++_next}';
    _handles[id] = AgentHandle(id, element, anchor, _clock());
    while (_handles.length > maxHandles) {
      _handles.remove(_handles.keys.first);
    }
    return id;
  }

  /// The live element for handle [id], re-resolved under [root] through
  /// [index] when it changed. Throws an [AgentError] for an unknown,
  /// expired or stale handle.
  Element resolve(
    String id, {
    required Element root,
    required SourceIndex index,
  }) {
    final handle = _handles[id];
    if (handle == null) {
      throw AgentError(
        'unknown handle $id; call get_screen or find_widgets for a new one',
      );
    }
    final anchor = handle.anchor;
    final checkable = anchor != null && anchor.resolvable;
    if (!checkable && _clock().difference(handle.created) > lifetime) {
      _handles.remove(id);
      throw AgentError(
        'stale handle $id (older than ${lifetime.inSeconds} s); find the '
        'widget again',
      );
    }
    final element = handle.element;
    // Exact, not the nearest line: within one run a widget does not move,
    // so a widget on another line is another widget. After a hot reload
    // the handles are dropped (AgentCommands.reassemble).
    if (element.mounted &&
        (!checkable || index.matchesExactly(element, anchor))) {
      return element;
    }
    if (checkable) {
      final again = index.resolveExact(anchor, root: root);
      if (again != null) return handle.element = again;
    }
    throw AgentError(
      'stale handle $id: its widget is gone; find the widget again',
    );
  }

  /// Forgets every handle.
  void clear() => _handles.clear();
}

/// Runs the agent's commands inside the app.
///
/// Created by the overlay, which knows the app's keys. Everything it reads
/// is under the app's boundary, so Pinpoint's own UI is never listed,
/// tapped or measured.
class AgentCommands {
  AgentCommands({
    required this.controller,
    required this.appKey,
    required this.contentKey,
    required this.resolver,
    required this.pageContext,
    this.onDraft,
    this.stateAdapters,
  });

  /// The app's state adapters for `get_state`.
  final List<StateAdapter> Function()? stateAdapters;

  /// Keeps a draft note the stress matrix filed: pins it and stores it on
  /// the bridge. Null: the note only goes into the controller's book.
  final void Function(Annotation note, PickResult pick)? onDraft;

  /// Pinpoint's own context, above the app: the collector describes the
  /// page from it, so no app element is touched for that.
  final BuildContext Function() pageContext;

  final ContextCollector _collector = ContextCollector();

  final PinPointController controller;

  /// Key of the app's `RepaintBoundary`.
  final GlobalKey appKey;

  /// Key of the element directly above the app's own widgets.
  final GlobalKey contentKey;

  /// Reads locations and decides which files are local.
  final SourceResolver Function() resolver;

  /// The handles given to the agent.
  final HandleTable handles = HandleTable();

  /// Runs [tool]. Matches [AgentRunner].
  Future<Map<String, Object?>> run(
    String tool,
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final limits = OutputLimits.from(args);
    try {
      args = withTarget(args);
      final Object result = switch (tool) {
        'run_steps' => await runSteps(args, cancel),
        'verify_note' => await verifyNote(args, cancel),
        'wait_idle' => await waitIdleTool(args, cancel),
        'tap' => await tap(args, cancel),
        'long_press' => await tap(args, cancel, long: true),
        'enter_text' => await enterText(args, limits, cancel),
        'scroll' => await scroll(args),
        'scroll_to' => await scrollTo(args, limits, cancel),
        'navigate' => await navigate(args, cancel),
        'back' => await back(cancel),
        'set_environment' => await setEnvironment(args, cancel),
        'reset_environment' => await resetEnvironment(cancel),
        'scan' => await scan(args, limits),
        'screenshot' => await screenshot(args),
        'stress_matrix' => await stressMatrix(args, limits, cancel),
        'get_state' => stateDump(
          element(args),
          adapters: stateAdapters?.call() ?? const <StateAdapter>[],
          items: limits.items,
          chars: limits.chars,
        ),
        'get_screen' => getScreen(limits),
        'find_widgets' => findWidgets(args, limits),
        'inspect' => inspect(args),
        'flash' => flash(args),
        _ => throw AgentError('unknown tool: $tool'),
      };
      return AgentControl.ok(result);
    } on AgentError catch (failure) {
      return AgentControl.error(failure.message);
    }
  }

  /// Tools a `run_steps` step may call. Not `inspect`, `screenshot`,
  /// `verify_note` or `stress_matrix`: the bridge shapes their answers,
  /// and inside a step they would come back as raw JSON or base64.
  static const Set<String> stepTools = {
    'get_screen',
    'find_widgets',
    'flash',
    'get_state',
    'scan',
    'wait_idle',
    'tap',
    'long_press',
    'enter_text',
    'scroll',
    'scroll_to',
    'navigate',
    'back',
    'set_environment',
    'reset_environment',
  };

  /// The most steps in one `run_steps`.
  static const int maxSteps = 20;

  /// `run_steps`: runs each step in order and stops at the first that
  /// fails. One round trip instead of one per step. Each step answers as
  /// its tool would, so a later step names its widget with a `target`
  /// query, not with a handle from an earlier step.
  Future<Map<String, Object?>> runSteps(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final steps = args['steps'];
    if (steps is! List<Object?> || steps.isEmpty) {
      throw const AgentError('steps is required: a list of {tool, …args}');
    }
    if (steps.length > maxSteps) {
      throw const AgentError('at most $maxSteps steps');
    }
    // Every step is checked before the first runs: a typo in step 3 must
    // not leave steps 1 and 2 done.
    for (final (i, step) in steps.indexed) {
      final tool = step is Map<String, Object?> ? step['tool'] : null;
      if (tool is! String || !stepTools.contains(tool)) {
        throw AgentError(
          'step ${i + 1}: ${tool is String ? '$tool cannot run in '
                    'run_steps' : 'give tool'}; use one of '
          '${stepTools.join(', ')}',
        );
      }
    }
    final done = <Map<String, Object?>>[];
    for (final (i, step) in steps.cast<Map<String, Object?>>().indexed) {
      cancel.check();
      final tool = step['tool']! as String;
      Map<String, Object?> answer;
      try {
        answer = await run(tool, {...step}..remove('tool'), cancel);
      } on AgentAborted {
        rethrow;
      } on Object catch (failure) {
        answer = AgentControl.error('$tool failed: $failure');
      }
      done.add({'step': i + 1, 'tool': tool, ...answer});
      if (answer['ok'] != true) {
        return {
          'steps': done,
          'stopped': 'at step ${i + 1} of ${steps.length}',
        };
      }
    }
    return {'steps': done};
  }

  /// [args] with its `target` query turned into a new `handle`, so every
  /// tool that takes a handle takes a target too. A target is found again
  /// on each call: it does not go stale as a handle can.
  Map<String, Object?> withTarget(Map<String, Object?> args) {
    final target = args['target'];
    if (target == null) return args;
    if (args['handle'] != null) {
      throw const AgentError('give handle or target, not both');
    }
    if (target is! Map<String, Object?>) {
      throw const AgentError(
        'target must be an object: file, line, type, text, key, index',
      );
    }
    final at = target['index'];
    final index = at is int ? at : 0;
    final found = matching(target, take: index + 1);
    if (index < 0 || index >= found.length) {
      throw AgentError(
        found.isEmpty
            ? 'no widget matches the target ${jsonEncode(target)}'
            : 'the target matches ${found.length} widgets; index $index is '
                  'out of range',
      );
    }
    final element = found[index];
    return {
      for (final MapEntry(:key, :value) in args.entries)
        if (key != 'target') key: value,
      'handle': handles.add(element, _anchorOf(element)),
    };
  }

  /// How long a command waits for the app to settle after a change. A
  /// route transition takes 300 ms; a screen with a looping animation
  /// never settles, and then each wait costs this much.
  static const Duration settleTimeout = Duration(seconds: 1);

  /// Runs a note's checks (plan Milestone 12, step 7): applies the note's
  /// environment, goes to its route when its widget is not on screen,
  /// waits for idle, finds the widget by its anchor, runs each check and
  /// takes an "after" screenshot. Then it puts the environment, the route
  /// and every scroll position back, whatever happened.
  Future<Map<String, Object?>> verifyNote(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final note = args['note'];
    if (note is! Map<String, Object?>) {
      throw const AgentError('note is required');
    }
    final anchorJson = note['anchor'];
    final anchor = anchorJson is Map<String, Object?>
        ? NoteAnchor.fromJson(anchorJson)
        : null;
    var checks = [
      for (final check
          in note['checks'] is List<Object?>
              ? note['checks']! as List<Object?>
              : const <Object?>[])
        if (check is Map<String, Object?> && check['type'] is String) check,
    ];
    final defaulted = checks.isEmpty;
    if (defaulted) {
      checks = const [
        {'type': 'visible'},
      ];
    }
    final Environment environment;
    try {
      final json = note['environment'];
      environment = Environment.fromJson(
        json is Map<String, Object?> ? json : const {},
      );
    } on FormatException catch (error) {
      throw AgentError("the note's environment: ${error.message}");
    }
    final page = note['page'];
    final route =
        anchor?.route ??
        (page is Map<String, Object?> && page['route'] is String
            ? page['route']! as String
            : null);

    await prepareToDrive();
    final before = controller.environment.value;
    final scroll = scrollSnapshot();
    var pushed = false;
    try {
      // The note is checked as it was filed: under its environment.
      controller.environment.value = environment;
      await waitIdle(settleTimeout, cancel);
      // Watch out for: after a hot reload the lines have moved. The anchor
      // goes through the nearest-line matching of SourceIndex.resolve,
      // never through its stored line alone.
      Element? target = _resolveAnchor(anchor);
      if (target == null && route != null && route != currentRoute()) {
        pushed = await pushRoute(route);
        await waitIdle(settleTimeout, cancel);
        target = _resolveAnchor(anchor);
      }
      if (target != null) {
        await ensureVisible(target);
        await waitIdle(settleTimeout, cancel);
      }
      cancel.check();
      final root = appRoot;
      final runner = CheckRunner(
        appRoot: root,
        content: contentRoot,
        resolver: resolver(),
        devicePixelRatio: devicePixelRatio,
      );
      final results = await runner.run(target, checks);
      cancel.check();
      final png = await capturePng(
        target == null ? null : renderObjectOf(target),
      );
      return {
        'id': note['id'],
        'passed': results.every((r) => r.passed),
        'found': target == null ? null : sourceOf(target),
        'checks': [for (final r in results) r.toJson()],
        if (defaulted) 'defaulted': 'the note has no checks; checked visible',
        'environment': environment.toJson(),
        'png': ?png,
      };
    } finally {
      // Restored on every path, a failure or Esc included.
      if (pushed) await popRoute();
      controller.environment.value = before;
      await _frame();
      restoreScroll(scroll);
      await waitIdle(settleTimeout, AgentCancel());
    }
  }

  Element? _resolveAnchor(NoteAnchor? anchor) {
    if (anchor == null || !anchor.resolvable) return null;
    return sourceIndex().resolve(anchor, root: contentRoot);
  }

  /// `file:line` of [element]'s constructor call, or null.
  String? sourceOf(Element element) {
    final location = resolver().locationOf(element);
    if (location == null) return null;
    return '${resolver().paths.relativePath(location.uri)}:${location.line}';
  }

  /// The device pixel ratio, read from Pinpoint's own context.
  double get devicePixelRatio =>
      MediaQuery.maybeDevicePixelRatioOf(pageContext()) ?? 1;

  /// Gets the app ready for a driving command. Picking mode's pointer trap
  /// would swallow synthetic events (watch out for), so picking stops
  /// first. While the user writes a note, the agent waits its turn.
  Future<void> prepareToDrive() async {
    switch (controller.mode) {
      case PinPointMode.idle:
        return;
      case PinPointMode.picking:
        controller.stop();
        // The trap goes in the frame the stop scheduled.
        await _frame();
      case PinPointMode.commenting:
      case PinPointMode.sending:
        throw const AgentError(
          'the user is writing a note in Pinpoint; try again when they are '
          'done',
        );
    }
  }

  /// Returns when no frame is scheduled and no animation runs, twice in a
  /// row, or false at [timeout]. A frame the app draws anyway is waited
  /// for; none is forced while idle (engineering rule 2), and a looping
  /// spinner ends at the timeout instead of hanging.
  Future<bool> waitIdle(Duration timeout, AgentCancel cancel) async {
    final expired = Completer<void>();
    final timer = Timer(timeout, expired.complete);
    try {
      final scheduler = SchedulerBinding.instance;
      var quiet = 0;
      while (!expired.isCompleted) {
        cancel.check();
        if (scheduler.hasScheduledFrame ||
            scheduler.schedulerPhase != SchedulerPhase.idle ||
            scheduler.transientCallbackCount > 0) {
          quiet = 0;
          await Future.any([scheduler.endOfFrame, expired.future]);
          continue;
        }
        if (++quiet >= 2) return true;
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 16)),
          expired.future,
        ]);
      }
      return false;
    } finally {
      timer.cancel();
    }
  }

  /// Waits for the frame a change scheduled; returns at once when none is.
  static Future<void> _frame() async {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.hasScheduledFrame ||
        scheduler.schedulerPhase != SchedulerPhase.idle) {
      await scheduler.endOfFrame;
    }
  }

  /// Pushes [path] as if the platform asked, through the navigation
  /// channel: `WidgetsBinding.handlePushRoute` is protected and
  /// visible-for-testing (docs/api-notes.md, item 12). Named-route apps and
  /// Router apps both listen to it. Returns whether someone handled it.
  static Future<bool> pushRoute(String path) => _navigation(
    MethodCall('pushRouteInformation', <String, Object?>{
      'location': path,
      'state': null,
    }),
  );

  /// Pops the current route as the back button does.
  static Future<bool> popRoute() => _navigation(const MethodCall('popRoute'));

  static Future<bool> _navigation(MethodCall call) {
    const codec = JSONMethodCodec();
    final done = Completer<bool>();
    // channelBuffers.push, not BinaryMessenger.handlePlatformMessage,
    // which is deprecated (docs/api-notes.md, item 12).
    ServicesBinding.instance.channelBuffers.push(
      SystemChannels.navigation.name,
      codec.encodeMethodCall(call),
      (reply) {
        if (done.isCompleted) return;
        try {
          done.complete(reply != null && codec.decodeEnvelope(reply) == true);
        } catch (_) {
          done.complete(false);
        }
      },
    );
    return done.future;
  }

  /// Every scroll position in the app and its offset, to put back after a
  /// command that moves things (verify, stress).
  List<(ScrollableState, double)> scrollSnapshot() {
    final found = <(ScrollableState, double)>[];
    var visited = 0;
    void visit(Element element) {
      if (++visited > 20000) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        try {
          if (state.position.hasPixels) {
            found.add((state, state.position.pixels));
          }
        } catch (_) {
          // No position yet.
        }
      }
      element.visitChildren(visit);
    }

    try {
      visit(contentRoot);
    } catch (_) {
      // The app is not on screen: nothing to put back.
    }
    return found;
  }

  /// Puts every scroll position of [snapshot] that is still there back.
  static void restoreScroll(List<(ScrollableState, double)> snapshot) {
    for (final (state, pixels) in snapshot) {
      if (!state.mounted) continue;
      try {
        final position = state.position;
        if (!position.hasContentDimensions) continue;
        position.jumpTo(
          pixels.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      } catch (_) {
        // Detached meanwhile.
      }
    }
  }

  /// Scrolls every scrollable above [element] so it shows. Uses
  /// `findAncestorStateOfType`, which subscribes nothing (engineering rule
  /// 3); `Scrollable.ensureVisible` would depend on the scope.
  Future<void> ensureVisible(Element element) async {
    final renderObject = renderObjectOf(element);
    if (renderObject == null) return;
    if (RenderSearch.visibleRectOf(renderObject) case final shown?
        when shown.width > 0 && shown.height > 0) {
      final rect = RenderSearch.globalRectOf(renderObject);
      // Already wholly on screen.
      if (rect != null &&
          shown.width >= rect.width - 0.5 &&
          shown.height >= rect.height - 0.5) {
        return;
      }
    }
    var context = element;
    for (var steps = 0; steps < 8; steps++) {
      final scrollable = context.findAncestorStateOfType<ScrollableState>();
      if (scrollable == null) break;
      if (!renderObject.attached) break;
      await scrollable.position.ensureVisible(renderObject, alignment: 0.5);
      context = scrollable.context as Element;
    }
  }

  /// A PNG (base64) of [target] outlined, or of the whole app with no
  /// target, at most [maxWidth] wide. Null when the capture fails.
  Future<String?> capturePng(RenderObject? target, {int maxWidth = 800}) async {
    try {
      final boundary = appRoot;
      if (boundary is! RenderRepaintBoundary) return null;
      final rect = target == null
          ? RenderSearch.globalRectOf(boundary)
          : RenderSearch.globalRectOf(target);
      if (rect == null) return null;
      final shot = await captureScreenshot(
        boundary,
        rect,
        pixelRatio: devicePixelRatio,
        maxWidth: maxWidth,
        outline: target != null,
      ).timeout(const Duration(seconds: 5));
      return shot == null ? null : base64Encode(shot.png);
    } catch (_) {
      return null;
    }
  }

  /// `set_environment`: changes only the switches given (keys as in a
  /// note's `environment`); null clears one.
  Future<Map<String, Object?>> setEnvironment(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final changes = {
      for (final MapEntry(:key, :value) in args.entries)
        if (key != 'limit' && key != 'max_chars') key: value,
    };
    final Environment next;
    try {
      next = controller.environment.value.applyJson(changes);
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
    await prepareToDrive();
    controller.environment.value = next;
    await waitIdle(settleTimeout, cancel);
    return {'environment': next.toJson(), 'summary': next.summary};
  }

  /// `reset_environment`: removes every what-if override.
  Future<Map<String, Object?>> resetEnvironment(AgentCancel cancel) async {
    await prepareToDrive();
    controller.environment.reset();
    await waitIdle(settleTimeout, cancel);
    return {'environment': const <String, Object?>{}};
  }

  /// The kinds `scan` and `stress_matrix` know.
  static const Set<String> scanKinds = {
    'overflow',
    'truncated_text',
    'oversized_image',
    'accessibility',
  };

  /// The Milestone 10 detectors of [kinds] on the screen as it is now.
  /// `accessibility` runs the audit: semantics for one frame, and a
  /// capture for contrast.
  Future<List<Finding>> findingsFor(Set<String> kinds) async {
    final root = appRoot;
    final locator = this.locator();
    final detectors = <Detector>[
      if (kinds.contains('overflow')) const OverflowDetector(),
      if (kinds.contains('truncated_text')) const TruncationDetector(),
      if (kinds.contains('oversized_image'))
        ImageDetector(devicePixelRatio: devicePixelRatio),
    ];
    final found = <Finding>[
      if (detectors.isNotEmpty)
        ...scanTree(root, detectors, locator: locator).findings,
    ];
    if (kinds.contains('accessibility')) {
      found.addAll(
        await runAccessibilityAudit(
          root,
          locator: locator,
          devicePixelRatio: devicePixelRatio,
        ),
      );
    }
    return dedupeFindings(found);
  }

  static Set<String> _kinds(Object? value, Set<String> fallback) {
    if (value == null) return fallback;
    if (value is! List<Object?>) {
      throw const AgentError('kinds must be a list');
    }
    final kinds = <String>{};
    for (final kind in value) {
      if (kind is! String || !scanKinds.contains(kind)) {
        throw AgentError('unknown kind: $kind; use ${scanKinds.join(', ')}');
      }
      kinds.add(kind);
    }
    return kinds;
  }

  /// [finding] as the agent sees it.
  Map<String, Object?> findingJson(Finding finding, OutputLimits limits) {
    final source = finding.source;
    final rect = finding.rect;
    return {
      'kind': finding.kind,
      'severity': finding.severity.name,
      'summary': limits.clip(finding.summary),
      if (source != null)
        'source': '${resolver().paths.relativePath(source.uri)}:${source.line}',
      'route': ?finding.route,
      if (rect != null) 'rect': rectList(rect),
      'key': finding.key,
    };
  }

  /// `scan`: the detectors on the current screen.
  Future<Map<String, Object?>> scan(
    Map<String, Object?> args,
    OutputLimits limits,
  ) async {
    final kinds = _kinds(args['kinds'], const {
      'overflow',
      'truncated_text',
      'oversized_image',
    });
    final found = await findingsFor(kinds);
    final shown = found.take(limits.items).toList();
    return {
      'findings': [for (final f in shown) findingJson(f, limits)],
      if (found.length > shown.length) 'more': found.length - shown.length,
    };
  }

  /// `screenshot`: the whole app, or the handle's widget outlined, at most
  /// `max_width` wide (default 800).
  Future<Map<String, Object?>> screenshot(Map<String, Object?> args) async {
    final target = args['handle'] is String ? element(args) : null;
    final width = args['max_width'] is num
        ? (args['max_width']! as num).round().clamp(100, 1600)
        : 800;
    final png = await capturePng(
      target == null ? null : renderObjectOf(target),
      maxWidth: width,
    );
    if (png == null) throw const AgentError('the capture failed');
    return {'handle': ?args['handle'], 'png': png};
  }

  /// `stress_matrix` (plan Milestone 12, step 8): each run sets its
  /// environment, waits for idle, scans, and takes a 400 px thumbnail.
  /// Each distinct problem that a check can measure becomes a draft note
  /// with the environment of the first run that showed it. Truncation is
  /// often intended: an `info` finding is listed, never filed alone.
  ///
  /// The environment and every scroll position are put back afterwards,
  /// so a second run starts from the same state and reports the same
  /// findings; a draft already filed for a finding and environment is not
  /// filed again.
  Future<Map<String, Object?>> stressMatrix(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    final kinds = _kinds(args['kinds'], const {
      'overflow',
      'truncated_text',
      'accessibility',
    });
    List<T>? listOf<T>(String key, T? Function(Object? value) read) {
      final value = args[key];
      if (value == null) return null;
      if (value is! List<Object?>) throw AgentError('$key must be a list');
      return [
        for (final item in value)
          read(item) ?? (throw AgentError('$key: cannot read $item')),
      ];
    }

    double? positive(Object? v) => v is num && v > 0 ? v.toDouble() : null;
    T? byName<T extends Enum>(List<T> values, Object? v) {
      for (final value in values) {
        if (value.name == v) return value;
      }
      return null;
    }

    final base = controller.environment.value;
    final root = appRoot;
    final runs = stressRuns(
      base: base,
      height: base.viewport?.height ?? root.paintBounds.height,
      widths: listOf('widths', positive),
      textScales: listOf('textScales', positive),
      directions: listOf('directions', (v) => byName(TextDirection.values, v)),
      brightness: listOf('brightness', (v) => byName(Brightness.values, v)),
      full: args['full'] == true,
    );
    final thumbnails = args['thumbnails'] != false;

    await prepareToDrive();
    final scroll = scrollSnapshot();
    final runResults = <Map<String, Object?>>[];
    final distinct = <String, Map<String, Object?>>{};
    final drafts = <String>[];
    final existing = <String>[];
    try {
      for (final (i, run) in runs.indexed) {
        cancel.check();
        controller.environment.value = run.environment;
        await waitIdle(settleTimeout, cancel);
        final found = await findingsFor(kinds);
        cancel.check();
        for (final finding in found) {
          final seen = distinct[finding.key];
          if (seen != null) {
            (seen['runs']! as List<int>).add(i + 1);
            continue;
          }
          distinct[finding.key] = {
            ...findingJson(finding, limits),
            'runs': <int>[i + 1],
          };
          final filed = _fileDraft(finding, run);
          if (filed == null) continue;
          (filed.$2 ? existing : drafts).add(filed.$1);
        }
        final png = thumbnails ? await capturePng(null, maxWidth: 400) : null;
        runResults.add({
          'run': i + 1,
          'label': run.label,
          'environment': run.environment.toJson(),
          'findings': found.length,
          'png': ?png,
        });
      }
    } finally {
      controller.environment.value = base;
      await _frame();
      restoreScroll(scroll);
      await waitIdle(settleTimeout, AgentCancel());
    }
    return {
      'runs': runResults,
      'findings': distinct.values.toList(),
      'drafts': drafts,
      if (existing.isNotEmpty) 'existing': existing,
      if (args['full'] == true && runs.length >= stressMaxRuns)
        'truncated': 'at most $stressMaxRuns runs',
    };
  }

  /// Files [finding] from [run] as a draft note on its nearest local
  /// widget: `(id, false)` for a new draft, `(id, true)` when one for the
  /// same finding and environment exists, null when not filed.
  (String, bool)? _fileDraft(Finding finding, StressRun run) {
    if (finding.severity == Severity.info) return null;
    final checks = checksFor(finding);
    if (checks.isEmpty) return null;
    final environment = run.environment.toJson();
    final envKey = jsonEncode(environment);
    for (final note in controller.notes.notes) {
      if (note.finding?['key'] == finding.key &&
          jsonEncode(note.environment ?? const {}) == envKey) {
        return (note.id, true);
      }
    }
    final element = finding.element;
    if (element == null || !element.mounted) return null;
    var pick = pickFor(element);
    // The widget written in this project, not the framework's inside it.
    final local = pick.chain.defaultIndex;
    if (local != null) pick = pick.selecting(local);
    final note = _collector
        .collect(
          pick,
          'Stress matrix (${run.label}): ${finding.summary}',
          AnnotationIntent.bug,
          context: pageContext(),
          environment: environment,
        )
        .copyWith(finding: () => finding.toJson(), checks: checks);
    final keep = onDraft;
    if (keep == null) {
      controller.notes.put(note);
    } else {
      keep(note, pick);
    }
    return (note.id, false);
  }

  /// Drops every handle: after a hot reload lines have moved, and a
  /// handle must never land on another widget.
  void reassemble() => handles.clear();

  /// The live element of the handle in `args['handle']`.
  Element element(Map<String, Object?> args) {
    final id = args['handle'];
    if (id is! String || id.isEmpty) {
      throw const AgentError('handle is required');
    }
    return handles.resolve(id, root: contentRoot, index: sourceIndex());
  }

  /// Live widgets by source line, type, text or key: the reverse lookup.
  /// Visible ones first, then the rest (offstage routes, scrolled away).
  Map<String, Object?> findWidgets(
    Map<String, Object?> args,
    OutputLimits limits,
  ) {
    final ordered = matching(args, take: limits.items);
    final shown = ordered.take(limits.items).toList();
    return {
      'widgets': describeAll(shown, limits),
      if (ordered.length > shown.length) 'more': ordered.length - shown.length,
    };
  }

  /// The elements under [root] (the app when null) that fit the query in
  /// [args] (`file`, `line`, `type`, `text`, `key`), visible ones first.
  ///
  /// With [take], only the first [take] places are sorted: a visible rect
  /// walks every ancestor, so it is not measured for matches that cannot
  /// be among them (a `Text` query can match thousands).
  List<Element> matching(
    Map<String, Object?> args, {
    Element? root,
    int? take,
  }) {
    final file = _string(args['file']);
    final line = args['line'];
    final type = _string(args['type']);
    final text = _string(args['text'])?.toLowerCase();
    final key = _string(args['key']);
    if (file == null && type == null && text == null && key == null) {
      throw const AgentError('give at least one of file, type, text or key');
    }
    if (line != null && (line is! int || file == null)) {
      throw const AgentError('line must be an integer, with a file');
    }
    final matches = sourceIndex().query(
      root: root ?? contentRoot,
      file: file,
      line: line as int?,
      type: type,
      where: text == null && key == null
          ? null
          : (element) {
              if (key != null && !keyMatches(element.widget.key, key)) {
                return false;
              }
              if (text != null) {
                if (_isTextTwin(element)) return false;
                final shown = textOf(element);
                if (shown == null || !shown.toLowerCase().contains(text)) {
                  return false;
                }
              }
              return true;
            },
    );
    bool visible(Element e) {
      final renderObject = renderObjectOf(e);
      return renderObject != null &&
          RenderSearch.visibleRectOf(renderObject) != null;
    }

    final shown = <Element>[];
    final rest = <Element>[];
    for (final element in matches) {
      if (take != null && shown.length >= take) {
        rest.add(element);
      } else {
        (visible(element) ? shown : rest).add(element);
      }
    }
    return [...shown, ...rest];
  }

  /// Whether [widgetKey] is the key the agent named: its text as given
  /// (`[<'save'>]`) or the value inside it (`save`).
  static bool keyMatches(Key? widgetKey, String key) {
    if (widgetKey == null) return false;
    final text = widgetKey.toString();
    return text == key || text == "[<'$key'>]" || text == '[<$key>]';
  }

  /// `wait_idle`: whether the app settled within `timeout_ms` (default
  /// 2000).
  Future<Map<String, Object?>> waitIdleTool(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final ms = args['timeout_ms'];
    final timeout = ms is num ? ms.round().clamp(0, 60000) : 2000;
    final idle = await waitIdle(Duration(milliseconds: timeout), cancel);
    return {'idle': idle, 'timeout_ms': timeout};
  }

  /// A synthetic tap (or long press) at the center of the handle's
  /// visible part, after checking that nothing covers it.
  Future<Map<String, Object?>> tap(
    Map<String, Object?> args,
    AgentCancel cancel, {
    bool long = false,
  }) async {
    final target = element(args);
    await prepareToDrive();
    cancel.check();
    final renderObject = renderObjectOf(target);
    if (renderObject == null) {
      throw const AgentError('the widget is not laid out');
    }
    final visible = RenderSearch.visibleRectOf(renderObject);
    if (visible == null || visible.width <= 0 || visible.height <= 0) {
      throw const AgentError('not on screen; call scroll_to first');
    }
    final point = visible.center;
    // A what-if viewport leaves screen around the app: a point there is
    // over nothing (Milestone 9, RenderSearch.isOnApp).
    if (!RenderSearch.isOnApp(appRoot, point)) {
      throw const AgentError('outside the app viewport');
    }
    final viewId = SyntheticInput.viewIdOf(renderObject);
    final blocker = SyntheticInput.obscuredBy(
      renderObject,
      point,
      viewId: viewId,
      describe: describeObscurer,
    );
    if (blocker != null) throw AgentError('obscured by $blocker');
    controller.agent.mark(point, longPress: long);
    await SyntheticInput.press(
      point,
      viewId: viewId,
      cancel: cancel,
      hold: long ? SyntheticInput.longPressHold : SyntheticInput.tapHold,
    );
    await _frame();
    return {
      'handle': args['handle'],
      'tapped': [_round(point.dx), _round(point.dy)],
    };
  }

  /// The widget that covers a point: its nearest meaningful name, and
  /// whether it is Pinpoint's own (a pin, the launcher).
  String describeObscurer(RenderObject renderObject) {
    final locator = this.locator();
    final owner = locator.elementOf(renderObject);
    if (owner == null) return renderObject.runtimeType.toString();
    final name = _meaningfulName(owner);
    return locator.isInApp(owner) ? name : "Pinpoint's own $name";
  }

  /// Wrappers that say nothing about what covers a point.
  static const Set<String> _plain = {
    'AbsorbPointer',
    'Actions',
    'Align',
    'AnimatedBuilder',
    'BlockSemantics',
    'Builder',
    'Center',
    'ColoredBox',
    'ConstrainedBox',
    'Container',
    'CustomPaint',
    'DecoratedBox',
    'DefaultTextStyle',
    'ExcludeSemantics',
    'FadeTransition',
    'Focus',
    'FocusScope',
    'GestureDetector',
    'IconTheme',
    'IgnorePointer',
    'InkResponse',
    'InkWell',
    'KeyedSubtree',
    'Listener',
    'ListenableBuilder',
    'Material',
    'MergeSemantics',
    'MouseRegion',
    'Opacity',
    'Padding',
    'Positioned',
    'RawGestureDetector',
    'RepaintBoundary',
    'Semantics',
    'Shortcuts',
    'SizedBox',
    'Stack',
    'Tooltip',
    'ValueListenableBuilder',
  };

  /// Widgets that cover the app on purpose: named first when one of them
  /// is above the hit.
  static const Set<String> _covers = {
    'AlertDialog',
    'BottomSheet',
    'CupertinoAlertDialog',
    'Dialog',
    'Drawer',
    'ModalBarrier',
    'NavigationDrawer',
    'PinPointLauncher',
    'PinMarker',
    'SimpleDialog',
    'SnackBar',
  };

  /// The name of what covers a point: a known cover above the hit
  /// (a barrier, a dialog, a sheet), else the nearest widget from the
  /// app's own source, else the nearest public widget that is not a plain
  /// wrapper.
  String _meaningfulName(Element element) {
    final chain = <Element>[element];
    element.visitAncestorElements((ancestor) {
      chain.add(ancestor);
      return chain.length < 40;
    });
    String nameOf(Element e) =>
        e.widget.runtimeType.toString().split('<').first;
    // The outermost cover: an AlertDialog builds a Dialog inside it.
    String? cover;
    for (final e in chain) {
      if (_covers.contains(nameOf(e))) cover = nameOf(e);
    }
    if (cover != null) return cover;
    final resolver = this.resolver();
    for (final e in chain) {
      if (resolver.entryOf(e).isLocal) return nameOf(e);
    }
    for (final e in chain) {
      final name = nameOf(e);
      if (!name.startsWith('_') && !_plain.contains(name)) return name;
    }
    return nameOf(element);
  }

  /// Focuses the text field under the handle and sets its text as typing
  /// would: `userUpdateTextEditingValue` runs the input formatters and
  /// `onChanged` (docs/api-notes.md, item 13: it takes a cause too).
  Future<Map<String, Object?>> enterText(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    final text = args['text'];
    if (text is! String) throw const AgentError('text is required');
    final target = element(args);
    final field = _editableIn(target);
    if (field == null) {
      throw const AgentError('no text field at or under the handle');
    }
    if (field.widget.readOnly) {
      throw const AgentError('the field is read only or disabled');
    }
    await prepareToDrive();
    cancel.check();
    field.widget.focusNode.requestFocus();
    await _frame();
    cancel.check();
    if (!field.mounted) throw const AgentError('the field went away');
    field.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
    await _frame();
    final value = field.mounted ? field.textEditingValue.text : text;
    return {
      'handle': args['handle'],
      // Never echo a password back (engineering rule 9).
      'text': field.widget.obscureText ? '[masked]' : limits.clip(value),
      'focused': field.mounted && field.widget.focusNode.hasFocus,
    };
  }

  static EditableTextState? _editableIn(Element element) {
    EditableTextState? found;
    var visited = 0;
    void visit(Element e) {
      if (found != null || ++visited > 2000) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }

  /// Moves a scrollable by `dy` (a vertical one) or `dx` (a horizontal
  /// one): the nearest of that axis at or above the handle, or the main
  /// one with no handle. The axis decides, so a text field's own
  /// horizontal scrollable never takes a `dy` meant for the page.
  Future<Map<String, Object?>> scroll(Map<String, Object?> args) async {
    final dx = args['dx'];
    final dy = args['dy'];
    final vertical = dy is num && dy != 0;
    final horizontal = dx is num && dx != 0;
    if (vertical == horizontal) {
      throw const AgentError('give one of dy (vertical) or dx (horizontal)');
    }
    final axis = vertical ? Axis.vertical : Axis.horizontal;
    final delta = (vertical ? dy : dx)! as num;
    final target = args['handle'] == null ? null : element(args);
    await prepareToDrive();
    final scrollable = target == null
        ? mainScrollable(axis: axis)
        : scrollableFor(target, axis: axis);
    if (scrollable == null) {
      throw AgentError(
        'no ${axis.name} scrollable '
        '${target == null ? 'on screen' : 'at or above the widget'}',
      );
    }
    final position = scrollable.position;
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await _frame();
    return _scrollState(position);
  }

  static Map<String, Object?> _scrollState(ScrollPosition position) => {
    'pixels': _round(position.pixels),
    'min': _round(position.minScrollExtent),
    'max': _round(position.maxScrollExtent),
    'viewport': _round(position.viewportDimension),
    'axis': axisDirectionToAxis(position.axisDirection).name,
  };

  /// The scrollable of a handle: its own (a list's handle), else the
  /// nearest above it; with [axis], only one that scrolls along it. Found
  /// without subscribing (engineering rule 3).
  static ScrollableState? scrollableFor(Element element, {Axis? axis}) {
    bool fits(Element e) =>
        e is StatefulElement &&
        e.state is ScrollableState &&
        (axis == null ||
            axisDirectionToAxis((e.state as ScrollableState).axisDirection) ==
                axis);
    ScrollableState? found;
    var visited = 0;
    void visit(Element e) {
      if (found != null || ++visited > 200) return;
      if (fits(e)) {
        found = (e as StatefulElement).state as ScrollableState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    if (found != null) return found;
    element.visitAncestorElements((e) {
      if (!fits(e)) return true;
      found = (e as StatefulElement).state as ScrollableState;
      return false;
    });
    return found;
  }

  /// The biggest scrollable on screen, of [axis] when given: the page's
  /// main list.
  ScrollableState? mainScrollable({Axis? axis}) {
    ScrollableState? best;
    var bestArea = 0.0;
    var visited = 0;
    void visit(Element e) {
      if (++visited > 20000) return;
      if (e is StatefulElement &&
          e.state is ScrollableState &&
          (axis == null ||
              axisDirectionToAxis((e.state as ScrollableState).axisDirection) ==
                  axis)) {
        final renderObject = renderObjectOf(e);
        final shown = renderObject == null
            ? null
            : RenderSearch.visibleRectOf(renderObject);
        final area = shown == null ? 0.0 : shown.width * shown.height;
        if (area > bestArea) {
          bestArea = area;
          best = e.state as ScrollableState;
        }
      }
      e.visitChildren(visit);
    }

    visit(contentRoot);
    return best;
  }

  /// `scroll_to`: with a handle, brings it into view. With a query, scrolls
  /// a list one screen at a time until a matching widget is built, then
  /// brings it into view.
  ///
  /// Lazy lists build only what is near the screen (watch out for):
  /// `find_widgets` cannot see an item that was never built, so this
  /// scrolls, waits for the frame that builds the next items, and searches
  /// again, at most `max_steps` times (default 30). From the end of the
  /// list it goes on from the start, up to where it began.
  Future<Map<String, Object?>> scrollTo(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    await prepareToDrive();
    if (args['handle'] is String) {
      final target = element(args);
      await ensureVisible(target);
      await _frame();
      return {'widget': describe(target, _anchorOf(target), limits)};
    }
    final within = args['within'];
    final scrollable = within is String
        ? scrollableFor(element({'handle': within}))
        : mainScrollable();
    if (scrollable == null) {
      throw const AgentError('no scrollable list on screen');
    }
    final steps = args['max_steps'] is num
        ? (args['max_steps']! as num).round().clamp(1, 200)
        : 30;
    final start = scrollable.position.pixels;
    var wrapped = false;
    for (var step = 0; step < steps; step++) {
      cancel.check();
      if (!scrollable.mounted) throw const AgentError('the list went away');
      final found = matching(
        args,
        root: scrollable.context as Element,
        take: 1,
      );
      if (found.isNotEmpty) {
        final target = found.first;
        await ensureVisible(target);
        await _frame();
        return {
          'widget': describe(target, _anchorOf(target), limits),
          'steps': step,
        };
      }
      final position = scrollable.position;
      if (position.pixels >= position.maxScrollExtent - 0.5) {
        // The end: go on from the start, once.
        if (wrapped || start <= position.minScrollExtent + 0.5) break;
        wrapped = true;
        position.jumpTo(position.minScrollExtent);
      } else {
        // One screen on: with the cache extent, no item is skipped.
        position.jumpTo(
          math.min(
            position.pixels + position.viewportDimension,
            position.maxScrollExtent,
          ),
        );
        if (wrapped && position.pixels >= start) break;
      }
      // The frame that builds the newly shown items.
      await _frame();
    }
    throw AgentError('not found after $steps steps');
  }

  NoteAnchor? _anchorOf(Element element) =>
      sourceIndex().anchorsFor([element], root: contentRoot)[element];

  /// Pushes a route by path, as the platform would.
  Future<Map<String, Object?>> navigate(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw const AgentError('path is required, for example /settings');
    }
    await prepareToDrive();
    final handled = await pushRoute(path);
    await waitIdle(settleTimeout, cancel);
    return {
      'handled': handled,
      'route': currentRoute(),
      if (!handled) 'reason': 'no navigator or router took the route',
    };
  }

  /// Pops the current route, as the back button does.
  Future<Map<String, Object?>> back(AgentCancel cancel) async {
    await prepareToDrive();
    final handled = await popRoute();
    await waitIdle(settleTimeout, cancel);
    return {'handled': handled, 'route': currentRoute()};
  }

  /// The Milestone 4 payload for the handle's widget, without a
  /// screenshot.
  Map<String, Object?> inspect(Map<String, Object?> args) {
    final target = element(args);
    final pick = pickFor(target);
    final note = _collector.collect(
      pick,
      '',
      AnnotationIntent.improve,
      context: pageContext(),
      environment: controller.environment.toJson(),
    );
    return {
      'handle': args['handle'],
      if (args['detail'] case final String detail) 'detail': detail,
      'note': note.toJson(),
    };
  }

  /// Outlines the handle's widget for 1.5 seconds, so the user sees what
  /// the agent means.
  Map<String, Object?> flash(Map<String, Object?> args) {
    final target = element(args);
    final renderObject = renderObjectOf(target);
    if (renderObject == null) {
      throw const AgentError('the widget has no layout to show');
    }
    controller.agent.flashOn(renderObject);
    final rect = RenderSearch.globalRectOf(renderObject);
    return {
      'handle': args['handle'],
      if (rect != null) 'rect': rectList(rect),
      'visible': RenderSearch.visibleRectOf(renderObject) != null,
    };
  }

  /// A pick of [element] itself, as a pin or a finding makes one.
  PickResult pickFor(Element element) {
    final root = appKey.currentContext;
    if (root is! Element) throw const AgentError('the app is not on screen');
    final pick = PickResult.forElement(
      element,
      rootElement: root,
      chainBoundary: contentRoot,
      resolver: resolver(),
    );
    if (pick == null) {
      throw const AgentError('the widget is not laid out (off screen?)');
    }
    return pick;
  }

  /// A `RichText` that a `Text` built: the `Text` already stands for it.
  static bool _isTextTwin(Element element) {
    if (element.widget is! RichText) return false;
    var twin = false;
    var steps = 0;
    element.visitAncestorElements((ancestor) {
      twin = ancestor.widget is Text;
      return !twin && ++steps < 3;
    });
    return twin;
  }

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// The app's boundary render object. Throws when the app is not on
  /// screen.
  RenderObject get appRoot {
    final root = appKey.currentContext?.findRenderObject();
    if (root == null || !root.attached) {
      throw const AgentError('the app is not on screen');
    }
    return root;
  }

  /// The element directly above the app's own widgets.
  Element get contentRoot {
    final content = contentKey.currentContext;
    if (content is! Element || !content.mounted) {
      throw const AgentError('the app is not on screen');
    }
    return content;
  }

  /// Finds elements, sources and routes of the app's render objects.
  FindingLocator locator() =>
      FindingLocator(resolver: resolver(), boundary: contentRoot);

  /// The reverse lookup, for handles and anchors.
  SourceIndex sourceIndex() => SourceIndex(resolver: resolver());

  /// Route, URL, viewport, environment and a bounded outline of the local
  /// widgets on screen, each with a handle.
  Map<String, Object?> getScreen(OutputLimits limits) {
    final root = appRoot;
    final locator = this.locator();
    final seen = Set<Element>.identity();
    final shown = <Element>[];
    var total = 0;
    RenderSearch.visitVisible(root, (node, rect, visible) {
      final owner = locator.elementOf(node);
      if (owner == null) return;
      final local = locator.localEntryOf(owner);
      if (local == null || !seen.add(local.element)) return;
      total++;
      if (shown.length < limits.items) shown.add(local.element);
    });
    return {
      'route': currentRoute(),
      'url': kIsWeb ? limits.clip(Uri.base.toString()) : null,
      'viewport': _size(root.paintBounds.size),
      'environment': controller.environment.toJson(),
      'mode': controller.mode.name,
      'outline': describeAll(shown, limits),
      if (total > shown.length) 'more': total - shown.length,
    };
  }

  /// [elements] as the agent sees them, each with a new handle.
  List<Map<String, Object?>> describeAll(
    List<Element> elements,
    OutputLimits limits,
  ) {
    final anchors = sourceIndex().anchorsFor(elements, root: contentRoot);
    return [
      for (final element in elements)
        describe(element, anchors[element], limits),
    ];
  }

  /// One element as the agent sees it, with a new handle.
  Map<String, Object?> describe(
    Element element,
    NoteAnchor? anchor,
    OutputLimits limits,
  ) {
    final renderObject = renderObjectOf(element);
    final rect = renderObject == null
        ? null
        : RenderSearch.globalRectOf(renderObject);
    final text = textOf(element);
    var field = _soleEditableIn(element);
    var scrollable = _ownScrollable(element);
    if (field != null && scrollable != null) {
      // A field has its own horizontal scrollable; a list can hold one
      // field. Whichever is outside the other is what this widget is.
      final inField = identical(
        scrollable.context.findAncestorStateOfType<EditableTextState>(),
        field,
      );
      if (inField) {
        scrollable = null;
      } else {
        field = null;
      }
    }
    return {
      'handle': handles.add(element, anchor),
      'widget': element.widget.runtimeType.toString(),
      'source': ?_where(anchor),
      'key': ?element.widget.key?.toString(),
      'rect': ?(rect == null ? null : rectList(rect)),
      'visible':
          renderObject != null &&
          RenderSearch.visibleRectOf(renderObject) != null,
      if (text != null) 'text': limits.clip(text),
      // A field's value and a list's position, so the agent needs no
      // get_state call to read them.
      if (field != null && text == null)
        'value': field.widget.obscureText
            ? '[masked]'
            : limits.clip(field.textEditingValue.text),
      if (scrollable != null && scrollable.position.hasPixels)
        'scroll': _scrollState(scrollable.position),
    };
  }

  /// The one text field at or close under [element] (a `TextField`,
  /// a `TextFormField`), or null when there is none or more than one (a
  /// form).
  static EditableTextState? _soleEditableIn(Element element) {
    EditableTextState? found;
    var count = 0;
    var visited = 0;
    void visit(Element e) {
      if (count > 1 || ++visited > 200) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        count++;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return count == 1 ? found : null;
  }

  /// The scrollable at or close under [element] (a list's own), or null.
  static ScrollableState? _ownScrollable(Element element) {
    ScrollableState? found;
    var visited = 0;
    void visit(Element e) {
      if (found != null || ++visited > 50) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        found = e.state as ScrollableState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }

  /// The route on top: the route of what is at the center of the app.
  String? currentRoute() {
    final root = appRoot;
    final rect = RenderSearch.globalRectOf(root);
    if (rect == null) return null;
    final hits = RenderSearch.find(root, rect.center).candidates;
    final locator = this.locator();
    for (final hit in hits) {
      final owner = locator.elementOf(hit.renderObject);
      if (owner is RenderObjectElement) {
        return ContextCollector.routeNameOf(owner);
      }
    }
    return null;
  }

  /// The render object of [element]: its own, or the nearest below.
  static RenderObject? renderObjectOf(Element element) {
    try {
      final renderObject = element.renderObject;
      return renderObject != null && renderObject.attached
          ? renderObject
          : null;
    } catch (_) {
      return null;
    }
  }

  /// The text [element] shows, when it is a text widget. Text from a field
  /// with `obscureText` is masked (engineering rule 9).
  static String? textOf(Element element) {
    final widget = element.widget;
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText();
    }
    if (widget is RichText) return widget.text.toPlainText();
    if (widget is EditableText) {
      return widget.obscureText ? '[masked]' : widget.controller.text;
    }
    return null;
  }

  /// `[x, y, w, h]` to one decimal.
  static List<num> rectList(Rect rect) => [
    _round(rect.left),
    _round(rect.top),
    _round(rect.width),
    _round(rect.height),
  ];

  static Map<String, num> _size(Size size) => {
    'width': _round(size.width),
    'height': _round(size.height),
  };

  static num _round(double value) {
    final r = (value * 10).roundToDouble() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }

  static String? _where(NoteAnchor? anchor) {
    final file = anchor?.file;
    final line = anchor?.line;
    return file == null || line == null ? null : '$file:$line';
  }
}
