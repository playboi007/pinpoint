import 'source_scan.dart';

/// A place in `lib/` that a metric counted, for the failure message.
final class Hit {
  const Hit(this.path, this.line, this.detail);

  final String path;
  final int line;
  final String detail;

  @override
  String toString() => '$path:$line $detail';
}

/// Comment lines that name a plan, milestone, session number, step or wave.
final _planWords = RegExp(
  r'PLAN|[Mm]ilestone|\bM\d{1,2}[a-z]?\b|\b[Ss]tep \d|\bwave [A-Z]\b|'
  r'\b[Ss]ession \d|[Ss]ession[- ]notes|\bP\d{1,2}\b',
);

/// Comment lines that tell the history of the code.
final _storyWords = RegExp(
  r'watch out|we used|\bearlier\b|regression|used to |no longer|previously|'
  r'\bwas fixed\b',
  caseSensitive: false,
);

List<Hit> planComments(List<ScannedSource> files) =>
    _commentHits(files, _planWords);

List<Hit> storyComments(List<ScannedSource> files) =>
    _commentHits(files, _storyWords);

List<Hit> _commentHits(List<ScannedSource> files, RegExp pattern) => [
  for (final file in files)
    for (final comment in file.comments)
      if (pattern.hasMatch(comment.text))
        Hit(file.path, comment.line, comment.text),
];

/// Files with more lines than [limit].
List<Hit> filesOver(List<ScannedSource> files, int limit) => [
  for (final file in files)
    if (file.lineCount > limit) Hit(file.path, 1, '${file.lineCount} lines'),
];

/// "Plain Dart" headers that cite a plan: the first comment block of the file.
List<Hit> plainDartHeadersCitingPlan(List<ScannedSource> files) => [
  for (final file in files)
    if (_leadingComment(file) case final header
        when header.contains('Plain Dart') && _planWords.hasMatch(header))
      Hit(file.path, 1, 'Plain Dart header cites a plan'),
];

String _leadingComment(ScannedSource file) {
  final lines = <String>[];
  var expected = 1;
  for (final comment in file.comments) {
    if (comment.line != expected) break;
    lines.add(comment.text);
    expected++;
  }
  return lines.join('\n');
}

/// Comparisons of a value with a string literal, and `case 'x':` labels.
final _stringKind = RegExp(
  r'''(?:==|!=)\s*(?:'[^'\n]+'|"[^"\n]+")|'''
  r'''(?:'[^'\n]+'|"[^"\n]+")\s*(?:==|!=)|'''
  r'''\bcase\s+(?:'[^'\n]+'|"[^"\n]+")''',
);

List<Hit> stringKindCompares(List<ScannedSource> files) => [
  for (final file in files)
    for (final match in _stringKind.allMatches(file.codeWithStrings))
      Hit(file.path, file.lineAt(match.start), match[0]!),
];

/// Helpers with one `Object?` parameter that read a typed value from JSON,
/// such as `_map`, `_list`, `_string`, `_double` or `asList`.
final _jsonHelper = RegExp(
  r'^\s*(?:static\s+)?[\w<>?,\[\]]+(?:\s[\w<>?,\[\]]+)*\s+'
  r'(_?(?:as)?(?:map|list|string|strings|stringMap|int|double|num|number|date|'
  r'bool)(?:Of|OrNull|OrEmpty)?)'
  r'\(\s*Object\?\s+\w+\s*\)\s*(?:=>|\{)',
  caseSensitive: false,
);

/// `lib/src/model/json_read.dart` is the one place these helpers may live.
List<Hit> jsonHelpers(List<ScannedSource> files) => [
  for (final file in files)
    if (!file.path.endsWith('model/json_read.dart'))
      for (final (index, line) in file.code.split('\n').indexed)
        if (_jsonHelper.firstMatch(line) case final match?)
          Hit(file.path, index + 1, match[1]!),
];

/// Names that look like a call before `(` but are not a function.
const _notFunctions = {
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'when',
  'case',
  'return',
  'await',
  'assert',
  'super',
  'this',
  'Function',
  'else',
  'in',
};

/// A function or method with a block body, and where it starts and ends.
final class FunctionSpan {
  const FunctionSpan(this.name, this.startLine, this.endLine);

  final String name;
  final int startLine;
  final int endLine;

  int get length => endLine - startLine + 1;
}

/// Block-bodied named functions. Closures and `=>` bodies are not measured.
List<FunctionSpan> functionSpans(ScannedSource file) {
  final code = file.code;
  final matching = _matchBraces(code);
  return [
    for (final open in matching.keys)
      if (_headerBefore(code, open) case final header?)
        FunctionSpan(
          header.name,
          file.lineAt(header.nameStart),
          file.lineAt(matching[open]!),
        ),
  ];
}

List<Hit> longFunctions(List<ScannedSource> files, int limit) => [
  for (final file in files)
    for (final span in functionSpans(file))
      if (span.length > limit)
        Hit(file.path, span.startLine, '${span.name} ${span.length} lines'),
];

Map<int, int> _matchBraces(String code) {
  final matching = <int, int>{};
  final open = <int>[];
  for (var i = 0; i < code.length; i++) {
    final char = code[i];
    if (char == '{') {
      open.add(i);
    } else if (char == '}' && open.isNotEmpty) {
      matching[open.removeLast()] = i;
    }
  }
  return matching;
}

typedef _Header = ({String name, int nameStart});

/// The named function whose block opens at [brace], or null for any other
/// block: a class, an if, a switch, a closure, a map literal.
_Header? _headerBefore(String code, int brace) {
  var i = _skipBack(code, brace - 1);
  for (final modifier in const ['async*', 'sync*', 'async']) {
    if (i + 1 >= modifier.length &&
        code.startsWith(modifier, i + 1 - modifier.length)) {
      i = _skipBack(code, i - modifier.length);
      break;
    }
  }
  if (i < 0 || code[i] != ')') return null;
  final open = _matchingOpenParen(code, i);
  if (open == null) return null;
  var nameEnd = _skipBack(code, open - 1);
  if (nameEnd > 0 && code[nameEnd] == '>' && code[nameEnd - 1] == '=') {
    return null;
  }
  if (nameEnd >= 0 && code[nameEnd] == '>') {
    nameEnd = _skipBack(code, _matchingOpenAngle(code, nameEnd) - 1);
  }
  if (nameEnd < 0 || !_isIdentifierUnit(code.codeUnitAt(nameEnd))) return null;
  var nameStart = nameEnd;
  while (nameStart > 0 && _isIdentifierUnit(code.codeUnitAt(nameStart - 1))) {
    nameStart--;
  }
  final name = code.substring(nameStart, nameEnd + 1);
  if (_notFunctions.contains(name)) return null;
  return (name: name, nameStart: nameStart);
}

int _skipBack(String code, int from) {
  var i = from;
  while (i >= 0 && code[i].trim().isEmpty) {
    i--;
  }
  return i;
}

int? _matchingOpenParen(String code, int close) {
  var depth = 0;
  for (var i = close; i >= 0; i--) {
    if (code[i] == ')') depth++;
    if (code[i] == '(') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

int _matchingOpenAngle(String code, int close) {
  var depth = 0;
  for (var i = close; i >= 0; i--) {
    if (code[i] == '>') depth++;
    if (code[i] == '<') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return 0;
}

bool _isIdentifierUnit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A) ||
    unit == 0x5F ||
    unit == 0x24;

final _callOpen = RegExp(r'([A-Za-z_]\w*)\s*(?:<[^<>;{}()]*>)?\s*\(');
final _boolParameter = RegExp(r'^(?:covariant\s+)?(?:final\s+)?bool\??\s+\w+$');

/// Functions and methods with a positional `bool name` parameter. Setters,
/// function types and named or optional parameters do not count.
List<Hit> positionalBoolParameters(List<ScannedSource> files) => [
  for (final file in files)
    for (final match in _callOpen.allMatches(file.code))
      if (!_notFunctions.contains(match[1]) &&
          !_isSetterOrOperator(file.code, match.start) &&
          _positionalParameters(
            file.code,
            match.end - 1,
          ).any(_boolParameter.hasMatch))
        Hit(file.path, file.lineAt(match.start), match[1]!),
];

final _setterOrOperator = RegExp(r'\b(?:set|operator)\s+$');

bool _isSetterOrOperator(String code, int nameStart) {
  final before = code.substring(nameStart < 20 ? 0 : nameStart - 20, nameStart);
  return _setterOrOperator.hasMatch(before);
}

/// A parameter list longer than this is a call with a `<` comparison.
const _maxParameterListLength = 800;

/// The parameters of the list that opens at [open], before any `{` or `[`.
List<String> _positionalParameters(String code, int open) {
  final parameters = <String>[];
  final current = StringBuffer();
  var depth = 0;
  final end = open + _maxParameterListLength;
  for (var i = open; i < code.length && i < end; i++) {
    final char = code[i];
    if (char == '(' || char == '<') {
      depth++;
      if (depth == 1) continue;
    } else if (char == '>' && code[i - 1] == '=') {
      // the arrow of a closure, not a closing angle bracket
    } else if (char == ')' || char == '>') {
      depth--;
      if (depth == 0) break;
    } else if (depth == 1 && (char == '{' || char == '[')) {
      return parameters;
    } else if (depth == 1 && char == ',') {
      parameters.add(current.toString().trim());
      current.clear();
      continue;
    }
    current.write(char);
  }
  parameters.add(current.toString().trim());
  return parameters;
}
