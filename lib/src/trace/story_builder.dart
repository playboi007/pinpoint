// Plain Dart: no `dart:ui` and no `package:flutter`.
// Makes the [Story] from what the recorder holds: the `state.notify` and
// `state.setState` events since the watch began, the causes, the input events
// around them, and the joins of the state lens (which widgets rebuilt).

import '../model/trace_event.dart';
import 'cause_zone.dart';
import 'pointer_phase.dart';
import 'state_flow.dart';
import 'story.dart';
import 'story_names.dart';
import 'trace_format.dart' show shortUrl;
import 'trace_recorder.dart';

/// How far before a change a tap or a key can be for the "maybe after"
/// hint (a change that has no cause).
const int maybeAfterMs = 300;

/// How many events before the watch are read, to find the pointer down of
/// a pointer up.
const int lookBackEvents = 300;

/// Widget types whose `setState` only moves focus. A block that has no
/// other row is folded with the hover blocks.
const Set<String> focusWidgets = <String>{
  'Focus',
  '_FocusState',
  'FocusScope',
  'FocusableActionDetector',
  '_FocusableActionDetectorState',
};

/// What the watch card and the `state_flow` text show.
class StoryBuilder {
  const StoryBuilder._();

  /// The story of the events from [fromSeq] on.
  ///
  /// [startT] is the recorder time of the watch's start; times in the story
  /// count from it. [rebuilds] are the joins of the lens. [ends] are lines
  /// the lens knows (a hot reload) and [endedBecause] why the window ended
  /// (null while it runs), with [endedAt] in recorder time.
  static Story build({
    required TraceRecorder recorder,
    required int fromSeq,
    required int startT,
    required Iterable<FlowRebuild> rebuilds,
    StoryFilter filter = const StoryFilter(),
    int? startWall,
    List<StoryEnd> ends = const <StoryEnd>[],
    String? endedBecause,
    int? endedAt,
    bool rebuildsRecorded = true,
  }) {
    final ctx = _Context(recorder, fromSeq, startT);
    ctx.scan();

    // One group per cause, in order of the first change.
    final blocks = <StoryBlock>[];
    var hiddenHover = 0;
    var hiddenControllers = 0;
    var hiddenForeign = 0;
    var causeless = false;
    for (final group in ctx.groups.values) {
      final cause = ctx.causeOf(group);
      final rows = ctx.rowsOf(group);
      if (cause.kind == StoryKind.none) causeless = true;
      final events = group.states.length;
      final onlyFocus =
          rows.isNotEmpty &&
          rows.every(
            (r) =>
                r.verb == 'focus' ||
                (r.kind == 'setState' && focusWidgets.contains(r.owner)),
          );
      if ((cause.kind.isHover || onlyFocus) && !filter.showHover) {
        hiddenHover += events;
        continue;
      }
      final shown = <StoryRow>[];
      for (final row in rows) {
        if (row.verb != null && !filter.showControllers) {
          hiddenControllers += row.count;
          continue;
        }
        if (filter.onlyMine && !row.mine) {
          hiddenForeign += row.count;
          continue;
        }
        shown.add(row);
      }
      if (shown.isEmpty) continue;
      final first = group.states.first;
      final at = first.t - startT < 0 ? 0 : first.t - startT;
      final readers = ctx.readersOf(group, rebuilds);
      final names = <String>{for (final r in readers) r.type}.toList();
      blocks.add(
        StoryBlock(
          id: group.cause == null ? 'f${group.frame}' : 'c${group.cause}',
          at: at,
          wall: startWall == null ? null : startWall + at,
          cause: cause,
          rows: shown.take(maxStoryRows).toList(),
          droppedRows: shown.length > maxStoryRows
              ? shown.length - maxStoryRows
              : 0,
          rebuilt: names.take(maxStoryRebuilt).toList(),
          rebuiltCount: names.length,
          hint: ctx.hintOf(group, cause, readers),
          frame: group.cause == null ? group.frame : null,
        ),
      );
    }

    final merged = _fold(blocks);
    final dropped = merged.length > maxStoryBlocks
        ? merged.length - maxStoryBlocks
        : 0;
    final kept = dropped == 0
        ? merged
        : merged.sublist(merged.length - maxStoryBlocks);

    final endLines = <StoryEnd>[
      ...ends,
      if (endedBecause != null)
        StoryEnd(
          endedAt == null
              ? _lastAt(kept)
              : (endedAt - startT).clamp(0, 1 << 40),
          _endText(endedBecause),
        ),
    ];
    return Story(
      blocks: kept,
      ends: endLines,
      droppedBlocks: dropped,
      hiddenHover: hiddenHover,
      hiddenControllers: hiddenControllers,
      hiddenForeign: hiddenForeign,
      droppedStacks: ctx.droppedStacks,
      noCauseHint: causeless && !recorder.causesRecorded
          ? 'Changes have no cause: PinPoint.run around runApp gives exact '
                'causes.'
          : null,
      startWall: startWall,
      rebuildsRecorded: rebuildsRecorded,
    );
  }

  static int _lastAt(List<StoryBlock> blocks) =>
      blocks.isEmpty ? 0 : (blocks.last.lastAt ?? blocks.last.at);

  /// The end line for each reason the lens gives. Any other reason is shown
  /// as it is.
  static const Map<String, String> _endTexts = {
    'target unmounted': 'target left the screen',
    're-targeted': 'watch moved to another widget',
    'disposed': 'stopped',
    'window ended': 'window ended',
  };

  static String _endText(String reason) => _endTexts[reason] ?? reason;

  // Blocks in a row that say the same become one with a count. A hover over
  // different rows of one list says the same, so their labels are cut to
  // "hover".
  static List<StoryBlock> _fold(List<StoryBlock> blocks) {
    final out = <StoryBlock>[];
    for (final block in blocks) {
      if (out.isNotEmpty) {
        final last = out.last;
        final sameKind = last.cause.kind == block.cause.kind;
        final sameLabel = last.cause.label == block.cause.label;
        if (sameKind &&
            (sameLabel || block.cause.kind.isHover) &&
            _rowsKey(last) == _rowsKey(block)) {
          out[out.length - 1] = StoryBlock(
            id: last.id,
            at: last.at,
            wall: last.wall,
            cause: sameLabel
                ? last.cause
                : StoryCause(kind: last.cause.kind, label: 'hover'),
            rows: last.rows,
            droppedRows: last.droppedRows,
            rebuilt: last.rebuilt,
            rebuiltCount: last.rebuiltCount,
            hint: last.hint,
            repeat: last.repeat + block.repeat,
            lastAt: block.lastAt ?? block.at,
            frame: last.frame,
          );
          continue;
        }
      }
      out.add(block);
    }
    return out;
  }

  static String _rowsKey(StoryBlock block) =>
      block.rows.map((r) => r.signature).join('\n');
}

/// Who started a pointer cause: the user, the agent, or a tape replay.
enum _Origin {
  user(''),
  agent('agent '),
  replay('replayed ');

  const _Origin(this.prefix);

  /// Starts the label: `agent tap "Save"`.
  final String prefix;

  StoryKind kindOr(StoryKind own) => switch (this) {
    user => own,
    agent => StoryKind.agent,
    replay => StoryKind.replay,
  };
}

/// The input event that names a cause. Pointer, key and text keep the last
/// event of the cause; message, route and network keep the first.
sealed class _Trigger {
  const _Trigger(this.event);

  final TraceEvent event;

  static _Trigger? of(List<TraceEvent> events) {
    TraceEvent? last(String kind) =>
        events.where((e) => e.kind == kind).lastOrNull;
    TraceEvent? first(String kind) =>
        events.where((e) => e.kind == kind).firstOrNull;

    if (last(TraceKind.pointer) case final e?) return _Pointer(e);
    if (last(TraceKind.key) case final e?) return _Key(e);
    if (last(TraceKind.text) case final e?) return _Text(e);
    if (first(TraceKind.message) case final e?) return _Message(e);
    if (first(TraceKind.route) case final e?) return _Route(e);
    final answer = events
        .where(
          (e) =>
              e.kind == TraceKind.netResponse || e.kind == TraceKind.netError,
        )
        .firstOrNull;
    return answer == null ? null : _Net(answer);
  }
}

final class _Pointer extends _Trigger {
  const _Pointer(super.event);
}

final class _Key extends _Trigger {
  const _Key(super.event);
}

final class _Text extends _Trigger {
  const _Text(super.event);
}

final class _Message extends _Trigger {
  const _Message(super.event);
}

final class _Route extends _Trigger {
  const _Route(super.event);
}

final class _Net extends _Trigger {
  const _Net(super.event);
}

class _Group {
  _Group(this.cause, this.frame);

  final int? cause;
  final int frame;
  final List<TraceEvent> states = <TraceEvent>[];
  final List<TraceEvent> notifies = <TraceEvent>[];
  final List<TraceEvent> setStates = <TraceEvent>[];
  int watchedSetStates = 0;
}

class _Context {
  _Context(this.recorder, this.fromSeq, this.startT);

  final TraceRecorder recorder;
  final int fromSeq;
  final int startT;

  final Map<String, _Group> groups = <String, _Group>{};

  // Inputs, net, route and message events by cause.
  final Map<int, List<TraceEvent>> _byCause = <int, List<TraceEvent>>{};

  // The pointer down of each pointer id, and whether it moved since.
  final Map<Object?, TraceEvent> _downs = <Object?, TraceEvent>{};
  final Set<Object?> _moved = <Object?>{};
  final Set<int> _replayed = <int>{};
  // Taps and keys, for the "maybe after" hint: (t, label).
  final List<(int, String)> _inputs = <(int, String)>[];
  // For an `up`: the down that preceded it and whether the pointer moved
  // between them, by the up's seq.
  final Map<int, (TraceEvent?, bool)> _upDowns = <int, (TraceEvent?, bool)>{};
  int droppedStacks = 0;

  void scan() {
    final start = fromSeq - lookBackEvents < 1 ? 1 : fromSeq - lookBackEvents;
    var replaying = false;
    for (var seq = start; seq < recorder.nextSeq; seq++) {
      final e = recorder.at(seq);
      if (e == null) continue;
      final kind = e.kind;
      if (kind == TraceKind.replayStart) {
        replaying = true;
      } else if (kind == TraceKind.replayEnd) {
        replaying = false;
      }
      if (kind == TraceKind.pointer) {
        _trackPointer(e);
        if (replaying && e.byAgent) _replayed.add(e.seq);
      }
      if (seq < fromSeq) continue;
      if (kind == TraceKind.stateDropped) {
        final n = e.data['n'];
        droppedStacks += n is int ? n : 0;
        continue;
      }
      final id = e.cause;
      if (id != null &&
          (TraceKind.isInput(kind) ||
              kind.startsWith('net.') ||
              kind == TraceKind.route)) {
        _byCause.putIfAbsent(id, () => <TraceEvent>[]).add(e);
      }
      if (kind == TraceKind.pointer && e.pointerPhase == PointerPhase.up ||
          kind == TraceKind.key && e.data['phase'] == 'down' ||
          kind == TraceKind.text) {
        _inputs.add((e.t, _inputLabel(e)));
      }
      if (kind != TraceKind.stateNotify && kind != TraceKind.stateSetState) {
        continue;
      }
      if (isNoiseSetState(e)) continue;
      final key = e.cause == null ? 'f${e.frame}' : 'c${e.cause}';
      final group = groups.putIfAbsent(key, () => _Group(e.cause, e.frame));
      group.states.add(e);
      if (kind == TraceKind.stateNotify) {
        group.notifies.add(e);
      } else if (e.data['watched'] == true) {
        group.setStates.insert(group.watchedSetStates++, e);
      } else {
        group.setStates.add(e);
      }
    }
  }

  /// Remembers each pointer's down, and whether it moved before its up.
  void _trackPointer(TraceEvent e) {
    final pointer = e.data['pointer'];
    switch (e.pointerPhase) {
      case PointerPhase.down:
        _downs[pointer] = e;
        _moved.remove(pointer);
      case PointerPhase.move:
        _moved.add(pointer);
      case PointerPhase.up || PointerPhase.cancel:
        _upDowns[e.seq] = (_downs[pointer], _moved.contains(pointer));
        _downs.remove(pointer);
        _moved.remove(pointer);
      case PointerPhase.hover || PointerPhase.scroll || PointerPhase.drag:
        break;
    }
  }

  // ------------------------------------------------------------- causes

  String _inputLabel(TraceEvent e) => switch (e.kind) {
    TraceKind.pointer => 'tap ${_target(e, _downOf(e))}'.trimRight(),
    TraceKind.key => 'key ${e.data['key'] ?? '?'}',
    _ => 'text in ${e.widget ?? 'a field'}',
  };

  TraceEvent? _downOf(TraceEvent up) => _upDowns[up.seq]?.$1;

  // `"Fetch"` (the text on the widget under the pointer), else the widget's
  // type, else the position.
  String _target(TraceEvent e, TraceEvent? down) {
    final source = down ?? e;
    final text = source.data['label'];
    if (text is String && text.isNotEmpty) return '"$text"';
    final widget = source.widget ?? e.widget;
    if (widget != null) return widget;
    final x = e.data['x'];
    final y = e.data['y'];
    return x is num && y is num ? 'at ${x.round()},${y.round()}' : '';
  }

  /// The input that caused [group]. Without one, the kind of entry says what
  /// it was.
  StoryCause causeOf(_Group group) {
    final id = group.cause;
    if (id == null) {
      return const StoryCause(kind: StoryKind.none, label: 'no cause recorded');
    }
    return switch (_Trigger.of(_byCause[id] ?? const <TraceEvent>[])) {
      _Pointer(:final event) => _pointerCause(id, event),
      _Key(:final event) => _keyCause(id, event),
      _Text(:final event) => _textCause(id, event),
      _Message(:final event) => _cause(
        id,
        StoryKind.message,
        'message from ${event.data['origin'] ?? 'another window'}',
      ),
      _Route(:final event) => _cause(
        id,
        StoryKind.route,
        'route change ${event.data['from'] ?? '(none)'} → '
        '${event.data['to'] ?? '(none)'}',
      ),
      _Net(:final event) => _netCause(id, event),
      null => _entryCause(id, recorder.causeOf(id)?.kind ?? CauseKind.other),
    };
  }

  static StoryCause _cause(int id, StoryKind kind, String label) =>
      StoryCause(kind: kind, label: label, id: id);

  static String _joined(String verb, String target) =>
      target.isEmpty ? verb : '$verb $target';

  StoryCause _pointerCause(int id, TraceEvent pointer) {
    final origin = _originOf(pointer);
    final prefix = origin.prefix;
    final (down, moved) = _upDowns[pointer.seq] ?? (null, false);
    return switch (pointer.pointerPhase) {
      PointerPhase.hover => _cause(id, StoryKind.hover, _hoverLabel(pointer)),
      PointerPhase.down => _cause(
        id,
        origin.kindOr(StoryKind.press),
        _joined('${prefix}press', _target(pointer, pointer)),
      ),
      PointerPhase.up => _cause(
        id,
        origin.kindOr(moved ? StoryKind.drag : StoryKind.tap),
        _joined('$prefix${moved ? 'drag' : 'tap'}', _target(pointer, down)),
      ),
      PointerPhase.cancel => _cause(
        id,
        origin.kindOr(StoryKind.drag),
        _joined(
          '${prefix}pointer cancelled',
          _target(pointer, _downOf(pointer)),
        ),
      ),
      PointerPhase.scroll => _cause(
        id,
        origin.kindOr(StoryKind.scroll),
        '${prefix}scroll',
      ),
      PointerPhase.move || PointerPhase.drag => _cause(
        id,
        origin.kindOr(StoryKind.drag),
        _joined('${prefix}drag', _target(pointer, null)),
      ),
    };
  }

  _Origin _originOf(TraceEvent pointer) => switch (pointer.byAgent) {
    false => _Origin.user,
    true when _replayed.contains(pointer.seq) => _Origin.replay,
    true => _Origin.agent,
  };

  static String _hoverLabel(TraceEvent pointer) {
    final widget = pointer.widget;
    if (widget != null) return 'hover $widget';
    return switch (pointer.data['left']) {
      final String left => 'pointer left $left',
      _ => 'hover',
    };
  }

  static StoryCause _keyCause(int id, TraceEvent key) {
    final name = key.data['key'] ?? '?';
    return key.byAgent
        ? _cause(id, StoryKind.agent, 'agent key $name')
        : _cause(id, StoryKind.key, 'key $name');
  }

  static StoryCause _textCause(int id, TraceEvent text) {
    final field = text.widget ?? 'a field';
    return text.byAgent
        ? _cause(id, StoryKind.agent, 'agent typed in $field')
        : _cause(id, StoryKind.text, 'typing in $field');
  }

  static StoryCause _netCause(int id, TraceEvent net) {
    final url = net.data['url'];
    final what =
        '${net.data['method'] ?? ''} ${url is String ? shortUrl(url) : ''}'
            .trim();
    final label = net.kind == TraceKind.netError
        ? 'network error $what'
        : 'network answer $what';
    return _cause(id, StoryKind.network, label.trim());
  }

  /// The cause of a change that no input names. A timer, a stream or a
  /// platform callback: the zone cannot tell which.
  static const Map<String, (StoryKind, String)> _entryCauses = {
    CauseKind.agent: (StoryKind.agent, 'agent command'),
    CauseKind.frame: (StoryKind.frame, 'frame callback'),
    CauseKind.pointer: (StoryKind.hover, 'pointer move'),
    CauseKind.message: (StoryKind.message, 'message'),
    CauseKind.key: (StoryKind.key, 'key'),
  };

  static StoryCause _entryCause(int id, String kind) {
    final (storyKind, label) =
        _entryCauses[kind] ?? (StoryKind.timer, 'timer or async callback');
    return _cause(id, storyKind, label);
  }

  // ---------------------------------------------------------------- rows

  List<StoryRow> rowsOf(_Group group) {
    final cause = group.cause == null ? null : recorder.causeOf(group.cause!);
    final rows = <StoryRow>[];
    final byKey = <String, _RowAcc>{};
    for (final e in group.notifies) {
      final d = e.data;
      final owner = '${d['owner'] ?? e.widget ?? '?'}';
      final src = d['src'] is String ? d['src']! as String : null;
      final verb = controllerVerb(_base(owner));
      final key = 'n|$owner|$src';
      byKey.putIfAbsent(key, () => _RowAcc(e, owner, src, verb, cause)).add(e);
    }
    rows.addAll(byKey.values.map((a) => a.row()));
    final bySet = <String, _SetAcc>{};
    for (final e in group.setStates) {
      final key = '${e.widget}|${e.data['file']}|${e.data['line']}';
      bySet.putIfAbsent(key, () => _SetAcc(e, cause)).count++;
    }
    rows.addAll(bySet.values.map((a) => a.row()));
    return rows;
  }

  static String _base(String owner) {
    final open = owner.indexOf('<');
    return open < 0 ? owner : owner.substring(0, open);
  }

  // ------------------------------------------------------- rebuilds, hints

  List<FlowReader> readersOf(_Group group, Iterable<FlowRebuild> rebuilds) {
    final seqs = {for (final e in group.states) e.seq};
    final tags = {for (final e in group.notifies) e.data['tag']};
    final types = {for (final e in group.setStates) e.widget};
    final found = <String, FlowReader>{};
    for (final join in rebuilds) {
      if (!join.eventSeqs.any(seqs.contains)) continue;
      for (final reader in join.readers) {
        final concerns = reader.via == 'setState'
            ? types.contains(reader.type)
            : reader.tag != null && tags.contains(reader.tag);
        if (concerns) found.putIfAbsent(reader.key, () => reader);
      }
    }
    return found.values.toList();
  }

  String? hintOf(_Group group, StoryCause cause, List<FlowReader> readers) {
    final hint = couplingHint(group.notifies, group.setStates, readers);
    if (hint != null) return hint;
    if (cause.kind != StoryKind.none) return null;
    final first = group.states.first.t;
    (int, String)? latest;
    for (final input in _inputs) {
      if (input.$1 <= first && first - input.$1 <= maybeAfterMs) {
        latest = input;
      }
    }
    return latest == null ? null : 'maybe after ${latest.$2}';
  }
}

class _RowAcc {
  _RowAcc(this.first, this.owner, this.src, this.verb, this.cause);

  final TraceEvent first;
  final String owner;
  final String? src;
  final String? verb;
  final TraceCause? cause;
  int count = 0;
  final Map<String, int> changes = <String, int>{};
  // Per instance (by tag): label and the last change.
  final Map<String, (String, String?)> instances =
      <String, (String, String?)>{};

  void add(TraceEvent e) {
    count++;
    final d = e.data;
    String? change;
    if (verb == null) {
      if (d['change'] is String) {
        change = d['change']! as String;
      } else if (d.containsKey('after')) {
        change = '${d['before']} → ${d['after']}';
      }
    }
    if (change != null) changes[change] = (changes[change] ?? 0) + 1;
    final tag = d['tag'] is String
        ? d['tag']! as String
        : '#${instances.length}';
    final label = d['instance'] is String ? d['instance']! as String : null;
    instances[tag] = (label ?? '', change);
  }

  StoryRow row() {
    final d = first.data;
    final base = _Context._base(owner);
    final startT = cause?.t;
    final after = startT == null ? null : first.t - startT;
    final many = instances.length > 1;
    var n = 0;
    final listed = <StoryInstance>[];
    if (many) {
      for (final MapEntry(value: (label, change)) in instances.entries) {
        n++;
        listed.add(
          StoryInstance(label.isEmpty ? 'instance $n' : label, change),
        );
        if (listed.length >= maxStoryInstances) break;
      }
    }
    return StoryRow(
      kind: 'notify',
      owner: owner,
      src: src,
      srcArg: d['srcArg'] is String ? d['srcArg']! as String : null,
      verb: verb,
      detail: d['detail'] is String ? d['detail']! as String : null,
      mine:
          verb == null &&
          (!isFrameworkType(base) ||
              (frameworkHolders.contains(base) && src != null)),
      count: count,
      instances: listed,
      instanceCount: many ? instances.length : 0,
      changes: [for (final e in changes.entries) StoryChange(e.key, e.value)],
      file: d['file'] is String ? d['file']! as String : null,
      line: d['line'] is int ? d['line']! as int : null,
      method: d['method'] is String ? d['method']! as String : null,
      afterMs: after != null && after >= minAfterMs ? after : null,
      tag: d['tag'] is String ? d['tag']! as String : null,
      hasValue: d.containsKey('after'),
    );
  }
}

class _SetAcc {
  _SetAcc(this.first, this.cause);

  final TraceEvent first;
  final TraceCause? cause;
  int count = 0;

  StoryRow row() {
    final d = first.data;
    final startT = cause?.t;
    final after = startT == null ? null : first.t - startT;
    return StoryRow(
      kind: 'setState',
      owner: first.widget ?? '?',
      count: count,
      file: d['file'] is String ? d['file']! as String : null,
      line: d['line'] is int ? d['line']! as int : null,
      method: d['method'] is String ? d['method']! as String : null,
      afterMs: after != null && after >= minAfterMs ? after : null,
    );
  }
}
