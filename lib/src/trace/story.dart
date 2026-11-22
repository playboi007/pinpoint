// Plain Dart: no `dart:ui` and no `package:flutter`. The bridge imports this
// file, so `state_flow` and the watch card read the same blocks.
//
// A story is a list of blocks in time order, oldest first. One block is one
// cause (a tap, a timer, a network answer, ...) with the rows it changed and
// the widgets that rebuilt. [StoryBuilder] makes it; this file is the data
// and its JSON.

import '../model/json_read.dart';

/// The kinds of cause a block has. The label says the rest.
enum StoryKind {
  tap('tap'),
  press('press'),
  drag('drag'),
  scroll('scroll'),
  hover('hover'),
  key('key'),
  text('text'),
  timer('timer'),
  network('network'),
  message('message'),
  route('route'),
  frame('frame'),
  agent('agent'),
  replay('replay'),
  other('other'),

  /// Changes that came with no cause (no `PinPoint.run`).
  none('none');

  const StoryKind(this.wire);

  final String wire;

  /// An unknown or missing kind reads as [other].
  static StoryKind fromWire(Object? wire) =>
      values.firstWhere((kind) => kind.wire == wire, orElse: () => other);

  /// Whether [StoryFilter.showHover] folds this kind.
  bool get isHover => this == hover;
}

/// What started a block.
class StoryCause {
  const StoryCause({required this.kind, required this.label, this.id});

  factory StoryCause.fromJson(Map<String, Object?> json) => StoryCause(
    kind: StoryKind.fromWire(json['kind']),
    label: '${json['label'] ?? ''}',
    id: json['id'] is int ? json['id']! as int : null,
  );

  final StoryKind kind;

  /// `tap "Fetch"`, `timer or async callback`, `no cause recorded`.
  final String label;

  /// The cause's id; null for a change with no cause.
  final int? id;

  Map<String, Object?> toJson() => {
    'kind': kind.wire,
    'label': label,
    'id': ?id,
  };
}

/// One kind of change inside a row, and how many times it happened:
/// `focused false → true` ×3.
class StoryChange {
  const StoryChange(this.text, [this.count = 1]);

  final String text;
  final int count;

  Map<String, Object?> toJson() => {'text': text, 'count': count};

  static StoryChange? fromJson(Object? json) => json is Map<String, Object?>
      ? StoryChange(
          '${json['text'] ?? ''}',
          json['count'] is int ? json['count']! as int : 1,
        )
      : null;
}

/// One instance of a notifier inside a grouped row (a list row's own
/// `ValueNotifier`), named by its nearest `Key`, list index or short text.
class StoryInstance {
  const StoryInstance(this.label, this.change);

  final String label;
  final String? change;

  Map<String, Object?> toJson() => {'label': label, 'change': ?change};

  static StoryInstance? fromJson(Object? json) => json is Map<String, Object?>
      ? StoryInstance(
          '${json['label'] ?? ''}',
          json['change'] is String ? json['change']! as String : null,
        )
      : null;
}

/// One thing that changed in a block: a notifier (one row for all the
/// instances with the same type and creating line) or a `setState`.
class StoryRow {
  const StoryRow({
    required this.kind,
    required this.owner,
    this.src,
    this.srcArg,
    this.verb,
    this.detail,
    this.mine = true,
    this.count = 1,
    this.instances = const <StoryInstance>[],
    this.instanceCount = 0,
    this.changes = const <StoryChange>[],
    this.file,
    this.line,
    this.method,
    this.afterMs,
    this.tag,
    this.hasValue = false,
  });

  factory StoryRow.fromJson(Map<String, Object?> json) => StoryRow(
    kind: '${json['kind'] ?? 'notify'}',
    owner: '${json['owner'] ?? '?'}',
    src: json['src'] is String ? json['src']! as String : null,
    srcArg: json['srcArg'] is String ? json['srcArg']! as String : null,
    verb: json['verb'] is String ? json['verb']! as String : null,
    detail: json['detail'] is String ? json['detail']! as String : null,
    mine: json['mine'] != false,
    count: json['count'] is int ? json['count']! as int : 1,
    instances: [
      for (final i in asJsonList(json['instances'])) ?StoryInstance.fromJson(i),
    ],
    instanceCount: json['instanceCount'] is int
        ? json['instanceCount']! as int
        : 0,
    changes: [
      for (final c in asJsonList(json['changes'])) ?StoryChange.fromJson(c),
    ],
    file: json['file'] is String ? json['file']! as String : null,
    line: json['line'] is int ? json['line']! as int : null,
    method: json['method'] is String ? json['method']! as String : null,
    afterMs: json['afterMs'] is int ? json['afterMs']! as int : null,
    tag: json['tag'] is String ? json['tag']! as String : null,
    hasValue: json['hasValue'] == true,
  );

  /// `notify` or `setState`.
  final String kind;

  /// The notifier's type as Dart prints it (`ValueNotifier<bool>`), or the
  /// widget whose `State` called `setState`.
  final String owner;

  /// Where the widget that listens (a builder) or provides (a scope) is
  /// created, `lib/x.dart:40`. The bridge reads the name from this line.
  final String? src;

  /// The argument to read at [src]: `valueListenable` or `listenable`.
  final String? srcArg;

  /// A known framework controller: `text changed`, `scrolled`, `focus`,
  /// `tab`, `page`, `animation`. Such a row is folded by default.
  final String? verb;

  /// More about [verb]: `index 2`.
  final String? detail;

  /// Whether the notifier is the app's own state (see [StoryFilter.onlyMine]).
  final bool mine;

  /// How many events the row folds.
  final int count;

  /// Up to [maxStoryInstances] instances, when there is more than one.
  final List<StoryInstance> instances;

  /// How many instances there were.
  final int instanceCount;

  /// The kinds of change and their counts.
  final List<StoryChange> changes;

  /// The first project frame of the first event.
  final String? file;
  final int? line;
  final String? method;

  /// Milliseconds after the cause started, when that is long enough to
  /// say ("+420 ms": the code awaited something).
  final int? afterMs;

  /// The identity of the notifier. Kept for grouping, never shown.
  final String? tag;

  /// Whether the notifier has a value (a `ValueListenable`).
  final bool hasValue;

  /// The text before the first `<`: `ValueNotifier`.
  String get base {
    final open = owner.indexOf('<');
    return open < 0 ? owner : owner.substring(0, open);
  }

  Map<String, Object?> toJson() => {
    'kind': kind,
    'owner': owner,
    'src': ?src,
    'srcArg': ?srcArg,
    'verb': ?verb,
    'detail': ?detail,
    if (!mine) 'mine': false,
    if (count != 1) 'count': count,
    if (instances.isNotEmpty)
      'instances': [for (final i in instances) i.toJson()],
    if (instanceCount > 0) 'instanceCount': instanceCount,
    if (changes.isNotEmpty) 'changes': [for (final c in changes) c.toJson()],
    'file': ?file,
    'line': ?line,
    'method': ?method,
    'afterMs': ?afterMs,
    'tag': ?tag,
    if (hasValue) 'hasValue': true,
  };

  /// A string that is equal for two rows that say the same (used to fold
  /// blocks that repeat).
  String get signature =>
      '$kind|$owner|$src|$verb|${changes.map((c) => c.text).join(';')}|$method';
}

/// One cause and what it changed.
class StoryBlock {
  const StoryBlock({
    required this.id,
    required this.at,
    required this.cause,
    this.wall,
    this.rows = const <StoryRow>[],
    this.droppedRows = 0,
    this.rebuilt = const <String>[],
    this.rebuiltCount = 0,
    this.hint,
    this.repeat = 1,
    this.lastAt,
    this.frame,
  });

  factory StoryBlock.fromJson(Map<String, Object?> json) => StoryBlock(
    id: '${json['id'] ?? ''}',
    at: json['at'] is int ? json['at']! as int : 0,
    cause: StoryCause.fromJson(asJsonMap(json['cause'])),
    wall: json['wall'] is int ? json['wall']! as int : null,
    rows: [
      for (final r in asJsonList(json['rows']))
        if (r is Map<String, Object?>) StoryRow.fromJson(r),
    ],
    droppedRows: json['droppedRows'] is int ? json['droppedRows']! as int : 0,
    rebuilt: [for (final r in asJsonList(json['rebuilt'])) '$r'],
    rebuiltCount: json['rebuiltCount'] is int
        ? json['rebuiltCount']! as int
        : 0,
    hint: json['hint'] is String ? json['hint']! as String : null,
    repeat: json['repeat'] is int ? json['repeat']! as int : 1,
    lastAt: json['lastAt'] is int ? json['lastAt']! as int : null,
    frame: json['frame'] is int ? json['frame']! as int : null,
  );

  /// `c12` for a cause, `f330` for a change with no cause. Stable for a
  /// block while the story grows; used for keys in the UI.
  final String id;

  /// Milliseconds from the start of the watch to the block's first change.
  final int at;

  /// The wall clock of [at], in ms since the epoch, for the hover on the
  /// time.
  final int? wall;

  final StoryCause cause;

  /// At most [maxStoryRows].
  final List<StoryRow> rows;
  final int droppedRows;

  /// Types of the widgets that rebuilt because of the block, at most
  /// [maxStoryRebuilt], and how many there were.
  final List<String> rebuilt;
  final int rebuiltCount;

  /// One line about the coupling (see `couplingHint`), or about a tap that
  /// may be the cause.
  final String? hint;

  /// How many identical blocks in a row this one stands for.
  final int repeat;

  /// When the last of them happened (ms from the start).
  final int? lastAt;

  /// The frame number, shown only for a block with no cause.
  final int? frame;

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at,
    'wall': ?wall,
    'cause': cause.toJson(),
    'rows': [for (final r in rows) r.toJson()],
    if (droppedRows > 0) 'droppedRows': droppedRows,
    'rebuilt': rebuilt,
    if (rebuiltCount > 0) 'rebuiltCount': rebuiltCount,
    'hint': ?hint,
    if (repeat > 1) 'repeat': repeat,
    'lastAt': ?lastAt,
    'frame': ?frame,
  };
}

/// A line that ends or interrupts the story: the target left the screen,
/// a hot reload, the window ended.
class StoryEnd {
  const StoryEnd(this.at, this.text);

  factory StoryEnd.fromJson(Map<String, Object?> json) => StoryEnd(
    json['at'] is int ? json['at']! as int : 0,
    '${json['text'] ?? ''}',
  );

  final int at;
  final String text;

  Map<String, Object?> toJson() => {'at': at, 'text': text};
}

/// What the story shows. The app's default: hover and controller changes
/// folded, every owner shown.
class StoryFilter {
  const StoryFilter({
    this.showHover = false,
    this.showControllers = false,
    this.onlyMine = false,
  });

  /// Show blocks whose cause is a hover or that only moved focus.
  final bool showHover;

  /// Show rows of framework controllers (text changed, scrolled, ...).
  final bool showControllers;

  /// Hide owners whose class and creating line are outside the project.
  final bool onlyMine;

  StoryFilter copyWith({
    bool? showHover,
    bool? showControllers,
    bool? onlyMine,
  }) => StoryFilter(
    showHover: showHover ?? this.showHover,
    showControllers: showControllers ?? this.showControllers,
    onlyMine: onlyMine ?? this.onlyMine,
  );

  @override
  bool operator ==(Object other) =>
      other is StoryFilter &&
      other.showHover == showHover &&
      other.showControllers == showControllers &&
      other.onlyMine == onlyMine;

  @override
  int get hashCode => Object.hash(showHover, showControllers, onlyMine);
}

/// Most blocks a story keeps; older ones are counted in
/// [Story.droppedBlocks].
const int maxStoryBlocks = 60;

/// Most rows one block shows.
const int maxStoryRows = 12;

/// Most instances one grouped row lists.
const int maxStoryInstances = 12;

/// Most rebuilt widget types one block names.
const int maxStoryRebuilt = 12;

/// The whole story since the watch started.
class Story {
  const Story({
    this.blocks = const <StoryBlock>[],
    this.ends = const <StoryEnd>[],
    this.droppedBlocks = 0,
    this.hiddenHover = 0,
    this.hiddenControllers = 0,
    this.hiddenForeign = 0,
    this.droppedStacks = 0,
    this.noCauseHint,
    this.startWall,
    this.rebuildsRecorded = true,
  });

  factory Story.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const Story();
    return Story(
      blocks: [
        for (final b in asJsonList(json['blocks']))
          if (b is Map<String, Object?>) StoryBlock.fromJson(b),
      ],
      ends: [
        for (final e in asJsonList(json['ends']))
          if (e is Map<String, Object?>) StoryEnd.fromJson(e),
      ],
      droppedBlocks: (asInt(json['droppedBlocks']) ?? 0),
      hiddenHover: (asInt(json['hiddenHover']) ?? 0),
      hiddenControllers: (asInt(json['hiddenControllers']) ?? 0),
      hiddenForeign: (asInt(json['hiddenForeign']) ?? 0),
      droppedStacks: (asInt(json['droppedStacks']) ?? 0),
      noCauseHint: json['noCauseHint'] is String
          ? json['noCauseHint']! as String
          : null,
      startWall: json['startWall'] is int ? json['startWall']! as int : null,
      rebuildsRecorded: json['rebuildsRecorded'] != false,
    );
  }

  /// Oldest first.
  final List<StoryBlock> blocks;

  /// Lines that end or interrupt the story, oldest first.
  final List<StoryEnd> ends;

  /// Blocks older than the last [maxStoryBlocks] that were left out.
  final int droppedBlocks;

  /// Blocks (and rows) the filter folded, by reason.
  final int hiddenHover;
  final int hiddenControllers;
  final int hiddenForeign;

  /// `setState` stacks the cap dropped.
  final int droppedStacks;

  /// Said once at the top when changes have no cause: `PinPoint.run`
  /// gives exact causes.
  final String? noCauseHint;

  /// The wall clock of time 0 of the story, ms since the epoch.
  final int? startWall;

  /// Whether rebuilds were recorded: without them no block names what
  /// rebuilt.
  final bool rebuildsRecorded;

  /// Whether something changed: a block, or changes the filter folded. End
  /// lines alone are not a change.
  bool get hasChanges =>
      blocks.isNotEmpty ||
      hiddenHover > 0 ||
      hiddenControllers > 0 ||
      hiddenForeign > 0;

  /// Blocks and end lines in time order: each item is a [StoryBlock] or a
  /// [StoryEnd]. An end line that has the same time as a block comes after
  /// it.
  List<Object> get timeline {
    final out = <Object>[...blocks, ...ends];
    // Stable: `List.sort` is not, so order by time then by position.
    final index = <Object, int>{for (var i = 0; i < out.length; i++) out[i]: i};
    out.sort((a, b) {
      final c = _at(a).compareTo(_at(b));
      return c != 0 ? c : index[a]!.compareTo(index[b]!);
    });
    return out;
  }

  static int _at(Object item) =>
      item is StoryBlock ? item.at : (item as StoryEnd).at;

  Map<String, Object?> toJson() => {
    'blocks': [for (final b in blocks) b.toJson()],
    'ends': [for (final e in ends) e.toJson()],
    if (droppedBlocks > 0) 'droppedBlocks': droppedBlocks,
    if (hiddenHover > 0) 'hiddenHover': hiddenHover,
    if (hiddenControllers > 0) 'hiddenControllers': hiddenControllers,
    if (hiddenForeign > 0) 'hiddenForeign': hiddenForeign,
    if (droppedStacks > 0) 'droppedStacks': droppedStacks,
    'noCauseHint': ?noCauseHint,
    'startWall': ?startWall,
    if (!rebuildsRecorded) 'rebuildsRecorded': false,
  };
}
