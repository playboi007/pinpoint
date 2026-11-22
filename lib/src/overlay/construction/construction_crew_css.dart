part of 'construction_crew.dart';

/// The selector of each track's element.
const Map<String, String> _targets = {
  'sf': '.ppc-stk',
  'bx': '.ppc-bwalk',
  'bf': '.ppc-flip',
  'ta': '.ppc-tb',
  'sst': '.ppc-sp-st',
  'sfy': '.ppc-sfly',
  'spl': '.ppc-sp-pl',
  'sfl': '.ppc-sfl',
  'scb': '.ppc-scb',
  'thr': '.ppc-thrown',
};

/// The tracks of the wheelbarrow worker: paused, not stopped, on reveal.
const Set<String> _pausedOnReveal = {'bx', 'bf'};

/// A number for CSS: three decimals at most, no trailing zeros.
String _n(double v) {
  final s = v.toStringAsFixed(3);
  return s.contains('.')
      ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : s;
}

/// `@keyframes name` over [length] seconds from [stops].
String _keyframes(String name, double length, List<_Stop> stops) {
  final out = StringBuffer('@keyframes $name{');
  var last = -1.0;
  for (final s in stops) {
    var p = (s.t / length * 100).clamp(0.0, 100.0);
    if (p < last) p = last;
    last = p;
    out.write('${_n(p)}%{${s.css}');
    if (s.timing != null) out.write(';animation-timing-function:${s.timing}');
    out.write('}');
  }
  out.write('}');
  return out.toString();
}

/// The stops of an opacity that is 1 on each of [spans] and 0 elsewhere.
List<_Stop> _visible(
  List<(double, double)> spans,
  double length, {
  bool initial = false,
}) {
  final stops = <_Stop>[_Stop(0, 'opacity:${initial ? 1 : 0}', 'step-end')];
  for (final (a, b) in spans) {
    stops
      ..add(_Stop(a, 'opacity:1', 'step-end'))
      ..add(_Stop(b, 'opacity:0', 'step-end'));
  }
  return _close(stops, length);
}

/// Ends [stops] at [length] with the value of the last one.
List<_Stop> _close(List<_Stop> stops, double length) {
  final sorted = [...stops]..sort((a, b) => a.t.compareTo(b.t));
  final out = <_Stop>[];
  for (final s in sorted) {
    if (out.isNotEmpty &&
        (s.t - out.last.t).abs() < 1e-9 &&
        s.css == out.last.css) {
      continue;
    }
    out.add(s);
  }
  if (out.last.t < length) out.add(_Stop(length, out.last.css, null));
  return out;
}

class _Stop {
  const _Stop(this.t, this.css, this.timing);

  final double t;
  final String css;
  final String? timing;
}

/// The three parts of the crew's CSS, joined in this order.
class _CssParts {
  final keyframes = StringBuffer();
  final rules = StringBuffer();
  final reveal = StringBuffer();

  @override
  String toString() => '$keyframes$rules$reveal';
}

extension _CrewCss on ConstructionCrew {
  /// The wheelbarrow worker's walk and facing, over [list]'s trips.
  ({List<_Stop> barrow, List<_Stop> turn}) _barrowStops(
    List<StackerTrip> list,
  ) {
    final barrow = <_Stop>[_Stop(0, 'transform:translateX(0px)', null)];
    final turn = <_Stop>[_Stop(0, 'transform:scaleX(1)', 'step-end')];
    final run = layout.barrowRun;
    for (final t in list) {
      barrow
        ..add(_Stop(t.start, 'transform:translateX(0px)', null))
        ..add(
          _Stop(t.start + t.walk, 'transform:translateX(${_n(run)}px)', null),
        )
        ..add(_Stop(t.turnAt, 'transform:translateX(${_n(run)}px)', null))
        ..add(_Stop(t.end, 'transform:translateX(0px)', null));
      turn
        ..add(_Stop(t.turnAt, 'transform:scaleX(-1)', 'step-end'))
        ..add(_Stop(t.end, 'transform:scaleX(1)', 'step-end'));
    }
    return (barrow: barrow, turn: turn);
  }

  /// The block's arc: a parabola, in a few straight pieces.
  List<_Stop> _arcStops(List<StackerTrip> list) {
    final (sx, sy) = _arcStart;
    final (ex, ey) = _arcEnd;
    final lift = math.max(8.0, 0.14 * layout.stackerBoxHeight);
    String at(double u) {
      final x = sx + (ex - sx) * u - _block / 2;
      final y = sy + (ey - sy) * u - 4 * lift * u * (1 - u) - _block / 2;
      return 'transform:translate(${_n(x)}px,${_n(y)}px)';
    }

    final arc = <_Stop>[_Stop(0, at(0), null)];
    for (final t in list) {
      for (var k = 0; k <= 6; k++) {
        arc.add(
          _Stop(t.throwAt + (t.catchAt - t.throwAt) * k / 6, at(k / 6), null),
        );
      }
    }
    return arc;
  }

  /// All the tracks of one timeline of trips, as `(suffix, stops)`.
  List<(String, List<_Stop>)> _tracks(
    List<StackerTrip> list,
    double length, {
    required bool withDrop,
  }) {
    final fly = [
      for (final m in _moves(list, withDrop: withDrop))
        _Stop(
          m.t,
          'transform:translate(${_n(m.x)}px,${_n(m.y)}px)',
          m.ease.css,
        ),
    ];
    final (:barrow, :turn) = _barrowStops(list);
    final arc = _arcStops(list);
    const dropEnd = ConstructionCrew.dropStart + ConstructionCrew.dropSeconds;

    return [
      ('sf', _close(fly, length)),
      ('bx', _close(barrow, length)),
      ('bf', _close(turn, length)),
      ('ta', _close(arc, length)),
      (
        'sst',
        _close([
          _Stop(0, 'opacity:1', 'step-end'),
          for (final t in list) ...[
            _Stop(t.catchAt, 'opacity:0', 'step-end'),
            _Stop(t.liftAt, 'opacity:1', 'step-end'),
          ],
        ], length),
      ),
      (
        'sfy',
        _visible([for (final t in list) (t.catchAt, t.arriveAt)], length),
      ),
      ('spl', _visible([for (final t in list) (t.arriveAt, t.liftAt)], length)),
      (
        'sfl',
        _visible([
          if (withDrop) (ConstructionCrew.dropStart, dropEnd),
          for (final t in list) (t.catchAt, t.landAt),
        ], length),
      ),
      ('scb', _visible([for (final t in list) (t.catchAt, t.hitAt)], length)),
      ('thr', _visible([for (final t in list) (t.throwAt, t.catchAt)], length)),
    ];
  }

  String _crewCss(String key, String rootId) {
    final parts = _CssParts();
    final sel = '#$rootId .ppc-$key';
    _trackRules(parts, key, sel);
    _slipRules(parts, key, sel);
    return '$parts';
  }

  /// One keyframes pair and one rule per track: building, then the loop.
  void _trackRules(_CssParts parts, String key, String sel) {
    final build = _tracks(trips, buildEnd, withDrop: true);
    final loopT = _tracks(loop, loopLength, withDrop: false);
    final b = _n(buildEnd);
    final l = _n(loopLength);
    for (var i = 0; i < build.length; i++) {
      final suffix = build[i].$1;
      final target = _targets[suffix]!;
      final nb = 'ppc-$key-$suffix';
      final nl = 'ppc-$key-$suffix-l';
      parts.keyframes
        ..write(_keyframes(nb, buildEnd, build[i].$2))
        ..write('\n')
        ..write(_keyframes(nl, loopLength, loopT[i].$2))
        ..write('\n');
      parts.rules.write(
        '$sel $target{animation:$nb ${b}s linear 0s both,'
        '$nl ${l}s linear ${b}s infinite}\n',
      );
      if (_pausedOnReveal.contains(suffix)) {
        parts.reveal.write(
          '$sel.ppc-reveal $target{animation-play-state:paused}\n',
        );
      } else {
        parts.reveal.write('$sel.ppc-reveal $target{animation:none}\n');
      }
    }
  }

  /// The slips of the loop: a box of his slips just before he arrives and
  /// is repaired when he places the block. One keyframes per slipping box.
  void _slipRules(_CssParts parts, String key, String sel) {
    final b = _n(buildEnd);
    final l = _n(loopLength);
    for (var k = 0; k < loop.length; k++) {
      final t = loop[k];
      final s = math.max(0.0, t.arriveAt - ConstructionCrew.slipLead);
      final name = 'ppc-$key-ss$k';
      const away =
          'transform:translate(calc(.4*var(--dx)),calc(.4*var(--dy))) rotate(calc(.5*var(--dr)))';
      const over =
          'transform:translate(calc(-.06*var(--dx)),calc(-.06*var(--dy))) rotate(calc(-.1*var(--dr)))';
      parts.keyframes
        ..write(
          _keyframes(name, loopLength, [
            _Stop(0, 'transform:none', null),
            _Stop(s, 'transform:none', 'ease-out'),
            _Stop(s + 0.25, away, null),
            _Stop(t.hitAt - 0.18, away, 'cubic-bezier(.5,0,.9,.5)'),
            _Stop(t.hitAt, over, 'ease-in-out'),
            _Stop(t.hitAt + 0.15, 'transform:none', null),
            _Stop(loopLength, 'transform:none', null),
          ]),
        )
        ..write('\n');
      parts.rules.write(
        '$sel .ppc-slip.ppc-ss$k{animation:ppc-draw .3s linear var(--pd) both,'
        '$name ${l}s linear ${b}s infinite}\n',
      );
      parts.reveal.write(
        '$sel.ppc-reveal .ppc-slip.ppc-ss$k{animation:none}\n',
      );
    }
  }
}
