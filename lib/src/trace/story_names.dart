// Plain Dart: no `dart:ui` and no `package:flutter`. The
// words of a story: the name ladder, short types,
// the verbs of framework controllers, and the text of a row. The watch card
// and the bridge's `state_flow` text both call these, so they say the same.

import 'story.dart';

/// Base type names of framework controllers and what their notify means.
/// A row of such an owner shows the verb, never a value, and is folded by
/// default ([StoryFilter.showControllers]).
const Map<String, String> controllerVerbs = <String, String>{
  'TextEditingController': 'text changed',
  'RestorableTextEditingController': 'text changed',
  'SearchController': 'text changed',
  'ScrollController': 'scrolled',
  'ScrollPosition': 'scrolled',
  'ScrollPositionWithSingleContext': 'scrolled',
  'TrackingScrollController': 'scrolled',
  'DraggableScrollableController': 'sheet dragged',
  'FocusNode': 'focus',
  'FocusScopeNode': 'focus',
  'TabController': 'tab',
  'PageController': 'page',
  'CarouselController': 'page',
  'WidgetStatesController': 'widget state',
  'MaterialStatesController': 'widget state',
  'TransformationController': 'zoom or pan',
  'UndoHistoryController': 'undo history',
  'AnimationController': 'animation',
  'CurvedAnimation': 'animation',
  'ProxyAnimation': 'animation',
  'ReverseAnimation': 'animation',
  'CompoundAnimation': 'animation',
  'TrainHoppingAnimation': 'animation',
  'AlwaysStoppedAnimation': 'animation',
};

/// Generic holders from the framework. They are the app's state when the
/// widget that listens to them is created in the project.
const Set<String> frameworkHolders = <String>{
  'ValueNotifier',
  'ChangeNotifier',
  'ValueListenable',
  'Listenable',
};

/// The verb of the framework controller [base] (a type name without type
/// arguments), or null. Private framework types that end in `Animation` or
/// `Evaluation` (`_AnimatedEvaluation`) are animations.
String? controllerVerb(String base) {
  final direct = controllerVerbs[base];
  if (direct != null) return direct;
  final name = base.startsWith('_') ? base.substring(1) : base;
  if (name.endsWith('Animation') || name.endsWith('Evaluation')) {
    return 'animation';
  }
  return null;
}

/// Whether [base] is a type the framework defines (a holder or a
/// controller), not a class the app declared. A class the app declared
/// names its row by itself (rung 1 of the name ladder).
bool isFrameworkType(String base) =>
    frameworkHolders.contains(base) || controllerVerb(base) != null;

/// The argument of a builder that holds the listenable.
String? builderArgument(String via) => switch (via) {
  'ValueListenableBuilder' => 'valueListenable',
  'ListenableBuilder' => 'listenable',
  'AnimatedBuilder' => 'animation',
  _ => null,
};

/// How a row is named.
class StoryName {
  const StoryName(this.text, this.rung);

  final String text;

  /// 1: the app's class. 2: the expression in the code. 3: a short type.
  final int rung;
}

/// The name ladder: (1) a class the app declared,
/// (2) the expression that [expression] read at the creating line, (3) a
/// short type. Never waits: with no [expression] yet, the short type is the
/// answer, and the caller asks again when the expression arrives.
StoryName storyName(StoryRow row, {String? expression}) {
  if (row.kind == 'setState') return StoryName(row.owner, 1);
  if (!isFrameworkType(row.base)) return StoryName(row.base, 1);
  if (expression != null && expression.isNotEmpty) {
    return StoryName(expression, 2);
  }
  return StoryName(shortType(row.owner), 3);
}

/// The type with record fields cut to their names and long type arguments
/// cut: `ValueNotifier<({bool focused, bool open})>` is
/// `ValueNotifier<(focused, open)>`.
String shortType(String type, {int max = 40}) {
  var text = _cutRecords(type.trim());
  if (text.length > max) {
    final open = text.indexOf('<');
    if (open > 0) text = '${text.substring(0, open)}<…>';
  }
  return text;
}

String _cutRecords(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    final prev = i == 0 ? '' : s[i - 1];
    if (c == '(' && (i == 0 || prev == '<' || prev == ',' || prev == ' ')) {
      final close = _match(s, i);
      if (close > i) {
        out.write(_recordNames(s.substring(i + 1, close)));
        i = close + 1;
        continue;
      }
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

// The index of the bracket that closes the one at [open], or -1.
int _match(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    switch (s[i]) {
      case '(' || '{' || '[' || '<':
        depth++;
      case ')' || '}' || ']' || '>':
        depth--;
        if (depth == 0) return i;
    }
  }
  return -1;
}

List<String> _splitTop(String s) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    switch (s[i]) {
      case '(' || '{' || '[' || '<':
        depth++;
      case ')' || '}' || ']' || '>':
        depth--;
      case ',' when depth == 0:
        parts.add(s.substring(start, i));
        start = i + 1;
    }
  }
  final last = s.substring(start);
  if (last.trim().isNotEmpty) parts.add(last);
  return parts;
}

// `bool focused, bool open` of a record type, as `(focused, open)`.
String _recordNames(String inner) {
  final names = <String>[];
  for (final raw in _splitTop(inner)) {
    final part = raw.trim();
    if (part.startsWith('{') && part.endsWith('}')) {
      for (final field in _splitTop(part.substring(1, part.length - 1))) {
        final tokens = field.trim().split(RegExp(r'\s+'));
        if (tokens.isNotEmpty && tokens.last.isNotEmpty) names.add(tokens.last);
      }
    } else if (part.isNotEmpty) {
      names.add(_cutRecords(part));
    }
  }
  return '(${names.join(', ')})';
}

final RegExp _builderName = RegExp(
  r'\b(?:ValueListenableBuilder|ListenableBuilder|AnimatedBuilder)\b',
);

// The index of the `(` that opens the builder's arguments: after its name
// and its type arguments (`<({bool a, bool b})>` has parentheses of its
// own). -1 when there is none.
int _argumentsStart(String source) {
  final name = _builderName.firstMatch(source);
  if (name == null) return source.indexOf('(');
  var i = name.end;
  while (i < source.length && source[i] == ' ') {
    i++;
  }
  if (i < source.length && source[i] == '<') {
    var depth = 0;
    for (; i < source.length; i++) {
      if (source[i] == '<') depth++;
      if (source[i] == '>') {
        depth--;
        if (depth == 0) {
          i++;
          break;
        }
      }
    }
  }
  while (i < source.length && source[i] == ' ') {
    i++;
  }
  return i < source.length && source[i] == '(' ? i : -1;
}

final RegExp _identifierPath = RegExp(
  r'[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*',
);

/// The expression given for the argument [argument] of the builder that
/// starts [source] (the statement at the creating line: the text the bridge
/// reads with `GET /source?before=0`): `_focused`, `widget.controller`,
/// `model.items`. Only an identifier or a dotted path counts; a call, an
/// index, a literal or anything else gives null (the caller keeps the short
/// type).
///
/// Only the builder's own arguments are read, not those of builders nested
/// in its `builder:` closure.
String? expressionFromSource(String source, String argument) {
  final open = _argumentsStart(source);
  if (open < 0) return null;
  // The text of the argument list with everything inside nested brackets
  // blanked out, so only the builder's own arguments are left.
  final inner = StringBuffer();
  var depth = 0;
  String? quote;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      inner.write(' ');
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      inner.write(' ');
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      depth++;
      // The builder's own parenthesis is not written. A nested bracket
      // leaves a mark, so `items[0]` and `make()` are not read as `items`.
      if (depth > 1) inner.write('§');
      continue;
    }
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth <= 0) {
        inner.write(',');
        break;
      }
      inner.write(' ');
      continue;
    }
    inner.write(depth > 1 ? ' ' : c);
  }
  final text = inner.toString();
  final arg = RegExp('(?:^|[\\s,])${RegExp.escape(argument)}\\s*:\\s*');
  for (final m in arg.allMatches(text)) {
    final rest = text.substring(m.end);
    final id = _identifierPath.matchAsPrefix(rest);
    if (id == null) continue;
    final after = rest.substring(id.end).trimLeft();
    if (!(after.startsWith(',') || after.isEmpty)) continue;
    var name = id[0]!;
    if (name.startsWith('this.')) name = name.substring(5);
    // A keyword or a literal is not a name.
    if (name == 'null' || name == 'true' || name == 'false') return null;
    return name;
  }
  return null;
}

/// `+1.24 s` from the start of the watch.
String formatStoryAt(int ms) => '+${(ms / 1000).toStringAsFixed(2)} s';

/// `+420 ms` after the cause started.
String formatAfterMs(int ms) => '+$ms ms';

/// A row's `afterMs` is kept only from this long on.
const int minAfterMs = 100;

/// The change lines of a row, as one text: `focused false → true (3), true →
/// false (9)`. When the row has one kind of change, no count.
String changesText(StoryRow row) {
  if (row.changes.isEmpty) return '';
  if (row.changes.length == 1) return row.changes.first.text;
  return [
    for (final c in row.changes)
      if (c.count > 1) '${c.text} (${c.count})' else c.text,
  ].join(', ');
}

/// The verb of a controller row: `text changed`, `tab index 2`.
String verbText(StoryRow row) {
  final verb = row.verb;
  if (verb == null) return '';
  final detail = row.detail;
  return detail == null || detail.isEmpty ? verb : '$verb $detail';
}

/// `method()` for `Class.method`; a top-level function keeps its name.
String storyMethod(String? method) {
  if (method == null || method.isEmpty) return '';
  final dot = method.lastIndexOf('.');
  final name = dot < 0 ? method : method.substring(dot + 1);
  return name.isEmpty ? '' : '$name()';
}

/// `lib/x.dart:88` for a frame's file and line. A `package:app/x.dart`
/// file shows as `lib/x.dart`.
String storyWhere(String? file, int? line) {
  if (file == null || file.isEmpty) return '';
  var shown = file;
  if (shown.startsWith('package:')) {
    final slash = shown.indexOf('/');
    shown = slash < 0 ? shown : 'lib/${shown.substring(slash + 1)}';
  }
  return line != null && line > 0 ? '$shown:$line' : shown;
}

/// The line that says what a block's cause was, with its repeat: `tap
/// "Fetch" ×12`.
String causeTitle(StoryBlock block) => block.repeat > 1
    ? '${block.cause.label} ×${block.repeat}'
    : block.cause.label;

/// The first line of a row: `_focused (ValueNotifier<(focused, open)>)
/// ×12`, `CartModel`, `_CartState setState`, `TextEditingController text
/// changed`. The change itself ([changesText]) follows on the same row.
String rowHeadline(StoryRow row, StoryName name) {
  final out = StringBuffer();
  if (row.kind == 'setState') {
    out.write('${row.owner} setState');
  } else {
    out.write(name.text);
    if (name.rung == 2) out.write(' (${shortType(row.owner)})');
    if (row.verb != null) out.write(' ${verbText(row)}');
  }
  if (row.count > 1) out.write(' ×${row.count}');
  final after = row.afterMs;
  if (after != null) out.write(' ${formatAfterMs(after)}');
  return out.toString();
}

/// The instances of a grouped row: `row 3: false → true; row 4: true →
/// false (+10 more)`. Empty when the row has one instance.
String instancesText(StoryRow row) {
  if (row.instances.isEmpty) return '';
  final parts = [
    for (final i in row.instances)
      if (i.change == null) i.label else '${i.label}: ${i.change}',
  ];
  final more = row.instanceCount - row.instances.length;
  return '${parts.join('; ')}${more > 0 ? ' (+$more more)' : ''}';
}

/// The time of a block: `+1.24 s`, or `+1.24 s … +3.00 s` for blocks that
/// repeated.
String blockTime(StoryBlock block) {
  final last = block.lastAt;
  return block.repeat > 1 && last != null && last != block.at
      ? '${formatStoryAt(block.at)} … ${formatStoryAt(last)}'
      : formatStoryAt(block.at);
}

/// The cause of a block as a line, with its frame when it has no cause.
String causeLine(StoryBlock block) {
  final frame = block.frame;
  final tail = frame == null ? '' : ' (f$frame)';
  return '${causeTitle(block)}$tail';
}

/// The line about hidden changes, or null: `4 hover changes hidden`.
String? hiddenLine(Story story) {
  final parts = <String>[
    if (story.hiddenHover > 0)
      '${story.hiddenHover} hover or focus change'
          '${story.hiddenHover == 1 ? '' : 's'} hidden',
    if (story.hiddenControllers > 0)
      '${story.hiddenControllers} controller change'
          '${story.hiddenControllers == 1 ? '' : 's'} hidden',
    if (story.hiddenForeign > 0)
      '${story.hiddenForeign} change'
          '${story.hiddenForeign == 1 ? '' : 's'} of other owners hidden',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}
