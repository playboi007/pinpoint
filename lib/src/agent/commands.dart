import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../capture/context_collector.dart';
import '../capture/screenshot.dart';
import '../core/pinpoint_controller.dart';
import '../detect/detector.dart';
import '../env/environment_controller.dart';
import '../model/annotation.dart';
import '../search/pick_result.dart';
import '../search/render_search.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';
import 'agent_control.dart';
import 'checks.dart';

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
/// Handles hold elements, which die on rebuild (watch out for). Each one
/// lives [lifetime]; on use it is checked, re-resolved from its anchor
/// when its element is gone, and refused as stale when that fails, never
/// acted on as another widget.
class HandleTable {
  HandleTable({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// How long a handle can be used.
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
    if (_clock().difference(handle.created) > lifetime) {
      _handles.remove(id);
      throw AgentError(
        'stale handle $id (older than ${lifetime.inSeconds} s); find the '
        'widget again',
      );
    }
    final anchor = handle.anchor;
    final element = handle.element;
    // Exact, not the nearest line: within one run a widget does not move,
    // so a widget on another line is another widget. After a hot reload
    // the handles are dropped (AgentCommands.reassemble).
    if (element.mounted &&
        (anchor == null ||
            !anchor.resolvable ||
            index.matchesExactly(element, anchor))) {
      return element;
    }
    if (anchor != null && anchor.resolvable) {
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
  });

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
      final Object result = switch (tool) {
        'verify_note' => await verifyNote(args, cancel),
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

  /// How long a command waits for the app to settle after a change.
  static const Duration settleTimeout = Duration(seconds: 3);

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
      root: contentRoot,
      file: file,
      line: line as int?,
      type: type,
      where: text == null && key == null
          ? null
          : (element) {
              if (key != null &&
                  !(element.widget.key?.toString().contains(key) ?? false)) {
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

    final ordered = [
      ...matches.where(visible),
      ...matches.where((e) => !visible(e)),
    ];
    final shown = ordered.take(limits.items).toList();
    return {
      'widgets': describeAll(shown, limits),
      if (ordered.length > shown.length) 'more': ordered.length - shown.length,
    };
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
    };
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
