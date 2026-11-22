// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so
// `dart run pinpoint:bridge` can run it.

import 'dart:async';
import 'dart:io';

/// Why a source lookup failed. [status] is the HTTP status the bridge
/// answers with.
class SourceLookupException implements Exception {
  const SourceLookupException(this.status, this.message);

  /// 400 for bad input, 403 for a path outside the project, 404 for a file
  /// that is not there.
  final int status;
  final String message;

  @override
  String toString() => message;
}

/// The lines of a method, as [SourceLookup.methodLines] found them.
class SourceSnippet {
  const SourceSnippet({
    required this.file,
    required this.start,
    required this.end,
    required this.text,
  });

  /// Relative to the project folder, with `/` separators.
  final String file;

  /// First line, 1-based.
  final int start;

  /// Last line, 1-based.
  final int end;

  final String text;

  Map<String, Object?> toJson() => {
    'file': file,
    'start': start,
    'end': end,
    'text': text,
  };
}

/// Where a type is declared, as [SourceLookup.declaration] found it.
class SourceDeclaration {
  const SourceDeclaration({
    required this.type,
    required this.file,
    required this.line,
  });

  final String type;

  /// Relative to the project folder, with `/` separators.
  final String file;

  /// 1-based.
  final int line;

  Map<String, Object?> toJson() => {'type': type, 'file': file, 'line': line};
}

/// Reads the app's own source for the state lens:
/// the lines of the method around a file and line, and where a class is
/// declared. Only `.dart` files inside the project folder; nothing outside
/// it is ever read.
class SourceLookup {
  /// [root] is the project folder (the one that holds `.pinpoint/`).
  /// [reader] replaces the file read, for tests.
  SourceLookup(this.root, {Future<String> Function(File file)? reader})
    : _read = reader ?? ((file) => file.readAsString());

  final Directory root;
  final Future<String> Function(File file) _read;

  /// The most text [methodLines] returns.
  static const int maxBytes = 4 * 1024;

  /// The most lines [methodLines] looks up for a method start.
  static const int maxBefore = 100;

  /// The most lines a snippet spans.
  static const int maxLines = 200;

  /// The folder after its symbolic links are resolved. Paths are checked
  /// against this, so `/var/…` and `/private/var/…` agree on macOS.
  Future<String> _realRoot() async {
    try {
      return await root.resolveSymbolicLinks();
    } on FileSystemException {
      throw const SourceLookupException(404, 'The project folder is missing');
    }
  }

  // ---------------------------------------------------------------- methods

  /// The lines of the method that holds [line] (1-based) in [file].
  ///
  /// [file] may be an absolute path inside the project, a path relative to
  /// it, a `file:` URI, or `package:<app>/…` for a file in `lib/` (the app's
  /// name is the `name:` of `pubspec.yaml`).
  ///
  /// Method start heuristic: walk up from [line], at most [before] lines,
  /// to the nearest line that looks like a method, function, getter, setter
  /// or constructor header (a name with `(`, or `get`/`set`, ending in `{`,
  /// `=>`, or an open `(`; not a control statement and not a call such as
  /// `setState(() {`) at an indent equal to or lower than the line's; with
  /// no such line, start [before] lines up.
  /// End: the statement that holds [line] starts after a line that ends in
  /// `;`, `{` or `}`; it ends at the first line from [line] on where the
  /// brackets are back to the level at its start and the line ends in `;`
  /// or `}`. Text is cut at [maxBytes] or [maxLines] lines.
  Future<SourceSnippet> methodLines(
    String file,
    int line, {
    int before = 15,
  }) async {
    if (line < 1) {
      throw const SourceLookupException(400, 'line must be 1 or more');
    }
    if (before < 0) {
      throw const SourceLookupException(400, 'before must be 0 or more');
    }
    before = before > maxBefore ? maxBefore : before;
    final resolved = await _resolve(file);
    final lines = (await _read(resolved.file)).split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (line > lines.length) {
      throw SourceLookupException(
        400,
        '${resolved.relative} has ${lines.length} lines, not $line',
      );
    }
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].endsWith('\r')) {
        lines[i] = lines[i].substring(0, lines[i].length - 1);
      }
    }
    final start = _methodStart(lines, line - 1, before);
    var end = _statementEnd(lines, start, line - 1);
    if (end - start + 1 > maxLines) end = start + maxLines - 1;
    var text = '';
    var last = start;
    for (var i = start; i <= end; i++) {
      final next = i == start ? lines[i] : '$text\n${lines[i]}';
      if (next.length > maxBytes) {
        if (i == start) text = lines[i].substring(0, maxBytes);
        break;
      }
      text = next;
      last = i;
    }
    return SourceSnippet(
      file: resolved.relative,
      start: start + 1,
      end: last + 1,
      text: text,
    );
  }

  static final RegExp _control = RegExp(
    r'^(?:if|else|for|while|switch|catch|try|finally|do|return|await|throw|'
    r'case|default|new|assert|yield|on|with|super|this)\b',
  );
  static final RegExp _getSet = RegExp(r'(?:^|\s)(?:get|set)\s+[A-Za-z_$]');
  static final RegExp _namedCall = RegExp(
    r'^([^=(]*?)([A-Za-z_$][\w$.]*)\s*(?:<.*>)?\s*\(',
  );

  static final RegExp _typeLead = RegExp(r'^[\w$<>?,\[\]\s.]*$');

  /// Whether [text] looks like the header of a method, function, getter,
  /// setter or constructor.
  static bool _isHeader(String text) {
    final line = _code(text).trim();
    if (line.isEmpty || line.startsWith('}') || line.startsWith('@')) {
      return false;
    }
    if (_control.hasMatch(line)) return false;
    final opens =
        line.endsWith('{') || line.endsWith('(') || line.contains('=>');
    if (!opens) return false;
    if (_getSet.hasMatch(line)) return true;
    final call = _namedCall.firstMatch(line);
    if (call == null) return false;
    final lead = call[1]!.trim();
    if (lead.isNotEmpty) {
      // A return type or a modifier before the name: a declaration. Not
      // `child: Bar(`, a named argument.
      return _typeLead.hasMatch(lead);
    }
    // One token: a constructor, or a call such as `setState(() {`. A
    // header's parentheses close on its line; a call that opens a closure
    // does not.
    return _depth(line) <= 0 && (line.endsWith('{') || line.contains('=>'));
  }

  static int _methodStart(List<String> lines, int index, int before) {
    final indent = _indentOf(lines[index]);
    final floor = index - before < 0 ? 0 : index - before;
    for (var i = index; i >= floor; i--) {
      if (lines[i].trim().isEmpty) continue;
      if (_indentOf(lines[i]) > indent) continue;
      if (_isHeader(lines[i])) return i;
    }
    return floor;
  }

  static int _statementEnd(List<String> lines, int start, int index) {
    // Bracket depth at the start of each line from the method start.
    final before = <int>[0];
    for (var i = start; i < index; i++) {
      before.add(before.last + _depth(lines[i]));
    }
    // The statement that holds the line starts after a line that ends in
    // `;`, `{` or `}`; with the header asked for, it is the method.
    var first = index;
    while (first > start + 1 && !_endsStatement(lines, first - 1)) {
      first--;
    }
    if (index == start) first = start;
    final base = before[first - start];
    var depth = before[index - start];
    for (var i = index; i < lines.length; i++) {
      depth += _depth(lines[i]);
      final trimmed = _code(lines[i]).trimRight();
      if (depth <= base && (trimmed.endsWith(';') || trimmed.endsWith('}'))) {
        return i;
      }
      if (i - index > maxLines) return i;
    }
    return lines.length - 1;
  }

  /// Whether the last line of code up to and including [index] (blank and
  /// comment lines left out) ends a statement or opens or closes a block.
  static bool _endsStatement(List<String> lines, int index) {
    for (var i = index; i >= 0; i--) {
      final code = _code(lines[i]).trim();
      if (code.isEmpty) continue;
      return code.endsWith(';') || code.endsWith('{') || code.endsWith('}');
    }
    return true;
  }

  static int _indentOf(String line) {
    var n = 0;
    while (n < line.length && (line[n] == ' ' || line[n] == '\t')) {
      n++;
    }
    return n;
  }

  static final RegExp _strings = RegExp(
    r'''r?'(?:\\.|[^'\\])*'|r?"(?:\\.|[^"\\])*"''',
  );

  /// [line] with string literals and a trailing `//` comment taken out, so
  /// brackets inside them are not counted. Strings that run over several
  /// lines are not handled.
  static String _code(String line) {
    final stripped = line.replaceAll(_strings, "''");
    final comment = stripped.indexOf('//');
    return comment < 0 ? stripped : stripped.substring(0, comment);
  }

  /// Opening minus closing brackets on [line].
  static int _depth(String line) {
    var depth = 0;
    for (final unit in _code(line).codeUnits) {
      switch (unit) {
        case 0x28 || 0x5B || 0x7B: // ( [ {
          depth++;
        case 0x29 || 0x5D || 0x7D: // ) ] }
          depth--;
      }
    }
    return depth;
  }

  // ------------------------------------------------------------ declaration

  static final RegExp _declaration = RegExp(
    r'^(?:(?:abstract|base|final|sealed|interface)\s+)*'
    r'(?:mixin\s+class|class|mixin|enum|extension\s+type(?:\s+const)?)\s+'
    r'([A-Za-z_$][\w$]*)',
  );
  static final RegExp _identifier = RegExp(r'^[A-Za-z_$][\w$]*$');

  final Map<String, _IndexedFile> _index = <String, _IndexedFile>{};

  /// Where the class, mixin, enum or extension type [typeName] is declared
  /// in `lib/`, or null. A generic name such as `Foo<T>` is looked up as
  /// `Foo`.
  ///
  /// A declaration is a line that starts in column 0 with the keyword
  /// (after the modifiers `abstract`, `base`, `final`, `sealed`,
  /// `interface`) and then the name on a word boundary. Generated files
  /// (`*.g.dart`, `*.freezed.dart`) are skipped. The first match in file
  /// path order wins. Each file is read once; it is read again only when
  /// its modification time or size changes.
  Future<SourceDeclaration?> declaration(String typeName) async {
    var name = typeName.trim();
    final generic = name.indexOf('<');
    if (generic >= 0) name = name.substring(0, generic);
    name = name.replaceAll('?', '').trim();
    if (!_identifier.hasMatch(name)) {
      throw SourceLookupException(400, 'Not a type name: $typeName');
    }
    final real = await _realRoot();
    final lib = Directory('$real/lib');
    if (!await lib.exists()) return null;
    final paths = <String>[];
    await for (final entity in lib.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart') ||
          path.endsWith('.g.dart') ||
          path.endsWith('.freezed.dart')) {
        continue;
      }
      paths.add(path);
    }
    paths.sort();
    _index.removeWhere((path, _) => !paths.contains(path));
    for (final path in paths) {
      final file = File(path);
      final FileStat stat;
      try {
        stat = await file.stat();
      } on FileSystemException {
        continue;
      }
      var indexed = _index[path];
      if (indexed == null ||
          indexed.modified != stat.modified ||
          indexed.size != stat.size) {
        try {
          indexed = _IndexedFile(
            stat.modified,
            stat.size,
            _declarationsOf(await _read(file)),
          );
        } on FileSystemException {
          continue;
        }
        _index[path] = indexed;
      }
      final line = indexed.declarations[name];
      if (line != null) {
        return SourceDeclaration(
          type: name,
          file: _relative(real, path),
          line: line,
        );
      }
    }
    return null;
  }

  static Map<String, int> _declarationsOf(String source) {
    final found = <String, int>{};
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final match = _declaration.firstMatch(lines[i]);
      if (match != null) found.putIfAbsent(match[1]!, () => i + 1);
    }
    return found;
  }

  // ------------------------------------------------------------------ paths

  static String _relative(String realRoot, String path) {
    final prefix = realRoot.endsWith('/') ? realRoot : '$realRoot/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  /// [text] with `.` and `..` segments folded, without touching the disk.
  static String _normalize(String text) {
    final absolute = text.startsWith('/');
    final out = <String>[];
    for (final part in text.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) {
          out.removeLast();
        } else if (!absolute) {
          out.add('..');
        }
      } else {
        out.add(part);
      }
    }
    return '${absolute ? '/' : ''}${out.join('/')}';
  }

  static bool _inside(String realRoot, String path) =>
      path == realRoot || path.startsWith('$realRoot/');

  Future<({File file, String relative})> _resolve(String input) async {
    var text = input.trim();
    if (text.isEmpty) {
      throw const SourceLookupException(400, 'file is empty');
    }
    final real = await _realRoot();
    final String lexical;
    if (text.startsWith('package:')) {
      final slash = text.indexOf('/');
      final package = slash < 0 ? '' : text.substring(8, slash);
      final app = await _packageName();
      if (slash < 0 || package != app) {
        throw SourceLookupException(
          403,
          'Only package:$app/ files are inside the project: $input',
        );
      }
      lexical = _normalize('$real/lib/${text.substring(slash + 1)}');
    } else {
      if (text.startsWith('file:')) {
        try {
          text = Uri.parse(text).toFilePath();
        } on Object {
          throw SourceLookupException(400, 'Not a file URI: $input');
        }
      }
      lexical = text.startsWith('/')
          ? _normalize(text)
          : _normalize('$real/$text');
    }
    // The root itself may be reached by a symbolic link (macOS /var), so an
    // absolute path is also tried against the folder as given.
    final given = _normalize(root.absolute.path);
    var candidate = lexical;
    if (!_inside(real, candidate) && _inside(given, candidate)) {
      candidate = '$real${candidate.substring(given.length)}';
    }
    if (!_inside(real, candidate)) {
      throw SourceLookupException(403, 'Outside the project: $input');
    }
    if (!candidate.endsWith('.dart')) {
      throw SourceLookupException(400, 'Only .dart files: $input');
    }
    final String resolved;
    try {
      resolved = await File(candidate).resolveSymbolicLinks();
    } on FileSystemException {
      throw SourceLookupException(404, 'No such file: $input');
    }
    // A link inside the project may point outside it.
    if (!_inside(real, resolved)) {
      throw SourceLookupException(403, 'Outside the project: $input');
    }
    if (await FileSystemEntity.type(resolved) != FileSystemEntityType.file) {
      throw SourceLookupException(404, 'No such file: $input');
    }
    return (file: File(resolved), relative: _relative(real, resolved));
  }

  Future<String?> _packageName() async {
    try {
      final pubspec = await File('${root.path}/pubspec.yaml').readAsString();
      return RegExp(
        r'''^name:\s*['"]?([\w.-]+)''',
        multiLine: true,
      ).firstMatch(pubspec)?[1];
    } on FileSystemException {
      return null;
    }
  }
}

class _IndexedFile {
  const _IndexedFile(this.modified, this.size, this.declarations);

  final DateTime modified;
  final int size;

  /// Name -> 1-based line.
  final Map<String, int> declarations;
}
