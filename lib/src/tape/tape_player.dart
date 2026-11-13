import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../agent/synthetic_input.dart';
import '../model/annotation.dart' show NoteAnchor;
import '../model/tape.dart';
import '../model/trace_event.dart';
import '../overlay/replay_blocker.dart';
import '../search/render_search.dart';
import '../trace/sources/network_source.dart';
import '../trace/trace_session.dart';
import 'net_matcher.dart';
import 'tape_boot.dart';

/// What the player needs from the app it replays into. The overlay's agent
/// commands make one.
class ReplayHost {
  const ReplayHost({
    required this.session,
    required this.resolve,
    required this.widgetAt,
    required this.prepare,
    required this.postMessage,
    this.isOnApp,
  });

  final TraceSession session;

  /// The element [anchor] names now, or null.
  final Element? Function(NoteAnchor anchor) resolve;

  /// The type of the local widget under [position], or null.
  final String? Function(Offset position) widgetAt;

  /// Gets the app ready for synthetic input: leaves picking mode, whose
  /// pointer trap would take the player's events (watch out for).
  final Future<void> Function() prepare;

  /// Sends a `message` event to the page (web).
  final void Function(String data, String origin) postMessage;

  /// Whether [position] is over the app (not outside a what-if viewport).
  final bool Function(Offset position)? isOnApp;

  NetworkSource? get network {
    final source = session.source('network');
    return source is NetworkSource ? source : null;
  }
}

/// Where a replay holds (step 15).
class ReplayUntil {
  const ReplayUntil._({this.mark, this.step});

  /// `mark` (the last of the tape), `mark:N` (from 1) or `step:N`. Throws
  /// a [FormatException] for anything else, or a mark the tape lacks.
  factory ReplayUntil.parse(Object? value, Tape tape) {
    if (value is String) {
      if (value == 'mark' || value.startsWith('mark:')) {
        final n = value == 'mark'
            ? tape.marks.length
            : int.tryParse(value.substring(5)) ?? 0;
        if (n < 1 || n > tape.marks.length) {
          throw FormatException(
            'the tape has ${tape.marks.length} marks; $value is not one',
          );
        }
        return ReplayUntil._(mark: tape.marks[n - 1]);
      }
      if (value.startsWith('step:')) {
        final n = int.tryParse(value.substring(5));
        if (n != null && n >= 0) return ReplayUntil._(step: n);
      }
    }
    throw FormatException('until is "mark", "mark:N" or "step:N"; got $value');
  }

  final TapeMark? mark;
  final int? step;

  /// Whether the replay holds before [input].
  bool before(TapeInput input) =>
      (mark != null && input.seq > mark!.seq) ||
      (step != null && input.step > step!);

  @override
  String toString() => mark != null ? 'mark at seq ${mark!.seq}' : 'step $step';
}

/// A time limit kept by a timer, not a stopwatch: a timer follows a
/// test's fake clock, so a wait ends there as in the app.
class _Deadline {
  _Deadline(Duration limit) {
    _timer = Timer(limit, () => passed = true);
  }

  late final Timer _timer;
  bool passed = false;

  void cancel() => _timer.cancel();
}

/// Where a replay is.
enum ReplayState { running, held, done, stopped, diverged }

/// The replay ran into something it cannot go past.
class _Diverged implements Exception {
  _Diverged(this.reason);

  final String reason;
}

/// Plays a tape's inputs into the running app (PLAN-v2 Milestone 15,
/// steps 8 to 15) while the network source answers from it.
///
/// Inputs go by **logical order**, not by the clock (step 10). Each input
/// waits for three things: its recorded delay divided by [speed]; every
/// answer in its `after` to be delivered again; and its target to be ready
/// (built, laid out, on screen). A slow machine or a changed layout then
/// does not break the tape.
///
/// It forces frames only through the input it sends (the exception rule 15
/// allows), blocks real pointer input, shows a banner, stops on Esc, and
/// restores the network source and the input when it ends.
class TapePlayer {
  TapePlayer({
    required this.tape,
    required this.host,
    this.speed = 1,
    this.until,
    this.unmatched = Unmatched.fail,
    this.latency = const ReplayLatency.recorded(),
    String? runId,
    NetReplay? net,
    List<String> notes = const <String>[],
  }) : assert(speed > 0),
       runId = runId ?? newRunId(),
       _givenNet = net {
    _notes.addAll(notes);
  }

  final NetReplay? _givenNet;

  /// The network replay a restarted page installed before the app made
  /// its first request, and the session it is installed in. The player of
  /// that start takes it over.
  static NetReplay? bootNet;

  /// Called by the wrapper when its recorder starts. On a page a replay
  /// restarted, answers requests from the tape from now on: when
  /// `PinPoint.run` loaded it before `runApp`, from the app's first
  /// request; otherwise from when it arrives, and the requests before that
  /// were real.
  static void bootNetwork(TraceSession session, {required bool storage}) {
    final flag = TapeBoot.flag;
    if (flag == null || TapeBoot.started) return;
    session.tapes.replaying = true;
    ReplayGate.show('Replaying tape: loading it');
    void install(Tape tape) {
      final network = session.source('network');
      final options = flag.options;
      final net = bootNet = NetReplay(
        tape,
        matcher: session.tapes.matcher,
        unmatched:
            Unmatched.byName(options['unmatched'] ?? 'fail') ?? Unmatched.fail,
        latency:
            ReplayLatency.parse(options['latency']) ??
            const ReplayLatency.recorded(),
        speed: options['speed'] is num
            ? (options['speed']! as num).toDouble()
            : 1,
      );
      if (network is NetworkSource) network.replay = net;
    }

    final tape = TapeBoot.tape;
    if (tape != null) {
      install(tape);
      return;
    }
    debugPrint(
      'pinpoint: replay without PinPoint.run in main: requests made before '
      'the tape loaded reach the server.',
    );
    unawaited(
      TapeBoot.load(restoreStorage: storage).then((tape) {
        if (tape != null) install(tape);
      }),
    );
  }

  /// The replay running or holding now, or null. A static (api-notes item
  /// 29): Esc finds it from the wrapper.
  static TapePlayer? current;

  /// Ends any replay at once and clears the gate, for tests.
  @visibleForTesting
  static void debugReset() {
    current?._stopRequested = true;
    current?._resume?.complete();
    current = null;
    ReplayGate.clear();
  }

  final Tape tape;
  final ReplayHost host;
  final double speed;
  final ReplayUntil? until;
  final Unmatched unmatched;
  final ReplayLatency latency;
  final String runId;

  /// The longest wait between two inputs, whatever the tape says: a user
  /// who paused ten minutes need not be replayed so.
  static const Duration maxGap = Duration(seconds: 5);

  /// How long an input waits for its target.
  static const Duration readyTimeout = Duration(seconds: 2);

  /// How long an input waits for the answers it needs.
  static const Duration answerTimeout = Duration(seconds: 10);

  ReplayState _state = ReplayState.running;
  ReplayState get state => _state;

  late final NetReplay net;
  late final int startSeq;
  int _done = 0;
  bool _stopRequested = false;
  String? _stopReason;
  bool _heldOnce = false;
  Map<String, Object?>? _firstDifference;
  final List<String> _notes = <String>[];
  Completer<void>? _resume;
  Completer<Map<String, Object?>>? _settled;
  final Completer<void> _stopSignal = Completer<void>();

  /// Synthetic pointers down, by the recorded pointer id: their id and
  /// the offset from the recorded position.
  final Map<int, (int, Offset, PointerDeviceKind)> _pointers =
      <int, (int, Offset, PointerDeviceKind)>{};
  final Set<int> _addedDevices = <int>{};

  /// The last recorded position of each pointer down.
  final Map<int, Offset> _lastAt = <int, Offset>{};
  static int _nextDevice = 0;

  /// Inputs done.
  int get step => _done;

  /// Inputs in the tape.
  int get total => tape.inputs.length;

  /// The first difference from the tape, or null (step 13).
  Map<String, Object?>? get firstDifference => _firstDifference;

  /// Starts the replay. Completes when it holds or ends, with [result].
  Future<Map<String, Object?>> start() async {
    if (current != null) {
      throw StateError('a replay runs already (${current!.runId})');
    }
    current = this;
    final session = host.session;
    net =
        _givenNet ??
        NetReplay(
          tape,
          matcher: session.tapes.matcher,
          unmatched: unmatched,
          latency: latency,
          speed: speed,
        );
    host.network?.replay = net;
    session.tapes.replaying = true;
    _banner();
    startSeq = session.recorder
        .add(
          TraceKind.replayStart,
          data: {
            'tape': tape.id,
            'kind': tape.kind.name,
            'run': runId,
            'inputs': total,
            'speed': speed,
            'unmatched': unmatched.name,
            if (until != null) 'until': '$until',
          },
        )
        .seq;
    final settled = _settled = Completer<Map<String, Object?>>();
    try {
      await host.prepare();
    } catch (error) {
      _end(ReplayState.stopped, reason: '$error');
      return settled.future;
    }
    unawaited(_run());
    return settled.future;
  }

  /// Goes on after a hold. Completes at the next hold or the end.
  Future<Map<String, Object?>> resume() {
    final resume = _resume;
    if (_state != ReplayState.held || resume == null) {
      throw StateError('the replay does not hold');
    }
    _state = ReplayState.running;
    _banner();
    final settled = _settled = Completer<Map<String, Object?>>();
    resume.complete();
    return settled.future;
  }

  /// Ends the replay at the next chance: now when it holds, else after the
  /// input being sent.
  void stop({String reason = 'stopped'}) {
    if (_stopRequested) return;
    _stopRequested = true;
    _stopReason = reason;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    if (_state == ReplayState.held) {
      _settled = Completer<Map<String, Object?>>();
      _resume?.complete();
    }
  }

  /// A future that completes when the replay ends (not at a hold).
  Future<Map<String, Object?>> get ended => _ended.future;
  final Completer<Map<String, Object?>> _ended =
      Completer<Map<String, Object?>>();

  Future<void> _run() async {
    var previousT = tape.start.t;
    try {
      for (final input in tape.inputs) {
        if (_stopRequested) break;
        if (!_heldOnce && until != null && until!.before(input)) {
          await _hold();
          if (_stopRequested) break;
        }
        final gap = Duration(
          milliseconds: ((input.t - previousT) / speed).round(),
        );
        previousT = input.t;
        await _sleep(gap > maxGap ? maxGap : gap);
        if (_stopRequested) break;
        if (input.after.isNotEmpty &&
            !await net.waitFor(input.after, timeout: answerTimeout)) {
          _differ(
            input.step,
            'answer',
            [
              for (final n in input.after)
                if (!net.wasDelivered(n)) n,
            ].join(', '),
            'not delivered',
          );
        }
        if (_stopRequested) break;
        await _send(input);
        _done = input.step;
        host.session.recorder.add(
          TraceKind.replayStep,
          data: {
            'step': input.step,
            'of': total,
            'input': input.kind.substring('input.'.length),
            if (input.data['phase'] case final String phase) 'phase': phase,
          },
        );
        _banner();
        _compare(input.step);
      }
      if (!_stopRequested && !_heldOnce && until != null) {
        // The mark is after the last input: hold at the end.
        await _hold();
      }
      if (_stopRequested) {
        _end(ReplayState.stopped, reason: _stopReason);
        return;
      }
      await _settle();
      _compare(null);
      _end(ReplayState.done);
    } on _Diverged catch (diverged) {
      _end(ReplayState.diverged, reason: diverged.reason);
    } catch (error) {
      _end(ReplayState.stopped, reason: 'the player failed: $error');
    }
  }

  Future<void> _hold() async {
    _heldOnce = true;
    _state = ReplayState.held;
    final resume = _resume = Completer<void>();
    host.session.recorder.add(
      TraceKind.replayHold,
      data: {'step': _done, 'of': total, 'at': '$until'},
    );
    _banner();
    // Real input stays blocked: the app is in the state of that moment,
    // for picking, a state dump and a screenshot.
    _settled?.complete(result);
    await resume.future;
    _resume = null;
  }

  Future<void> _sleep(Duration duration) async {
    if (duration <= Duration.zero) return;
    await Future.any([Future<void>.delayed(duration), _stopSignal.future]);
  }

  /// Waits until the app stops drawing, at most 1 s, and once more for the
  /// route source's late read (500 ms after a tap).
  Future<void> _settle() async {
    final deadline = _Deadline(const Duration(seconds: 1));
    while (_moving && !deadline.passed) {
      await _tick();
    }
    deadline.cancel();
    await _sleep(const Duration(milliseconds: 600));
  }

  static bool get _moving {
    final scheduler = SchedulerBinding.instance;
    return scheduler.hasScheduledFrame ||
        scheduler.schedulerPhase != SchedulerPhase.idle ||
        scheduler.transientCallbackCount > 0;
  }

  /// The next frame while the app draws, else 50 ms.
  Future<void> _tick() => _moving
      ? Future.any([
          SchedulerBinding.instance.endOfFrame,
          Future<void>.delayed(const Duration(milliseconds: 100)),
        ])
      : Future<void>.delayed(const Duration(milliseconds: 50));

  // ---- inputs ----

  Future<void> _send(TapeInput input) async {
    switch (input.kind) {
      case TraceKind.pointer:
        await _pointer(input);
      case TraceKind.text:
        await _text(input);
      case TraceKind.message:
        final data = input.data['data'];
        final origin = input.data['origin'];
        if (data is String && origin is String) {
          // The recorded data is masked and clipped (rule 16): a masked
          // key arrives as "***".
          host.postMessage(data, origin);
        }
      default:
        // Keys: the text they made replays as input.text, and a tap on a
        // button as input.pointer. Key events alone (shortcuts, Tab) are
        // not sent; the count is in the result.
        _note('keys are not replayed');
    }
  }

  void _note(String note) {
    if (_notes.length < 10 && !_notes.contains(note)) _notes.add(note);
  }

  Future<void> _pointer(TapeInput input) async {
    final data = input.data;
    final phase = data['phase'];
    final recordedId = data['pointer'] is int ? data['pointer']! as int : 0;
    final recorded = Offset(_num(data['x']), _num(data['y']));
    _lastAt[recordedId] = recorded;
    switch (phase) {
      case 'down':
        final position = await _downPosition(input, recorded);
        final kind = _kind(data['device']);
        final id = _device(kind, position);
        _pointers[recordedId] = (id, position - recorded, kind);
        SyntheticInput.send(
          PointerDownEvent(
            viewId: _viewId,
            timeStamp: SyntheticInput.stamp(),
            pointer: id,
            device: id,
            kind: kind,
            position: position,
          ),
        );
      case 'move':
        final down = _pointers[recordedId];
        if (down == null) return;
        final (id, offset, kind) = down;
        SyntheticInput.send(
          PointerMoveEvent(
            viewId: _viewId,
            timeStamp: SyntheticInput.stamp(),
            pointer: id,
            device: id,
            kind: kind,
            position: recorded + offset,
          ),
        );
      case 'up' || 'cancel':
        final down = _pointers.remove(recordedId);
        if (down == null) return;
        final (id, offset, kind) = down;
        final position = recorded + offset;
        SyntheticInput.send(
          phase == 'up'
              ? PointerUpEvent(
                  viewId: _viewId,
                  timeStamp: SyntheticInput.stamp(),
                  pointer: id,
                  device: id,
                  kind: kind,
                  position: position,
                )
              : PointerCancelEvent(
                  viewId: _viewId,
                  timeStamp: SyntheticInput.stamp(),
                  pointer: id,
                  device: id,
                  kind: kind,
                  position: position,
                ),
        );
      case 'scroll':
        // Watch out for: a list restores nothing after a restart, so a
        // scroll replays as the signal that made it, never as an offset.
        // A drag replays as its down, moves and up.
        final id = _device(PointerDeviceKind.mouse, recorded);
        SyntheticInput.send(
          PointerScrollEvent(
            viewId: _viewId,
            timeStamp: SyntheticInput.stamp(),
            device: id,
            kind: PointerDeviceKind.mouse,
            position: recorded,
            scrollDelta: Offset(_num(data['dx']), _num(data['dy'])),
          ),
        );
    }
  }

  int get _viewId =>
      WidgetsBinding.instance.platformDispatcher.implicitView?.viewId ?? 0;

  /// A synthetic device for one pointer of the tape, added once. Ids are
  /// at or above [SyntheticInput.deviceBase], so the pointer source tags
  /// them `agent` and no new tape records them (watch out for).
  int _device(PointerDeviceKind kind, Offset position) {
    final id = SyntheticInput.deviceBase + 0x100 + (_nextDevice++ % 0xFF);
    if (_addedDevices.add(id)) {
      // Hover is not recorded (only moves while down), so no hover
      // replays; a mouse-kind pointer still needs its added event.
      SyntheticInput.send(
        PointerAddedEvent(
          viewId: _viewId,
          timeStamp: SyntheticInput.stamp(),
          device: id,
          kind: kind,
          position: position,
        ),
      );
    }
    return id;
  }

  static PointerDeviceKind _kind(Object? name) {
    for (final kind in PointerDeviceKind.values) {
      if (kind.name == name) return kind;
    }
    return PointerDeviceKind.touch;
  }

  static double _num(Object? value) => value is num ? value.toDouble() : 0;

  /// Where a down lands now (step 11): its anchor resolved to the widget
  /// now, at the stored fraction. Without an anchor, the recorded spot.
  /// When the anchor does not resolve, the recorded spot only when a widget
  /// of the same type is there; otherwise the replay diverges.
  Future<Offset> _downPosition(TapeInput input, Offset recorded) async {
    final anchorJson = input.data['anchor'];
    if (anchorJson is! Map<String, Object?>) return recorded;
    final NoteAnchor anchor;
    try {
      anchor = NoteAnchor.fromJson(anchorJson);
    } catch (_) {
      return recorded;
    }
    final deadline = _Deadline(readyTimeout);
    while (true) {
      final element = host.resolve(anchor);
      final renderObject = element?.findRenderObject();
      if (renderObject != null && renderObject.attached) {
        final rect = RenderSearch.globalRectOf(renderObject);
        final visible = RenderSearch.visibleRectOf(renderObject);
        if (rect != null &&
            visible != null &&
            visible.width > 0 &&
            visible.height > 0) {
          final fx = input.data['fx'];
          final fy = input.data['fy'];
          var point = fx is num && fy is num
              ? rect.topLeft + Offset(fx * rect.width, fy * rect.height)
              : visible.center;
          if (!visible.contains(point)) point = visible.center;
          if (host.isOnApp?.call(point) ?? true) {
            deadline.cancel();
            return point;
          }
        }
      }
      if (_stopRequested) {
        deadline.cancel();
        throw _Diverged('stopped');
      }
      if (deadline.passed) break;
      await _tick();
    }
    final there = host.widgetAt(recorded);
    if (there != null && there == input.widget) {
      _differ(
        input.step,
        'anchor',
        input.widget,
        'not found; tapped the '
            'recorded spot, where a ${input.widget} is',
      );
      return recorded;
    }
    final reason =
        'step ${input.step}: ${input.widget ?? 'the widget'} '
        '(${anchor.file?.split('/').last}:${anchor.line}) is not on screen, '
        'and ${there ?? 'nothing local'} is at the recorded spot';
    _differ(input.step, 'anchor', input.widget, there ?? 'nothing');
    host.session.recorder.add(
      TraceKind.replayDiverged,
      data: {
        'step': input.step,
        'widget': ?input.widget,
        'anchor': '${anchor.file?.split('/').last}:${anchor.line}',
        'found': ?there,
      },
    );
    throw _Diverged(reason);
  }

  /// Text replays into the focused field through
  /// `userUpdateTextEditingValue` (Milestone 12, step 5), so the app's
  /// formatters and `onChanged` run as for the user.
  Future<void> _text(TapeInput input) async {
    final value = input.data['value'];
    if (value is! String) return;
    if (value == '[masked]') {
      _note('a masked field (obscureText) is not replayed');
      _differ(input.step, 'text', 'masked value', 'not kept in the tape');
      return;
    }
    final length = input.data['length'];
    if (length is int && length > value.length) {
      _note('a long text was clipped to ${value.length} characters');
    }
    final deadline = _Deadline(readyTimeout);
    while (true) {
      final context = FocusManager.instance.primaryFocus?.context;
      // Not `.of`: nothing here may subscribe an element (rule 3).
      final field = context?.findAncestorStateOfType<EditableTextState>();
      if (field != null && field.mounted) {
        field.userUpdateTextEditingValue(
          TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
          ),
          SelectionChangedCause.keyboard,
        );
        deadline.cancel();
        return;
      }
      if (_stopRequested || deadline.passed) break;
      await _tick();
    }
    deadline.cancel();
    if (_stopRequested) return;
    host.session.recorder.add(
      TraceKind.replayDiverged,
      data: {'step': input.step, 'widget': ?input.widget, 'found': 'no focus'},
    );
    _differ(input.step, 'text', input.widget ?? 'a text field', 'no focus');
    throw _Diverged('step ${input.step}: no text field has focus');
  }

  // ---- differences (step 13) ----

  void _differ(Object step, String what, Object? expected, Object? got) {
    _firstDifference ??= {
      'step': step,
      'what': what,
      'expected': expected,
      'got': got,
    };
  }

  /// The routes shown since the replay started.
  List<String> get _routes => [
    for (final e in host.session.recorder.events)
      if (e.seq > startSeq &&
          e.kind == TraceKind.route &&
          e.data['to'] is String)
        e.data['to']! as String,
  ];

  /// Compares the route order and the request keys with the tape. [step]
  /// null: the end, where fewer than the tape is a difference too.
  void _compare(int? step) {
    if (_firstDifference != null) return;
    final at = step ?? 'end';
    for (final (what, expected, got) in [
      ('route', tape.routes, _routes),
      ('request', [for (final e in tape.net) e.key], net.asked),
    ]) {
      for (var i = 0; i < got.length; i++) {
        if (i >= expected.length) {
          return _differ(at, what, null, got[i]);
        }
        if (got[i] != expected[i]) {
          return _differ(at, what, expected[i], got[i]);
        }
      }
      // Fewer than the tape: a difference, not an error; seen at the end.
      if (step == null && got.length < expected.length) {
        return _differ(at, what, expected[got.length], null);
      }
    }
  }

  // ---- end ----

  void _banner() {
    final text = switch (_state) {
      ReplayState.held => 'Replay holds at step $_done of $total',
      _ => 'Replaying tape, step $_done of $total',
    };
    ReplayGate.show(text);
  }

  /// Where the replay is, for the tools.
  Map<String, Object?> get result => {
    'run': runId,
    'tape': tape.id,
    'kind': tape.kind.name,
    'state': _state.name,
    'step': _done,
    'of': total,
    if (_state == ReplayState.held) 'held_at': '$until',
    'first_difference': _firstDifference,
    if (_stopReason != null) 'reason': _stopReason,
    'requests': {'tape': tape.net.length, 'asked': net.asked.length},
    if (net.unmatchedRequests.isNotEmpty)
      'unmatched': net.unmatchedRequests.take(10).toList(),
    if (_notes.isNotEmpty) 'notes': _notes,
    // Rule 19: a partial tape gives a partial replay.
    if (tape.partial) 'partial': tape.partialReason ?? true,
  };

  void _end(ReplayState state, {String? reason}) {
    if (!identical(current, this)) return;
    _state = state;
    _stopReason ??= reason;
    // Pointers still down are cancelled, so no gesture is left half done.
    for (final MapEntry(key: recordedId, value: (id, offset, kind))
        in _pointers.entries) {
      SyntheticInput.send(
        PointerCancelEvent(
          viewId: _viewId,
          timeStamp: SyntheticInput.stamp(),
          pointer: id,
          device: id,
          kind: kind,
          position: (_lastAt[recordedId] ?? Offset.zero) + offset,
        ),
      );
    }
    _pointers.clear();
    _lastAt.clear();
    for (final id in _addedDevices) {
      SyntheticInput.send(
        PointerRemovedEvent(
          viewId: _viewId,
          timeStamp: SyntheticInput.stamp(),
          device: id,
        ),
      );
    }
    _addedDevices.clear();
    // Restore everything the replay changed (rule 15): the network, the
    // tape store, the input gate and the banner.
    host.network?.replay = null;
    net.close();
    if (identical(bootNet, net)) bootNet = null;
    host.session.tapes.replaying = false;
    ReplayGate.clear();
    host.session.recorder.add(
      TraceKind.replayEnd,
      data: {
        'run': runId,
        'state': state.name,
        'step': _done,
        'of': total,
        'reason': ?_stopReason,
        'first_difference': ?_firstDifference,
      },
    );
    current = null;
    final answer = result;
    final settled = _settled;
    if (settled != null && !settled.isCompleted) settled.complete(answer);
    if (!_ended.isCompleted) _ended.complete(answer);
  }
}
