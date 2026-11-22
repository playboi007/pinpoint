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
import '../model/json_read.dart';
import '../model/tape.dart';
import '../overlay/replay_blocker.dart';
import '../search/pick_result.dart';
import '../search/render_search.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';
import '../sink/bridge_client.dart';
import '../sink/http_sink.dart' show HttpSinkException;
import '../state/build_stacks.dart' show BuildStacks;
import '../state/state_lens.dart';
import '../tape/browser_page.dart';
import '../tape/net_matcher.dart';
import '../tape/tape_boot.dart';
import '../tape/tape_player.dart';
import '../tape/tape_recorder.dart' show TapeSince;
import '../trace/cause_zone.dart';
import '../trace/note_trace.dart';
import '../trace/story.dart' show StoryFilter;
import '../trace/trace_causes.dart';
import '../trace/trace_format.dart';
import '../trace/trace_session.dart';
import '../trace/watch.dart';
import 'agent_control.dart';
import 'checks.dart';
import 'state_dump.dart';
import 'stress_matrix.dart';
import 'synthetic_input.dart';

part 'commands_trace.dart';
part 'commands_replay.dart';
part 'commands_steps.dart';
part 'commands_verify.dart';
part 'commands_drive.dart';
part 'commands_view.dart';
part 'commands_stress.dart';
part 'commands_find.dart';
part 'commands_input.dart';
part 'commands_screen.dart';

/// A command failed for a reason the agent should read, for example
/// `stale handle h3`.
class AgentError implements Exception {
  const AgentError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A step that cannot run yet but may soon: its widget is not built, not
/// laid out or not on screen. Thrown only before the tool changes
/// anything, so the step can be tried again.
class AgentNotReady extends AgentError {
  const AgentNotReady(super.message);
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

  /// Forgets the handles [ids].
  void forget(Iterable<String> ids) => ids.forEach(_handles.remove);

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
    this.bridge,
  });

  /// The bridge, for tapes (PLAN-v2 Milestone 15); null without one.
  final BridgeClient? Function()? bridge;

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
  ///
  /// A step that is not ready ([AgentNotReady]) is tried again by
  /// [_againSoon]. One that is ready runs at once: nothing waits for an
  /// app that has nothing left to do.
  ///
  /// Each command is a cause of its own (PLAN-v2 Milestone 14): what the
  /// agent's tap starts names the agent, not the long poll that brought
  /// it.
  Future<Map<String, Object?>> run(
    String tool,
    Map<String, Object?> args,
    AgentCancel cancel,
  ) => CauseZone.enter(CauseKind.agent, () => _run(tool, args, cancel));

  Future<Map<String, Object?>> _run(
    String tool,
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final limits = OutputLimits.from(args);
    final ms = args['wait_ms'];
    final extra = Duration(
      milliseconds: ms is num ? ms.round().clamp(0, maxWaitMs) : 0,
    );
    final watch = Stopwatch()..start();
    while (true) {
      try {
        return AgentControl.ok(
          await _dispatch(tool, withTarget(args), limits, cancel),
        );
      } on AgentNotReady catch (failure) {
        if (!await _againSoon(watch.elapsed, extra, cancel)) {
          return AgentControl.error(failure.message);
        }
      } on AgentError catch (failure) {
        return AgentControl.error(failure.message);
      }
    }
  }

  /// The longest `wait_ms` a step may ask for.
  static const int maxWaitMs = 10000;

  /// Whether a step that was not ready gets another try, after a wait.
  ///
  /// While the app draws frames, something is still coming in (a route, a
  /// sheet, a list item): the wait is one frame, up to [AgentVerify.settleTimeout]. An
  /// app that draws nothing does not change by itself, so the step fails
  /// at once, unless `wait_ms` ([extra]) asks to wait for content that
  /// loads over the network; then it tries every 50 ms.
  Future<bool> _againSoon(
    Duration elapsed,
    Duration extra,
    AgentCancel cancel,
  ) async {
    final moving = appIsMoving;
    final limit = moving && extra < AgentVerify.settleTimeout
        ? AgentVerify.settleTimeout
        : extra;
    if (elapsed >= limit) return false;
    await (moving
        ? _nextFrame()
        : Future<void>.delayed(const Duration(milliseconds: 50)));
    cancel.check();
    return true;
  }

  /// Whether the app draws frames now: a frame is scheduled or running, or
  /// an animation ticks.
  static bool get appIsMoving {
    final scheduler = SchedulerBinding.instance;
    return scheduler.hasScheduledFrame ||
        scheduler.schedulerPhase != SchedulerPhase.idle ||
        scheduler.transientCallbackCount > 0;
  }

  /// The next frame, or 100 ms: a hidden tab draws none.
  static Future<void> _nextFrame() => Future.any([
    AgentDrive._frame(),
    Future<void>.delayed(const Duration(milliseconds: 100)),
  ]);

  Future<Object> _dispatch(
    String tool,
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    return switch (tool) {
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
      'get_trace' => getTrace(args),
      'trace_detail' => traceDetail(args),
      'watch' => watch(args),
      'unwatch' => unwatch(args),
      'mark' => mark(args),
      'save_tape' => await saveTape(args),
      'replay' => await replay(args, cancel),
      'resume_replay' => await resumeReplay(cancel),
      'stop_replay' => await stopReplay(),
      'why' => why(args),
      'caused_by' => causedBy(args),
      'state_flow' => stateFlow(args),
      _ => throw AgentError('unknown tool: $tool'),
    };
  }

  /// Drops every handle: after a hot reload lines have moved, and a
  /// handle must never land on another widget.
  void reassemble() => handles.clear();

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
}
