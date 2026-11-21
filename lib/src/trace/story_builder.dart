// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13).
// Makes the [Story] of PLAN-v3 Milestone 21b from what the recorder holds:
// the `state.notify` and `state.setState` events since the watch began, the
// causes, the input events around them, and the joins of the state lens
// (which widgets rebuilt).

import '../model/trace_event.dart';
import 'cause_zone.dart';
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
      if ((StoryKind.isHover(cause.kind) || onlyFocus) && !filter.showHover) {
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

  static String _endText(String reason) => switch (reason) {
    'target unmounted' => 'target left the screen',
    're-targeted' => 'watch moved to another widget',
    'disposed' => 'stopped',
    'window ended' => 'window ended',
    _ => reason,
  };

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
            (sameLabel || StoryKind.isHover(block.cause.kind)) &&
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
        final pointer = e.data['pointer'];
        switch (e.data['phase']) {
          case 'down':
            _downs[pointer] = e;
            _moved.remove(pointer);
          case 'move':
            _moved.add(pointer);
          case 'up' || 'cancel':
            _upDowns[e.seq] = (_downs[pointer], _moved.contains(pointer));
            _downs.remove(pointer);
            _moved.remove(pointer);
        }
        if (replaying && e.data['by'] == 'agent') _replayed.add(e.seq);
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
      if (kind == TraceKind.pointer && e.data['phase'] == 'up' ||
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

  StoryCause causeOf(_Group group) {
    final id = group.cause;
    if (id == null) {
      return const StoryCause(kind: StoryKind.none, label: 'no cause recorded');
    }
    final cause = recorder.causeOf(id);
    final kind = cause?.kind ?? CauseKind.other;
    final events = _byCause[id] ?? const <TraceEvent>[];
    StoryCause make(String k, String label) =>
        StoryCause(kind: k, label: label, id: id);

    // The last input of the cause: one pointer packet gives one event.
    TraceEvent? pointer;
    TraceEvent? key;
    TraceEvent? text;
    TraceEvent? message;
    TraceEvent? route;
    TraceEvent? net;
    for (final e in events) {
      switch (e.kind) {
        case TraceKind.pointer:
          pointer = e;
        case TraceKind.key:
          key = e;
        case TraceKind.text:
          text = e;
        case TraceKind.message:
          message ??= e;
        case TraceKind.route:
          route ??= e;
        case TraceKind.netResponse || TraceKind.netError:
          net ??= e;
      }
    }
    String joined(String verb, String target) =>
        target.isEmpty ? verb : '$verb $target';
    if (pointer != null) {
      final phase = pointer.data['phase'];
      final byAgent = pointer.data['by'] == 'agent';
      final replay = byAgent && _replayed.contains(pointer.seq);
      final prefix = replay ? 'replayed ' : (byAgent ? 'agent ' : '');
      String agentKind(String k) =>
          replay ? StoryKind.replay : (byAgent ? StoryKind.agent : k);
      switch (phase) {
        case 'hover':
          final widget = pointer.widget;
          final left = pointer.data['left'];
          return make(
            StoryKind.hover,
            widget != null
                ? 'hover $widget'
                : (left is String ? 'pointer left $left' : 'hover'),
          );
        case 'down':
          return make(
            agentKind(StoryKind.press),
            joined('${prefix}press', _target(pointer, pointer)),
          );
        case 'up':
          final pair = _upDowns[pointer.seq];
          final moved = pair?.$2 ?? false;
          final verb = moved ? 'drag' : 'tap';
          return make(
            agentKind(moved ? StoryKind.drag : StoryKind.tap),
            joined('$prefix$verb', _target(pointer, pair?.$1)),
          );
        case 'cancel':
          return make(
            agentKind(StoryKind.drag),
            joined(
              '${prefix}pointer cancelled',
              _target(pointer, _downOf(pointer)),
            ),
          );
        case 'scroll':
          return make(agentKind(StoryKind.scroll), '${prefix}scroll');
        default:
          return make(
            agentKind(StoryKind.drag),
            joined('${prefix}drag', _target(pointer, null)),
          );
      }
    }
    if (key != null) {
      final byAgent = key.data['by'] == 'agent';
      return make(
        byAgent ? StoryKind.agent : StoryKind.key,
        '${byAgent ? 'agent ' : ''}key ${key.data['key'] ?? '?'}',
      );
    }
    if (text != null) {
      final byAgent = text.data['by'] == 'agent';
      return make(
        byAgent ? StoryKind.agent : StoryKind.text,
        '${byAgent ? 'agent typed' : 'typing'} in ${text.widget ?? 'a field'}',
      );
    }
    if (message != null) {
      return make(
        StoryKind.message,
        'message from ${message.data['origin'] ?? 'another window'}',
      );
    }
    if (route != null) {
      return make(
        StoryKind.route,
        'route change ${route.data['from'] ?? '(none)'} → '
        '${route.data['to'] ?? '(none)'}',
      );
    }
    if (net != null) {
      final url = net.data['url'];
      final what =
          '${net.data['method'] ?? ''} '
                  '${url is String ? shortUrl(url) : ''}'
              .trim();
      return make(
        StoryKind.network,
        net.kind == TraceKind.netError
            ? 'network error $what'.trim()
            : 'network answer $what'.trim(),
      );
    }
    switch (kind) {
      case CauseKind.agent:
        return make(StoryKind.agent, 'agent command');
      case CauseKind.frame:
        return make(StoryKind.frame, 'frame callback');
      case CauseKind.pointer:
        return make(StoryKind.hover, 'pointer move');
      case CauseKind.message:
        return make(StoryKind.message, 'message');
      case CauseKind.key:
        return make(StoryKind.key, 'key');
      default:
        // An entry that no input names: a timer, a stream, a platform
        // callback. The zone cannot tell which.
        return make(StoryKind.timer, 'timer or async callback');
    }
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
