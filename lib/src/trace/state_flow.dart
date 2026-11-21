// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13).
// The chain of PLAN-v3 Milestone 21, step 4: the `state.notify` and
// `state.setState` events of one cause, the elements that rebuilt because of
// them, and one coupling hint. The app joins events with rebuilds
// (`StateLens`); this file turns the join into the answer, so the limits
// are tested without a widget tree.

import '../model/trace_event.dart';
import 'trace_format.dart';
import 'trace_recorder.dart';

/// One element that rebuilt in the frame after a state change, and why.
class FlowReader {
  const FlowReader({
    required this.type,
    required this.via,
    this.source,
    this.tag,
    this.owner,
  });

  /// The widget's type (`ProductDetailScreen`), or a `State`'s type.
  final String type;

  /// Why it rebuilt: `dependency` (it reads the object the tag names),
  /// `builder` (a `ValueListenableBuilder` or `ListenableBuilder` listens to
  /// it) or `setState` (its own `setState`).
  final String via;

  /// Where the widget is created: `lib/x.dart:40`.
  final String? source;

  /// The identity tag of the object it reads (`#a1`), for `dependency` and
  /// `builder`.
  final String? tag;

  /// The type name of that object.
  final String? owner;

  /// Two readers are the same when they have the same type, source and tag.
  String get key => '$type|$source|$tag|$via';

  Map<String, Object?> toJson() => {
    'type': type,
    'via': via,
    'source': ?source,
    'tag': ?tag,
    'owner': ?owner,
  };
}

/// The elements that rebuilt in one frame because of the state events in
/// it. Made by `StateLens` after each frame while it is armed.
class FlowRebuild {
  FlowRebuild({
    required this.frame,
    required this.eventSeqs,
    required this.readers,
  });

  /// Pinpoint's frame number when the lens made this.
  final int frame;

  /// The seqs of the `state.notify` and `state.setState` events it covers.
  final Set<int> eventSeqs;

  final List<FlowReader> readers;
}

/// Most causes one answer names.
const int maxFlowCauses = 12;

/// Most events of one kind listed for one cause.
const int maxFlowEvents = 6;

/// Most readers listed for one cause.
const int maxFlowReaders = 12;

/// Whether [e] is a `state.setState` that says nothing: its element is not
/// followed and no frame of its stack is the project's. The lens does not
/// record such an event; a recorder that holds one from an older build must
/// not show it as a row either.
bool isNoiseSetState(TraceEvent e) =>
    e.kind == TraceKind.stateSetState &&
    e.data['watched'] != true &&
    e.data['file'] == null;

/// The answer of `state_flow` for the events from [fromSeq] on: per cause,
/// what notified (and from which line), what rebuilt, and a coupling hint.
///
/// [rebuilds] are the joins of the lens. An event that no join covers has
/// an empty `rebuilt` list: nothing that the lens knows rebuilt, or rebuilds
/// were not recorded (the caller says which).
Map<String, Object?> stateFlowChain(
  TraceRecorder recorder, {
  required int fromSeq,
  required Iterable<FlowRebuild> rebuilds,
  int maxCauses = maxFlowCauses,
}) {
  // Insertion order is the order of first event: oldest group first.
  final groups = <String, _Group>{};
  var dropped = 0;
  var events = 0;
  for (var seq = fromSeq; seq < recorder.nextSeq; seq++) {
    final e = recorder.at(seq);
    if (e == null) continue;
    if (e.kind == TraceKind.stateDropped) {
      final n = e.data['n'];
      dropped += n is int ? n : 0;
      continue;
    }
    if (e.kind != TraceKind.stateNotify && e.kind != TraceKind.stateSetState) {
      continue;
    }
    if (isNoiseSetState(e)) continue;
    events++;
    final key = e.cause == null ? 'f${e.frame}' : 'c${e.cause}';
    final group = groups.putIfAbsent(key, () => _Group(e.cause, e.frame));
    if (e.kind == TraceKind.stateNotify) {
      group.notifies.add(e);
    } else if (e.data['watched'] == true) {
      // The States the lens follows come first: the framework's own
      // `setState` calls with a project frame in their stack follow.
      group.setStates.insert(group.watchedSetStates++, e);
    } else {
      group.setStates.add(e);
    }
    group.seqs.add(e.seq);
  }
  final list = groups.values.toList();
  final shown = list.length <= maxCauses
      ? list
      : list.sublist(list.length - maxCauses);
  final causes = <Map<String, Object?>>[];
  for (final group in shown) {
    final readers = <String, FlowReader>{};
    for (final join in rebuilds) {
      if (!join.eventSeqs.any(group.seqs.contains)) continue;
      for (final reader in join.readers) {
        // Only the readers of this group's objects and its own setStates.
        if (group.concerns(reader)) {
          readers.putIfAbsent(reader.key, () => reader);
        }
      }
    }
    final found = readers.values.toList();
    final cause = group.cause == null ? null : recorder.causeOf(group.cause!);
    final first = cause?.firstSeq == null
        ? null
        : recorder.at(cause!.firstSeq!);
    final hint = couplingHint(group.notifies, group.setStates, found);
    causes.add({
      if (group.cause != null) 'cause': group.cause,
      if (cause != null) 'kind': cause.kind,
      if (first != null) 'entry': '${first.kind} ${traceSummary(first)}',
      'frame': group.frame,
      't': group.notifies.isNotEmpty
          ? group.notifies.first.t
          : group.setStates.first.t,
      'notifies': [
        for (final e in group.notifies.take(maxFlowEvents)) _notifyJson(e),
      ],
      if (group.notifies.length > maxFlowEvents)
        'moreNotifies': group.notifies.length - maxFlowEvents,
      'setStates': [
        for (final e in group.setStates.take(maxFlowEvents)) _setStateJson(e),
      ],
      if (group.setStates.length > maxFlowEvents)
        'moreSetStates': group.setStates.length - maxFlowEvents,
      'rebuilt': [for (final r in found.take(maxFlowReaders)) r.toJson()],
      if (found.length > maxFlowReaders)
        'moreRebuilt': found.length - maxFlowReaders,
      'hint': ?hint,
    });
  }
  return {
    'events': events,
    'causes': causes,
    if (list.length > shown.length) 'earlierCauses': list.length - shown.length,
    if (dropped > 0) 'dropped': dropped,
  };
}

Map<String, Object?> _notifyJson(TraceEvent e) {
  final d = e.data;
  return {
    'seq': e.seq,
    'owner': d['owner'] ?? e.widget,
    'tag': d['tag'],
    'via': d['via'],
    'file': d['file'],
    'line': d['line'],
    'method': d['method'],
    if (d.containsKey('before')) 'before': d['before'],
    if (d.containsKey('after')) 'after': d['after'],
    if (d['depth'] is int) 'depth': d['depth'],
  };
}

Map<String, Object?> _setStateJson(TraceEvent e) {
  final d = e.data;
  return {
    'seq': e.seq,
    'widget': e.widget,
    'state': d['state'],
    'file': d['file'],
    'line': d['line'],
    'method': d['method'],
  };
}

class _Group {
  _Group(this.cause, this.frame);

  final int? cause;
  final int frame;
  final List<TraceEvent> notifies = <TraceEvent>[];
  final List<TraceEvent> setStates = <TraceEvent>[];
  final Set<int> seqs = <int>{};
  int watchedSetStates = 0;

  /// Whether [reader] rebuilt because of an event of this group.
  bool concerns(FlowReader reader) {
    if (reader.via == 'setState') {
      return setStates.any((e) => e.widget == reader.type);
    }
    final tag = reader.tag;
    return tag != null && notifies.any((e) => e.data['tag'] == tag);
  }
}

/// One line for one cause: the coupling shapes of PLAN-v3 Milestone 21,
/// joined with `; `. Null when there is nothing to say.
///
/// The user reads this line, so it uses plain words and never the shape
/// numbers:
/// - Shape 1, one notify, many readers: "CartModel.add() changed values
///   that 2 widgets read" (the code line under it shows what was set).
/// - Shape 2, a notify inside another notify's listener (the event's
///   `depth` is 2 or more): "B.go() ran while A.add() was being handled:
///   one change sets off another".
/// - Shape 3, two readers of one object (same tag): "FetchDialog and
///   ProductScreen read the same ProductModel".
String? couplingHint(
  List<TraceEvent> notifies,
  List<TraceEvent> setStates,
  List<FlowReader> readers,
) {
  final parts = <String>[];

  // Shape 2.
  for (final nested in notifies) {
    final depth = nested.data['depth'];
    if (depth is! int || depth < 2) continue;
    TraceEvent? parent;
    for (final other in notifies) {
      if (identical(other, nested)) continue;
      final otherDepth = other.data['depth'];
      if (otherDepth is int && otherDepth >= depth) continue;
      parent ??= other;
      if (other.data['tag'] != nested.data['tag']) {
        parent = other;
        break;
      }
    }
    final who = _who(
      nested.data['owner'] ?? nested.widget,
      nested.data['method'],
    );
    final outer = parent == null
        ? 'another change'
        : _who(parent.data['owner'] ?? parent.widget, parent.data['method']);
    parts.add(
      '$who ran while $outer was being handled: one change sets off another',
    );
    if (parts.length >= 2) break;
  }

  // Shape 1.
  final byTag = <Object?, List<TraceEvent>>{};
  for (final e in notifies) {
    final depth = e.data['depth'];
    if (depth is int && depth >= 2) continue;
    byTag.putIfAbsent(e.data['tag'], () => <TraceEvent>[]).add(e);
  }
  for (final MapEntry(key: tag, value: events) in byTag.entries) {
    final tagged = {
      for (final r in readers)
        if (r.tag == tag && r.via != 'setState') r.key: r,
    };
    if (tagged.length < 2) continue;
    final who = _who(
      events.first.data['owner'] ?? events.first.widget,
      events.first.data['method'],
    );
    final times = events.length == 1 ? '' : ' (${events.length} times)';
    parts.add('$who changed values that ${tagged.length} widgets read$times');
  }

  // Shape 3.
  final readersByTag = <String, Map<String, FlowReader>>{};
  for (final r in readers) {
    final tag = r.tag;
    if (tag == null || r.via == 'setState') continue;
    readersByTag.putIfAbsent(tag, () => <String, FlowReader>{})[r.key] = r;
  }
  for (final group in readersByTag.values) {
    // Two elements of one widget type (a list item) are not two screens.
    final types = {for (final r in group.values) r.type}.toList()..sort();
    if (types.length < 2) continue;
    final first = group.values.first;
    // The tag (`#a1`) is for grouping only: it is never shown.
    final owner = first.owner;
    parts.add(
      '${types.take(3).join(' and ')} read the same '
      '${owner == null || owner.isEmpty ? 'object' : owner}',
    );
  }

  return parts.isEmpty ? null : parts.join('; ');
}

/// `CartModel.add()` from an owner and a method (`CartModel.add` or `add`);
/// the owner alone when there is no method. Plain words for the hint line:
/// the user reads it, so no internal names such as "shape 1".
String _who(Object? owner, Object? method) {
  final name = owner?.toString() ?? '?';
  if (method is! String || method.isEmpty) return name;
  final dot = method.lastIndexOf('.');
  final short = dot < 0 ? method : method.substring(dot + 1);
  return '$name.$short()';
}
