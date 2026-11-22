import 'package:flutter/foundation.dart';

import '../model/source_location.dart';

/// One stack frame that is the project's own code.
@immutable
class ProjectFrame {
  const ProjectFrame({
    required this.file,
    required this.line,
    required this.column,
    required this.method,
  });

  /// Project-relative (`lib/src/x.dart`) when the frame matches one of the
  /// app's known files or is a `file:` URI under the project root; else a
  /// `package:name/path.dart` URI for app code that the VM or the web
  /// compiler names by package. The bridge maps that to `lib/path.dart`.
  final String file;

  /// 1-based; 0 when the frame has none.
  final int line;

  /// 1-based; null when the frame has none.
  final int? column;

  /// `Class.method`, or `method` for a top-level function. Closures lose
  /// their `<anonymous closure>` suffix, as in Flutter's `StackFrame`.
  final String method;

  /// `file:line:column`, as the trace's `source` field holds it.
  String get where => '$file:$line${column == null ? '' : ':$column'}';

  @override
  String toString() => '$where $method';
}

/// Packages whose frames are never "the project": the framework, the test
/// runner, state packages and Pinpoint itself. Used when the app's own
/// files are not known ([ProjectFiles.isEmpty]), and always as a first
/// check, because a framework frame must never win over a file match.
///
/// One list, so a missing package is one line to add. A dependency that is
/// not listed and calls back into the app (a router, an HTTP client) can
/// show as the first project frame while the file set is empty;
/// `PinPointConfig.localPathHints` does not change this (it is about
/// creation locations).
const Set<String> infrastructurePackages = <String>{
  'flutter',
  'flutter_test',
  'flutter_web_plugins',
  'flutter_localizations',
  'integration_test',
  'pinpoint',
  'listen',
  'provider',
  'riverpod',
  'flutter_riverpod',
  'hooks_riverpod',
  'bloc',
  'flutter_bloc',
  'get_it',
  'test_api',
  'test_core',
  'test',
  'matcher',
  'stack_trace',
  'async',
  'fake_async',
  'meta',
  'collection',
  'vector_math',
  'characters',
  'leak_tracker',
  'leak_tracker_flutter_testing',
};

/// The app's own source files, as the widgets' creation locations name them
/// (`SourceIndex.localFiles`). A stack frame is the project's when its file
/// is one of these.
///
/// A compiled app names a file in many ways: `package:app/a/b.dart` (VM and
/// DDC), `packages/app/a/b.dart` and `lib/a/b.dart` (DDC in Chrome),
/// `file:///.../lib/a/b.dart` (VM) or `org-dartlang-app:///a/b.dart` (wasm
/// and the web test runner). A creation location is a `file:///` URI. So a
/// frame is matched on the path after the package name, or after `lib/`,
/// against the path after each `lib/` of a known file (api-notes item 34).
///
/// A file that creates no widget (a model, a repository) is not in the set.
/// Its package is: when a frame of `package:app/...` matches, `app` is
/// remembered and the files of `app` that no widget creation names count
/// too ([knowsPackage]).
class ProjectFiles {
  ProjectFiles(Iterable<String> uris, this.paths) {
    for (final uri in uris) {
      final path = normalizeSourcePath(uri);
      final relative = paths.relativePath(uri);
      final underRoot = paths.projectRoot != null && relative != path;
      final tails = _libTails(path);
      // What the bridge can open: relative to the project root, or from the
      // package's `lib/`.
      final shown = underRoot
          ? relative
          : (tails.isEmpty ? path : 'lib/${tails.last}');
      void add(String key) => _byKey.putIfAbsent(_fold(key), () => shown);
      add(path);
      if (underRoot) add(relative);
      tails.forEach(add);
      final slash = path.lastIndexOf('/');
      _byName.putIfAbsent(_fold(path.substring(slash + 1)), () => shown);
    }
  }

  /// A set that knows no file: the deny list decides.
  static final ProjectFiles none = ProjectFiles(
    const <String>[],
    const SourcePaths(),
  );

  final SourcePaths paths;

  final Map<String, String> _byKey = <String, String>{};
  final Map<String, String> _byName = <String, String>{};
  final Set<String> _packages = <String>{};

  /// Whether no file is known.
  bool get isEmpty => _byKey.isEmpty;

  /// Files known (one per distinct file).
  int get length => _byName.length;

  /// Whether a frame of package [name] already matched a file.
  bool knowsPackage(String name) => _packages.contains(name);

  String _fold(String text) => paths.caseSensitive ? text : text.toLowerCase();

  // `a/b.dart` for `/x/lib/a/b.dart`, one per `lib/` in the path.
  static List<String> _libTails(String path) {
    final tails = <String>[];
    var from = 0;
    while (true) {
      final at = path.indexOf('lib/', from);
      if (at < 0) break;
      if (at == 0 || path[at - 1] == '/') tails.add(path.substring(at + 4));
      from = at + 4;
    }
    return tails;
  }

  /// The project path (as the bridge can open it) of the file that [file]
  /// names, or null when it is not a known file. [file] is a frame's file
  /// in any of the forms above.
  String? match(String file) {
    if (_byKey.isEmpty) return null;
    var path = file;
    String? package;
    if (path.startsWith('package:')) {
      final slash = path.indexOf('/');
      if (slash < 0) return null;
      package = path.substring('package:'.length, slash);
      path = path.substring(slash + 1);
    } else {
      path = normalizeSourcePath(path);
    }
    final candidates = <String>[path];
    if (path.startsWith('lib/')) candidates.add(path.substring(4));
    for (final candidate in candidates) {
      final shown = _byKey[_fold(candidate)];
      if (shown != null) {
        if (package != null) _packages.add(package);
        return shown;
      }
    }
    if (package == null &&
        !path.contains('/') &&
        !path.contains(':') &&
        path.endsWith('.dart')) {
      // A bare file name: a test file of `flutter test --platform chrome`.
      return _byName[_fold(path)];
    }
    return null;
  }
}

/// The first frame of [stack] that is the project's own code, or null.
///
/// See [ProjectFiles] for what "the project's" means. With a [files] set
/// that knows files, a frame counts when it matches one (or is in a package
/// that matched). With no files known, the deny list decides: Dart, the
/// web engine and the framework ([infrastructurePackages]) are skipped,
/// files outside the project ([SourcePaths.isLocal]) are skipped, the rest
/// counts. The parser is Flutter's [StackFrame] for the VM format
/// (`#3  Foo.bar (package:app/a.dart:10:5)`) and Pinpoint's own for the web
/// formats. A line it cannot read (an `elided` line, a frame with no
/// location) is skipped, never an error.
ProjectFrame? firstProjectFrame(
  StackTrace stack,
  SourcePaths paths, {
  int maxLines = 200,
  ProjectFiles? files,
}) => firstProjectFrameIn(
  stack.toString(),
  paths,
  maxLines: maxLines,
  files: files,
);

/// Same as [firstProjectFrame], for the text of a stack: Flutter's
/// `debugPrintStack` hands the stack over as one string.
ProjectFrame? firstProjectFrameIn(
  String stack,
  SourcePaths paths, {
  int maxLines = 200,
  ProjectFiles? files,
}) {
  final known = files ?? ProjectFiles.none;
  // The first frame of an app package that no known file names: it is the
  // project's when a later frame proves the package is the app's.
  _Raw? pending;
  for (final frame in _parsedFrames(stack, maxLines)) {
    final shown = _shown(frame.file, paths, known);
    if (shown != null) return _settled(pending, known) ?? frame.toFrame(shown);
    if (pending == null && !known.isEmpty && _unmatchedAppPackage(frame.file)) {
      pending = frame;
    }
    if (_settled(pending, known) case final settled?) return settled;
  }
  return null;
}

/// The pending frame as a project frame, once a known file names its package.
ProjectFrame? _settled(_Raw? pending, ProjectFiles known) =>
    pending != null && _knownPackage(pending.file, known)
    ? pending.toFrame(pending.file)
    : null;

/// The frames of the first [maxLines] non-empty lines. Lines that are no
/// frame are skipped but count. A negative cap reads nothing.
Iterable<_Raw> _parsedFrames(String stack, int maxLines) sync* {
  final lines = stack
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  for (final line in lines.take(maxLines < 0 ? 0 : maxLines)) {
    if (_parse(line) case final frame?) yield frame;
  }
}

class _Raw {
  const _Raw(this.file, this.line, this.column, this.method);

  /// `package:pkg/path` for any package frame, else as the stack gave it.
  final String file;
  final int line;
  final int? column;
  final String method;

  ProjectFrame toFrame(String shown) =>
      ProjectFrame(file: shown, line: line, column: column, method: method);
}

_Raw? _parse(String line) {
  if (!line.startsWith('#')) {
    // The web formats have no `#n`: DDC (`file 12:3  member`) and wasm
    // (`at M.Class.member closure at file:12:3 (wasm url)`).
    return _webDebugFrame(line) ?? _wasmFrame(line);
  }
  final StackFrame? frame;
  try {
    // `fromStackTraceLine` asserts on a line that is not a frame.
    frame = StackFrame.fromStackTraceLine(line);
  } catch (_) {
    return null;
  }
  if (frame == null ||
      frame.line < 0 && frame.packageScheme.isEmpty ||
      frame.packageScheme == '<unknown>') {
    // No file: a frame of a build that has no debug info (wasm, profile).
    return null;
  }
  final uri = _uriOf(frame);
  if (uri == null) return null;
  final method = switch ((frame.className, frame.method)) {
    ('', final method) => method,
    (final className, '') => className,
    (final className, final method) => '$className.$method',
  };
  return _Raw(
    uri,
    frame.line < 0 ? 0 : frame.line,
    frame.column < 0 ? null : frame.column,
    method,
  );
}

String _packageOf(String file) {
  final slash = file.indexOf('/');
  return slash < 0
      ? file.substring('package:'.length)
      : file.substring('package:'.length, slash);
}

bool _knownPackage(String file, ProjectFiles files) =>
    files.knowsPackage(_packageOf(file));

// A `package:` frame that is not the framework, not Pinpoint and not a
// state package: it can be the app's.
bool _unmatchedAppPackage(String file) =>
    file.startsWith('package:') &&
    !_denied(file) &&
    !infrastructurePackages.contains(_packageOf(file));

/// Files that are never the project, whatever the file set says: Dart's own
/// libraries, the web engine (`lib/_engine/...`, `lib/ui/...`), the
/// Flutter SDK and Pinpoint.
bool _denied(String file) {
  final path = file.toLowerCase();
  return _deniedStarts.any(path.startsWith) || _deniedParts.any(path.contains);
}

const _deniedStarts = [
  'dart:',
  'org-dartlang-sdk:',
  'lib/_',
  'lib/ui/',
  'packages/flutter/',
  'package:flutter/',
  'packages/pinpoint/',
  'package:pinpoint/',
];

const _deniedParts = ['dart-sdk/', 'flutter_web_sdk', 'sky_engine', '_engine/'];

enum _FileKind { denied, package, uri, path }

_FileKind _kindOf(String file) {
  if (_denied(file)) return _FileKind.denied;
  if (file.startsWith('package:')) return _FileKind.package;
  // `file:` and `org-dartlang-app:` URIs, and absolute paths.
  if (file.contains(':') || file.startsWith('/')) return _FileKind.uri;
  // A relative path (`lib/a/b.dart`) or a bare name (a test file).
  return _FileKind.path;
}

/// How [file] is shown when it is the project's, else null.
String? _shown(String file, SourcePaths paths, ProjectFiles files) =>
    switch (_kindOf(file)) {
      _FileKind.denied => null,
      _FileKind.package => _shownPackage(file, paths, files),
      _FileKind.uri =>
        paths.isLocal(file)
            ? files.match(file) ?? paths.relativePath(file)
            : null,
      _FileKind.path => files.isEmpty ? file : files.match(file),
    };

String? _shownPackage(String file, SourcePaths paths, ProjectFiles files) {
  // A path dependency listed in `localPathHints`.
  if (paths.isLocal(file)) return files.match(file) ?? file;
  final package = _packageOf(file);
  if (infrastructurePackages.contains(package)) return null;
  if (files.isEmpty) return file;
  if (files.match(file) case final match?) return match;
  return files.knowsPackage(package) ? file : null;
}

// `file line:col  member`, as DDC prints a frame: `package:app/a.dart 12:3
// fetchDialog`, `dart-sdk/lib/async/zone.dart 710:7  run`,
// `lib/_engine/engine/platform_dispatcher.dart 1733:5  invoke` or for a test
// file only its name, `a_test.dart 197:5  toggle`.
//
// Flutter's own `StackFrame` reads this format too, but it throws the file
// away for every frame that is not a `package:` one (its path stays
// `<unknown>`), and the class name is not in it. Checked in Chrome (api-notes
// item 34).
final RegExp _webDebugLine = RegExp(r'^(\S+) (\d+):(\d+)\s+(.+)$');

// The compiled module of a package, as a URL: `http://host:1234/packages/app/a.dart`.
final RegExp _packageUrl = RegExp(r'^https?://[^/]+/packages/([^/]+)/(.+)$');

// A file as the web formats name it, in one form: `package:pkg/path` for any
// package (a `packages/pkg/path` path and a compiled-module URL too), the
// text as given for the rest. Null for compiled output that is no package.
String? _webFile(String location) {
  // Older DDC stacks can name the JavaScript module instead of the Dart file.
  final file = location.endsWith('.dart.js')
      ? location.substring(0, location.length - '.js'.length)
      : location;
  final url = _packageUrl.firstMatch(file);
  if (url != null) return 'package:${url.group(1)}/${url.group(2)}';
  if (file.startsWith('packages/')) {
    // `packages/app/a.dart`: the same package, without its scheme.
    return 'package:${file.substring('packages/'.length)}';
  }
  if (file.contains('/dart-sdk/')) return file;
  if (file.startsWith('http://') || file.startsWith('https://')) return null;
  return file;
}

_Raw? _webDebugFrame(String line) {
  final match = _webDebugLine.firstMatch(line);
  if (match == null) return null;
  final file = _webFile(match.group(1)!);
  if (file == null) return null;
  return _Raw(
    file,
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    match.group(4)!,
  );
}

// A wasm frame. Only a closure (or an inlined call) has a place in source:
// `at M.main closure at org-dartlang-app:///a_test.dart:120:62 inner (http://
// host/main.dart.wasm:wasm-function[1]:0x1)`. A method has its name only
// (`at M._SpinnerState.toggle (http://host/main.dart.wasm:...)`), so a frame
// of this format is the project's only when it has a place and it is in the
// project's files. Checked in Chrome with `--wasm` (api-notes item 34).
final RegExp _wasmLine = RegExp(
  r'^at\s+(.+?)\s+at\s+(\S+?):(\d+):(\d+)(?:\s|$)',
);

_Raw? _wasmFrame(String line) {
  final match = _wasmLine.firstMatch(line);
  if (match == null) return null;
  final file = _webFile(match.group(2)!);
  if (file == null) return null;
  // `M.main closure`, `M.closure wrapper`: the member, as DDC names it.
  var member = match.group(1)!.replaceFirst(RegExp(r'^M\.'), '');
  member = member.replaceFirst(RegExp(r'\s+closure( wrapper)?$'), '');
  return _Raw(
    file,
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    member,
  );
}

/// The frame's file as a URI string, or null for a frame with no file.
String? _uriOf(StackFrame frame) {
  switch (frame.packageScheme) {
    case '':
      return null;
    case 'package':
      return 'package:${frame.package}/${frame.packagePath}';
    case 'dart':
      return 'dart:${frame.package}/${frame.packagePath}';
    case 'file':
      return 'file://${frame.packagePath}';
    default:
      // `org-dartlang-app:` (web test entrypoint) and http(s) URLs of the
      // web compiler's output.
      return '${frame.packageScheme}:${frame.packagePath}';
  }
}
