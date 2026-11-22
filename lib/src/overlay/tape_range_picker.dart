import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pinpoint_controller.dart';
import '../model/trace_event.dart';
import '../tape/tape_recorder.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';

/// Which part of the run the attached tape holds: a range slider over what
/// the tape recorder has, under "Attach what happened".
///
/// The track shows the run: taps as tall ticks, typing as short ones,
/// requests as dots under the line, route changes as labels above it and
/// marks as flags. Two handles choose the range; the start snaps to a mark
/// or a route change. While a handle moves, it grows, a time label rises
/// over it and the chosen band's hatching moves. Nothing moves at rest: a
/// constant animation would fill the trace with frames.
///
/// The choice lives in [CommentDraft.tapeFrom] and [CommentDraft.tapeTo]
/// (recorder ms). A start at the earliest time is app start, so the tape
/// can be full; an end at the right edge is "now", whenever the note goes.
class TapeRangePicker extends StatefulWidget {
  const TapeRangePicker({
    super.key,
    required this.draft,
    required this.tapes,
    this.enabled = true,
    this.clock = DateTime.now,
  });

  final CommentDraft draft;
  final TapeRecorder tapes;
  final bool enabled;

  /// The wall clock, for the labels' times. Replaceable in tests.
  final DateTime Function() clock;

  static const Key trackKey = ValueKey<String>('pinpoint.tapeRange.track');
  static const Key fromLabelKey = ValueKey<String>('pinpoint.tapeRange.from');
  static const Key toLabelKey = ValueKey<String>('pinpoint.tapeRange.to');
  static const Key lengthKey = ValueKey<String>('pinpoint.tapeRange.length');
  static const Key summaryKey = ValueKey<String>('pinpoint.tapeRange.summary');

  /// The preset chip [name]: `all`, `30s`, `2m` or `mark`.
  static Key presetKey(String name) =>
      ValueKey<String>('pinpoint.tapeRange.preset.$name');

  /// The track's height; the handles' grips sit at its bottom.
  static const double trackHeight = 66;

  /// The shortest range, in ms.
  static const int minRange = 500;

  /// How near (px) a handle must come to a mark or route change to snap.
  static const double snapDistance = 8;

  /// `1:05`, `12:30`, `1:02:03`.
  static String length(int ms) {
    final s = (ms / 1000).round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$r' : '$m:$r';
  }

  /// `14:02:31`.
  static String clockTime(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  @override
  State<TapeRangePicker> createState() => _TapeRangePickerState();
}

enum _End { from, to }

/// The range at one build: the ends and "now" in recorder ms, and the wall
/// clock time of a recorder time.
typedef _Span = ({int from, int to, int hi, DateTime Function(int t) wall});

String _plural(int n, String one) => '$n $one${n == 1 ? '' : 's'}';

class _TapeRangePickerState extends State<TapeRangePicker>
    with TickerProviderStateMixin {
  /// Presets glide the handles.
  late final AnimationController _glide = AnimationController(vsync: this);

  /// The held handle grows and its time label rises.
  late final AnimationController _grab = AnimationController(vsync: this);

  /// The band's hatching moves while a handle is held.
  late final AnimationController _hatch = AnimationController(vsync: this);

  /// A square ring opens from a handle that snapped.
  late final AnimationController _pulse = AnimationController(vsync: this);

  /// The motion of the last build: durations follow reduced motion and
  /// the What-if slow motion.
  PinPointMotion _motion = const PinPointMotion();

  void _timeControllers(PinPointMotion motion) {
    _motion = motion;
    _glide.duration = motion.expressive;
    _grab
      ..duration = motion.scaled(const Duration(milliseconds: 180))
      ..reverseDuration = motion.scaled(const Duration(milliseconds: 260));
    _hatch.duration = motion.informative(const Duration(milliseconds: 700));
    _pulse.duration = motion.scaled(const Duration(milliseconds: 360));
  }

  final FocusNode _focus = FocusNode(debugLabel: 'pinpoint tape range');

  Timer? _tick;
  _End? _held;
  _End _last = _End.from;
  int? _snappedTo;
  double? _hoverX;

  /// Where the glide starts, as fractions of the track.
  double _glideFrom0 = 0, _glideTo0 = 1;

  /// Where the handles were drawn last, as fractions of the track.
  double _shownFrom = 0, _shownTo = 1;

  @override
  void initState() {
    super.initState();
    widget.draft.addListener(_changed);
    // The right end is "now": the track grows while the form is open.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _held == null) setState(() {});
    });
  }

  @override
  void didUpdateWidget(TapeRangePicker old) {
    super.didUpdateWidget(old);
    if (old.draft != widget.draft) {
      old.draft.removeListener(_changed);
      widget.draft.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.draft.removeListener(_changed);
    _tick?.cancel();
    _glide.dispose();
    _grab.dispose();
    _hatch.dispose();
    _pulse.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // ---- the range in recorder ms ----

  int get _lo => widget.tapes.earliestT;
  int get _hi => math.max(widget.tapes.now, _lo + 1000);

  int? get _lastMarkT {
    final marks = widget.tapes.marks;
    if (marks.isEmpty) return null;
    final t = marks.last.t;
    return t >= _lo ? t : null;
  }

  /// The start the note gets without a choice (see `_withTape`).
  int get _defaultFrom => widget.tapes.canSaveFull ? _lo : (_lastMarkT ?? _lo);

  int get _from => (widget.draft.tapeFrom ?? _defaultFrom).clamp(_lo, _hi);
  int get _to => (widget.draft.tapeTo ?? _hi).clamp(_lo, _hi);

  double _fraction(int t) => (t - _lo) / (_hi - _lo);
  int _timeAt(double fraction) =>
      (_lo + fraction.clamp(0.0, 1.0) * (_hi - _lo)).round();

  /// Sets the range; [glide] moves the handles there in 420 ms.
  void _set(int? from, int? to, {bool glide = false}) {
    if (glide) {
      _glideFrom0 = _shownFrom;
      _glideTo0 = _shownTo;
      _glide.forward(from: 0);
    }
    widget.draft.setTapeRange(from, to);
  }

  /// [end] to time [t], kept [TapeRangePicker.minRange] from the other end.
  void _move(_End end, int t) {
    final draft = widget.draft;
    if (end == _End.from) {
      final limit = _to - TapeRangePicker.minRange;
      final from = math.max(_lo, math.min(t, limit));
      _set(from, draft.tapeTo);
    } else {
      final limit = _from + TapeRangePicker.minRange;
      final to = math.min(_hi, math.max(t, limit));
      // The right edge is "now", not this moment.
      _set(draft.tapeFrom ?? _from, to >= _hi ? null : to);
    }
  }

  // ---- gestures ----

  /// The time under [x] on a track [width] wide, snapped to a mark, a route
  /// change or an end when near one.
  int _snap(double x, double width) {
    final candidates = <int>[
      _lo,
      _hi,
      for (final m in widget.tapes.marks)
        if (m.t >= _lo) m.t,
      for (final r in widget.tapes.routes)
        if (r.t >= _lo) r.t,
    ];
    int? best;
    var bestDistance = TapeRangePicker.snapDistance;
    for (final t in candidates) {
      final distance = (_fraction(t) * width - x).abs();
      if (distance <= bestDistance) {
        best = t;
        bestDistance = distance;
      }
    }
    if (best != null && best != _snappedTo) {
      HapticFeedback.selectionClick();
      _pulse.forward(from: 0);
    }
    _snappedTo = best;
    return best ?? _timeAt(x / width);
  }

  _End _nearest(double x, double width) {
    final fromX = _fraction(_from) * width;
    final toX = _fraction(_to) * width;
    if ((x - fromX).abs() == (x - toX).abs()) {
      return x < fromX ? _End.from : _End.to;
    }
    return (x - fromX).abs() < (x - toX).abs() ? _End.from : _End.to;
  }

  void _start(double x, double width) {
    _focus.requestFocus();
    _held = _last = _nearest(x, width);
    _snappedTo = null;
    _glide.stop();
    _grab.forward();
    // With reduced motion the band stays still.
    if (!_motion.reduced) _hatch.repeat();
    _move(_held!, _snap(x, width));
  }

  void _update(double x, double width) {
    final held = _held;
    if (held == null) return;
    _move(held, _snap(x, width));
  }

  void _end() {
    _held = null;
    _grab.reverse();
    _hatch.stop();
    setState(() {});
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = HardwareKeyboard.instance.isShiftPressed ? 10000 : 1000;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final sign = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      final at = _last == _End.from ? _from : _to;
      _move(_last, at + sign * step);
      return KeyEventResult.handled;
    }
    // `[` and `]` choose which end the arrows move.
    if (key == LogicalKeyboardKey.bracketLeft ||
        key == LogicalKeyboardKey.bracketRight) {
      setState(
        () =>
            _last = key == LogicalKeyboardKey.bracketLeft ? _End.from : _End.to,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- presets ----

  List<({String key, String label, int? from, int? to})> get _presets {
    final hi = _hi;
    final mark = _lastMarkT;
    return [
      (key: 'all', label: 'All', from: _lo, to: null),
      (
        key: '30s',
        label: 'Last 30 s',
        from: math.max(_lo, hi - 30000),
        to: null,
      ),
      (
        key: '2m',
        label: 'Last 2 min',
        from: math.max(_lo, hi - 120000),
        to: null,
      ),
      if (mark != null) (key: 'mark', label: 'From mark', from: mark, to: null),
    ];
  }

  bool _chosen(({String key, String label, int? from, int? to}) preset) =>
      widget.draft.tapeTo == null &&
      // "Last 30 s" moves with now: within a second counts.
      ((_from - (preset.from ?? _lo)).abs() < 1000);

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    _timeControllers(PinPointMotion.of(context));
    final now = widget.clock();
    final from = _from;
    final to = _to;
    final hi = _hi;
    DateTime wall(int t) => now.subtract(Duration(milliseconds: hi - t));
    final span = (from: from, to: to, hi: hi, wall: wall);
    return Semantics(
      container: true,
      label: 'Replay range',
      value:
          'from ${TapeRangePicker.clockTime(wall(from))} to '
          '${to >= hi ? 'now' : TapeRangePicker.clockTime(wall(to))}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _titleRow(tokens, to - from),
          const SizedBox(height: 8),
          Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _hoverRegion(constraints.maxWidth, tokens, span),
            ),
          ),
          const SizedBox(height: 6),
          _endLabels(span),
          const SizedBox(height: 8),
          _presetChips(),
          const SizedBox(height: 8),
          ..._summary(tokens, span),
        ],
      ),
    );
  }

  Widget _titleRow(PinPointTokens tokens, int length) => Row(
    children: [
      Text('REPLAY RANGE', style: tokens.caps),
      const Spacer(),
      _Length(
        key: TapeRangePicker.lengthKey,
        text: TapeRangePicker.length(length),
      ),
    ],
  );

  MouseCursor get _cursor {
    if (!widget.enabled) return SystemMouseCursors.basic;
    return _held != null
        ? SystemMouseCursors.grabbing
        : SystemMouseCursors.grab;
  }

  Widget _hoverRegion(double width, PinPointTokens tokens, _Span span) =>
      MouseRegion(
        cursor: _cursor,
        onHover: (e) => setState(() => _hoverX = e.localPosition.dx),
        onExit: (_) => setState(() => _hoverX = null),
        child: _trackGestures(width, tokens, span),
      );

  Widget _trackGestures(double width, PinPointTokens tokens, _Span span) {
    final enabled = widget.enabled;
    return GestureDetector(
      key: TapeRangePicker.trackKey,
      behavior: HitTestBehavior.opaque,
      // The handle nearest to where the finger went down,
      // not to where the drag was recognised.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: enabled
          ? (d) => _start(d.localPosition.dx, width)
          : null,
      onHorizontalDragUpdate: enabled
          ? (d) => _update(d.localPosition.dx, width)
          : null,
      onHorizontalDragEnd: enabled ? (_) => _end() : null,
      onHorizontalDragCancel: enabled ? _end : null,
      onTapUp: enabled ? (d) => _tapTo(d.localPosition.dx, width) : null,
      child: AnimatedBuilder(
        animation: Listenable.merge([_glide, _grab, _hatch, _pulse]),
        builder: (context, _) => _trackCanvas(width, tokens, span),
      ),
    );
  }

  /// A tap glides the nearer handle there.
  void _tapTo(double x, double width) {
    final end = _last = _nearest(x, width);
    _snappedTo = null;
    _glideFrom0 = _shownFrom;
    _glideTo0 = _shownTo;
    _glide.forward(from: 0);
    _move(end, _snap(x, width));
  }

  Widget _trackCanvas(double width, PinPointTokens tokens, _Span span) {
    final tapes = widget.tapes;
    final glide = PinPointMotion.enter.transform(
      _glide.isAnimating ? _glide.value : 1,
    );
    _shownFrom = _glideFrom0 + (_fraction(span.from) - _glideFrom0) * glide;
    _shownTo = _glideTo0 + (_fraction(span.to) - _glideTo0) * glide;
    final heldEnd = _held ?? (_grab.value > 0 ? _last : null);
    final heldT = heldEnd == _End.from ? span.from : span.to;
    final snapped = _snappedTo;
    return CustomPaint(
      size: Size(width, TapeRangePicker.trackHeight),
      painter: _TrackPainter(
        tokens: tokens,
        fraction: _fraction,
        from: _shownFrom,
        to: _shownTo,
        inputs: tapes.inputs.where((e) => e.t >= _lo),
        requests: tapes.requestTimes.where((t) => t >= _lo),
        marks: tapes.marks.where((e) => e.t >= _lo),
        routes: tapes.routes.where((e) => e.t >= _lo),
        held: heldEnd,
        grab: PinPointMotion.spring.transform(_grab.value),
        hatch: _hatch.value,
        pulse: _pulse.isAnimating ? _pulse.value : null,
        snapped: snapped == null ? null : _fraction(snapped),
        callout: heldEnd == null ? null : _callout(heldT, span),
        hoverX: _held == null ? _hoverX : null,
        focused: _focus.hasFocus ? _last : null,
        enabled: widget.enabled,
      ),
    );
  }

  String _callout(int heldT, _Span span) {
    final ago = span.hi <= heldT
        ? 'now'
        : '−${TapeRangePicker.length(span.hi - heldT)}';
    return '$ago · ${TapeRangePicker.clockTime(span.wall(heldT))}';
  }

  String _fromNote(int from, int hi) {
    if (from > _lo) return '${TapeRangePicker.length(hi - from)} ago';
    return widget.tapes.canSaveFull ? 'app start' : 'earliest kept';
  }

  Widget _endLabels(_Span span) {
    final (:from, :to, :hi, :wall) = span;
    final toNow = to >= hi;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _EndLabel(
            key: TapeRangePicker.fromLabelKey,
            caption: 'FROM',
            time: TapeRangePicker.clockTime(wall(from)),
            note: _fromNote(from, hi),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _EndLabel(
            key: TapeRangePicker.toLabelKey,
            caption: 'TO',
            time: toNow ? 'now' : TapeRangePicker.clockTime(wall(to)),
            note: toNow
                ? TapeRangePicker.clockTime(wall(to))
                : '${TapeRangePicker.length(hi - to)} ago',
            end: true,
          ),
        ),
      ],
    );
  }

  ChipLook _presetLook(
    ({String key, String label, int? from, int? to}) preset,
  ) {
    if (!widget.enabled) return ChipLook.disabled;
    return _chosen(preset) ? ChipLook.selected : ChipLook.rest;
  }

  Widget _presetChips() => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final preset in _presets)
        DraftChip(
          key: TapeRangePicker.presetKey(preset.key),
          label: preset.label,
          look: _presetLook(preset),
          onTap: widget.enabled
              ? () => _set(preset.from, preset.to, glide: true)
              : null,
        ),
    ],
  );

  /// The kind badge, and how many taps, edits and requests the range holds.
  List<Widget> _summary(PinPointTokens tokens, _Span span) {
    final tapes = widget.tapes;
    final (:from, :to, hi: _, wall: _) = span;
    final inRange = [
      for (final e in tapes.inputs)
        if (e.t >= from && e.t <= to) e,
    ];
    final taps = inRange
        .where((e) => e.kind == TraceKind.pointer && e.data['phase'] == 'down')
        .length;
    final edits = inRange.where((e) => e.kind == TraceKind.text).length;
    final requests = tapes.requestTimes
        .where((t) => t >= from && t <= to)
        .length;
    final full = from <= _lo && tapes.canSaveFull;
    return [
      Row(
        key: TapeRangePicker.summaryKey,
        children: [
          _KindBadge(full: full),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              full
                  ? 'Reloads the page and plays from app start'
                  : 'Plays on the screen as it is then',
              style: tokens.label.copyWith(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        '${_plural(taps, 'tap')} · ${_plural(edits, 'text edit')} · '
        '${_plural(requests, 'request')}',
        style: tokens.micro,
      ),
    ];
  }
}

/// The range's length, its digits rolling in on change.
class _Length extends StatelessWidget {
  const _Length({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: tokens.ink,
        border: Border.all(color: tokens.ink),
      ),
      alignment: Alignment.center,
      child: ClipRect(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // One roller per character, so only the digits that change
            // move.
            for (final (i, char) in text.split('').indexed)
              AnimatedSwitcher(
                key: ValueKey<String>('${text.length}-$i'),
                duration: PinPointMotion.of(context).quick,
                switchInCurve: PinPointMotion.enter,
                switchOutCurve: PinPointMotion.exit,
                transitionBuilder: (child, animation) {
                  final coming = child.key == ValueKey<String>('$i$char');
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(0, coming ? 0.9 : -0.9),
                      end: Offset.zero,
                    ).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: Text(
                  char,
                  key: ValueKey<String>('$i$char'),
                  style: tokens.value.copyWith(
                    color: tokens.paper,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `FROM 14:01:12` over `app start`.
class _EndLabel extends StatelessWidget {
  const _EndLabel({
    super.key,
    required this.caption,
    required this.time,
    required this.note,
    this.end = false,
  });

  final String caption;
  final String time;
  final String note;
  final bool end;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(caption, style: tokens.caps),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                time,
                style: tokens.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        Text(
          note,
          style: tokens.micro.copyWith(color: tokens.faint),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// `FULL` (ink fill) or `SEGMENT` (dashed outline): never color alone.
class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.full});

  final bool full;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final label = Text(
      full ? 'FULL' : 'SEGMENT',
      style: tokens.caps.copyWith(color: full ? tokens.paper : tokens.ink),
    );
    return AnimatedSwitcher(
      duration: PinPointMotion.of(context).quick,
      child: full
          ? Container(
              key: const ValueKey<String>('full'),
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              color: tokens.ink,
              child: label,
            )
          : CustomPaint(
              key: const ValueKey<String>('segment'),
              painter: _DashedBox(tokens.ink),
              child: Container(
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                child: label,
              ),
            ),
    );
  }
}

class _DashedBox extends CustomPainter {
  const _DashedBox(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    void dashed(Offset a, Offset b) {
      final length = (b - a).distance;
      final unit = (b - a) / length;
      for (var d = 0.0; d < length; d += 5) {
        canvas.drawLine(
          a + unit * d,
          a + unit * math.min(d + 3, length),
          paint,
        );
      }
    }

    final r = Offset.zero & size;
    final rect = r.deflate(0.5);
    dashed(rect.topLeft, rect.topRight);
    dashed(rect.bottomLeft, rect.bottomRight);
    dashed(rect.topLeft, rect.bottomLeft);
    dashed(rect.topRight, rect.bottomRight);
  }

  @override
  bool shouldRepaint(_DashedBox old) => old.color != color;
}

/// The track: lanes for routes, inputs and requests; the band; the handles.
class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.tokens,
    required this.fraction,
    required this.from,
    required this.to,
    required this.inputs,
    required this.requests,
    required this.marks,
    required this.routes,
    required this.held,
    required this.grab,
    required this.hatch,
    required this.pulse,
    required this.snapped,
    required this.callout,
    required this.hoverX,
    required this.focused,
    required this.enabled,
  });

  final PinPointTokens tokens;
  final double Function(int t) fraction;
  final double from;
  final double to;
  final Iterable<TraceEvent> inputs;
  final Iterable<int> requests;
  final Iterable<TraceEvent> marks;
  final Iterable<TraceEvent> routes;
  final _End? held;
  final double grab;
  final double hatch;
  final double? pulse;
  final double? snapped;
  final String? callout;
  final double? hoverX;
  final _End? focused;
  final bool enabled;

  // Lanes, top to bottom.
  static const double _routeTop = 0;
  static const double _laneTop = 18;
  static const double _baseline = 46;
  static const double _gripCenter = 57;

  bool _inside(double x, double w) => x >= from * w - 0.5 && x <= to * w + 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final fromX = from * w;
    final toX = to * w;
    _paintBand(canvas, fromX, toX);
    _paintBaseline(canvas, w, fromX, toX);
    _paintInputs(canvas, w);
    _paintRequests(canvas, w);
    _paintMarks(canvas, w);
    _paintRoutes(canvas, w);
    _paintHover(canvas, w);
    _handle(
      canvas,
      fromX,
      isHeld: held == _End.from,
      isFocused: focused == _End.from,
    );
    _handle(
      canvas,
      toX,
      isHeld: held == _End.to,
      isFocused: focused == _End.to,
    );
    final heldX = held == _End.from ? fromX : toX;
    _paintPulse(canvas, heldX);
    _paintCallout(canvas, w, heldX);
  }

  /// The band: accentBg, moving hatch, accent edges.
  void _paintBand(Canvas canvas, double fromX, double toX) {
    final band = Rect.fromLTRB(fromX, _laneTop, toX, _baseline);
    canvas.drawRect(band, Paint()..color = tokens.accentBg);
    canvas.save();
    canvas.clipRect(band);
    final hatchPaint = Paint()
      ..color = tokens.accent.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    const gap = 7.0;
    final shift = hatch * gap;
    for (var x = fromX - band.height + shift; x < toX + gap; x += gap) {
      canvas.drawLine(
        Offset(x, _baseline),
        Offset(x + band.height, _laneTop),
        hatchPaint,
      );
    }
    canvas.restore();
    final edge = Paint()
      ..color = tokens.accent
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(fromX, _laneTop + 0.5),
      Offset(toX, _laneTop + 0.5),
      edge,
    );
  }

  /// The baseline: ink inside the band, rule outside.
  void _paintBaseline(Canvas canvas, double w, double fromX, double toX) {
    final rule = Paint()
      ..color = tokens.rule
      ..strokeWidth = 1;
    canvas.drawLine(
      const Offset(0, _baseline + 0.5),
      Offset(w, _baseline + 0.5),
      rule,
    );
    canvas.drawLine(
      Offset(fromX, _baseline + 0.5),
      Offset(toX, _baseline + 0.5),
      Paint()
        ..color = tokens.ink
        ..strokeWidth = 1,
    );
  }

  /// Inputs: taps tall, typing short, keys a dot. Ink inside, faint out.
  void _paintInputs(Canvas canvas, double w) {
    for (final e in inputs) {
      final x = (fraction(e.t) * w).clamp(0.5, w - 0.5);
      final color = _inside(x, w) ? tokens.ink : tokens.faint;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      switch (e.kind) {
        case TraceKind.pointer when e.data['phase'] == 'down':
          canvas.drawLine(Offset(x, _baseline), Offset(x, _laneTop + 6), paint);
        case TraceKind.text:
          canvas.drawLine(
            Offset(x, _baseline),
            Offset(x, _baseline - 11),
            paint,
          );
        case TraceKind.key when e.data['phase'] == 'down':
          canvas.drawRect(Rect.fromLTWH(x - 0.5, _baseline - 3, 1, 2), paint);
        case TraceKind.pointer || TraceKind.key:
          break;
        default:
          canvas.drawLine(
            Offset(x, _baseline),
            Offset(x, _baseline - 7),
            paint,
          );
      }
    }
  }

  /// Requests: small squares under the line.
  void _paintRequests(Canvas canvas, double w) {
    for (final t in requests) {
      final x = (fraction(t) * w).clamp(1.5, w - 1.5);
      canvas.drawRect(
        Rect.fromCenter(center: Offset(x, _baseline + 4), width: 3, height: 3),
        Paint()..color = _inside(x, w) ? tokens.muted : tokens.rule,
      );
    }
  }

  /// Marks: an accent flag and a dashed staff.
  void _paintMarks(Canvas canvas, double w) {
    for (final m in marks) {
      final x = (fraction(m.t) * w).clamp(0.5, w - 6);
      final staff = Paint()
        ..color = tokens.accent
        ..strokeWidth = 1;
      for (var y = _laneTop; y < _baseline; y += 4) {
        canvas.drawLine(
          Offset(x, y),
          Offset(x, math.min(y + 2, _baseline)),
          staff,
        );
      }
      canvas.drawPath(
        Path()
          ..moveTo(x, _laneTop - 1)
          ..lineTo(x + 6, _laneTop + 2)
          ..lineTo(x, _laneTop + 5)
          ..close(),
        Paint()..color = tokens.accent,
      );
    }
  }

  /// Routes: a tick and the path, when there is room for it.
  void _paintRoutes(Canvas canvas, double w) {
    var free = 0.0;
    for (final r in routes) {
      final x = (fraction(r.t) * w).clamp(0.5, w - 0.5);
      canvas.drawLine(
        Offset(x, _routeTop + 2),
        Offset(x, _laneTop),
        Paint()
          ..color = tokens.muted
          ..strokeWidth = 1,
      );
      final label = '${r.data['to'] ?? ''}';
      if (x + 3 < free || label.isEmpty) continue;
      final text = _text(label, tokens.micro.copyWith(color: tokens.muted));
      if (x + 3 + text.width > w) continue;
      text.paint(canvas, Offset(x + 3, _routeTop));
      free = x + 3 + text.width + 6;
    }
  }

  /// Hover: a faint hairline where a tap would move a handle.
  void _paintHover(Canvas canvas, double w) {
    if (!enabled || hoverX == null) return;
    final x = hoverX!.clamp(0.0, w);
    final hair = Paint()
      ..color = tokens.faint
      ..strokeWidth = 1;
    for (var y = _laneTop; y < _baseline; y += 3) {
      canvas.drawLine(Offset(x, y), Offset(x, y + 1.5), hair);
    }
  }

  /// Snap pulse: a square ring opening from the held handle.
  void _paintPulse(Canvas canvas, double heldX) {
    final p = pulse;
    if (p == null || held == null) return;
    final half = 6 + 10 * Curves.easeOut.transform(p);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(heldX, _gripCenter),
        width: half * 2,
        height: half * 2,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = tokens.accent.withValues(alpha: 1 - p),
    );
  }

  /// The time over the held handle, rising as it grows.
  void _paintCallout(Canvas canvas, double w, double heldX) {
    final label = callout;
    if (label == null || grab <= 0) return;
    final text = _text(label, tokens.micro.copyWith(color: tokens.ink));
    final boxW = text.width + 10;
    final left = (heldX - boxW / 2).clamp(0.0, w - boxW);
    final top = _routeTop - 2 - 6 * grab.clamp(0.0, 1.2);
    final box = Rect.fromLTWH(left, top, boxW, 16);
    final opacity = grab.clamp(0.0, 1.0);
    canvas.drawRect(
      box.shift(const Offset(2, 2)),
      Paint()
        ..color = tokens.shadow.withValues(alpha: tokens.shadow.a * opacity),
    );
    canvas.drawRect(
      box,
      Paint()..color = tokens.paper.withValues(alpha: opacity),
    );
    canvas.drawRect(
      box.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = tokens.ink.withValues(alpha: opacity),
    );
    final shown = _text(
      label,
      tokens.micro.copyWith(color: tokens.ink.withValues(alpha: opacity)),
    );
    shown.paint(canvas, Offset(left + 5, top + 1));
  }

  void _handle(
    Canvas canvas,
    double x, {
    required bool isHeld,
    required bool isFocused,
  }) {
    final scale = isHeld ? 1 + 0.25 * grab : 1.0;
    final color = enabled ? tokens.accent : tokens.faint;
    // The staff, with a paper halo so it reads over the ticks.
    canvas.drawLine(
      Offset(x, _laneTop - 4),
      Offset(x, _gripCenter),
      Paint()
        ..color = tokens.paper
        ..strokeWidth = 4,
    );
    canvas.drawLine(
      Offset(x, _laneTop - 4),
      Offset(x, _gripCenter),
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
    final grip = Rect.fromCenter(
      center: Offset(x, _gripCenter),
      width: 12 * scale,
      height: 14 * scale,
    );
    if (isFocused) {
      canvas.drawRect(grip.inflate(3), Paint()..color = tokens.accentBg);
    }
    canvas.drawRect(
      grip.shift(const Offset(2, 2)),
      Paint()..color = tokens.shadow,
    );
    canvas.drawRect(grip, Paint()..color = isHeld ? color : tokens.paper);
    canvas.drawRect(
      grip.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = tokens.ink,
    );
    // Two grip lines.
    final lines = Paint()
      ..color = isHeld ? tokens.paper : tokens.ink
      ..strokeWidth = 1;
    for (final dx in [-1.5, 1.5]) {
      canvas.drawLine(
        Offset(x + dx * scale, grip.top + 4 * scale),
        Offset(x + dx * scale, grip.bottom - 4 * scale),
        lines,
      );
    }
  }

  static TextPainter _text(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  bool shouldRepaint(_TrackPainter old) => true;
}
