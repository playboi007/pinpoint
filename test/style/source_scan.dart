import 'dart:io';

/// One comment line found in a source file.
final class CommentLine {
  const CommentLine(this.line, this.text);

  final int line;
  final String text;
}

/// A Dart source file with comments and string contents taken out.
///
/// [code] blanks both. [codeWithStrings] blanks comments only. Both keep the
/// length and the newlines of the original, so offsets give the same lines.
final class ScannedSource {
  factory ScannedSource.read(File file) {
    final source = file.readAsStringSync();
    final scanner = _Scanner(source)..run();
    return ScannedSource._(
      path: file.path,
      source: source,
      code: String.fromCharCodes(scanner.code),
      codeWithStrings: String.fromCharCodes(scanner.codeWithStrings),
      comments: scanner.comments,
    );
  }

  ScannedSource._({
    required this.path,
    required this.source,
    required this.code,
    required this.codeWithStrings,
    required this.comments,
  }) : _lineStarts = _lineStartsOf(source);

  final String path;
  final String source;
  final String code;
  final String codeWithStrings;
  final List<CommentLine> comments;
  final List<int> _lineStarts;

  int get lineCount => _lineStarts.length;

  /// The 1-based line that holds [offset].
  int lineAt(int offset) {
    var low = 0;
    var high = _lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  static List<int> _lineStartsOf(String source) => [
    0,
    for (var i = 0; i < source.length; i++)
      if (source.codeUnitAt(i) == _newline) i + 1,
  ];
}

const _newline = 0x0A;
const _space = 0x20;

/// Reads comments and strings with the Dart rules: quotes, triple quotes,
/// raw strings, escapes, `${}` interpolation and nested block comments.
final class _Scanner {
  _Scanner(this.source)
    : code = source.codeUnits.toList(),
      codeWithStrings = source.codeUnits.toList(),
      _lineStarts = ScannedSource._lineStartsOf(source);

  final String source;
  final List<int> code;
  final List<int> codeWithStrings;
  final List<CommentLine> comments = [];
  final List<int> _lineStarts;
  int _i = 0;

  void run() => _code(inInterpolation: false);

  void _code({required bool inInterpolation}) {
    var depth = 0;
    while (_i < source.length) {
      final char = source[_i];
      if (source.startsWith('//', _i)) {
        _lineComment();
      } else if (source.startsWith('/*', _i)) {
        _blockComment();
      } else if (char == "'" || char == '"') {
        _string(isRaw: false);
      } else if (char == 'r' && _startsRawString()) {
        _i++;
        _string(isRaw: true);
      } else if (inInterpolation && char == '{') {
        depth++;
        _i++;
      } else if (inInterpolation && char == '}') {
        _i++;
        if (depth == 0) return;
        depth--;
      } else {
        _i++;
      }
    }
  }

  bool _startsRawString() {
    if (_i + 1 >= source.length) return false;
    final next = source[_i + 1];
    if (next != "'" && next != '"') return false;
    return _i == 0 || !RegExp(r'\w').hasMatch(source[_i - 1]);
  }

  void _lineComment() {
    final end = source.indexOf('\n', _i);
    final stop = end == -1 ? source.length : end;
    _addComment(_i, stop);
    _blank(_i, stop, strings: true);
    _i = stop;
  }

  void _blockComment() {
    final start = _i;
    var depth = 0;
    while (_i < source.length) {
      if (source.startsWith('/*', _i)) {
        depth++;
        _i += 2;
      } else if (source.startsWith('*/', _i)) {
        depth--;
        _i += 2;
        if (depth == 0) break;
      } else {
        _i++;
      }
    }
    var lineStart = start;
    for (var k = start; k <= _i; k++) {
      if (k == _i || source.codeUnitAt(k) == _newline) {
        _addComment(lineStart, k);
        lineStart = k + 1;
      }
    }
    _blank(start, _i, strings: true);
  }

  void _addComment(int start, int end) {
    comments.add(
      CommentLine(_lineOf(start), source.substring(start, end).trim()),
    );
  }

  void _string({required bool isRaw}) {
    final quote = source[_i];
    final isTriple = source.startsWith(quote * 3, _i);
    final openLength = isTriple ? 3 : 1;
    _i += openLength;
    final contentStart = _i;
    while (_i < source.length) {
      final char = source[_i];
      if (isTriple && source.startsWith(quote * 3, _i)) {
        _blank(contentStart, _i, strings: false);
        _i += 3;
        return;
      }
      if (!isTriple && char == quote) {
        _blank(contentStart, _i, strings: false);
        _i++;
        return;
      }
      if (!isTriple && char == '\n') {
        _blank(contentStart, _i, strings: false);
        return;
      }
      if (!isRaw && char == r'\') {
        _i += 2;
      } else if (!isRaw && char == r'$' && source.startsWith('{', _i + 1)) {
        _i += 2;
        _code(inInterpolation: true);
      } else {
        _i++;
      }
    }
  }

  /// Blanks [start, end). [strings] also blanks the copy that keeps strings.
  void _blank(int start, int end, {required bool strings}) {
    for (var k = start; k < end && k < code.length; k++) {
      if (code[k] == _newline) continue;
      code[k] = _space;
      if (strings) codeWithStrings[k] = _space;
    }
  }

  int _lineOf(int offset) {
    var low = 0;
    var high = _lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }
}

/// Every `.dart` file under [root], sorted by path.
List<ScannedSource> scanDartFiles(String root) {
  final files =
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final file in files) ScannedSource.read(file)];
}
