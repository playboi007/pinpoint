import 'package:flutter/foundation.dart';

import '../model/source_location.dart';

/// One stack frame that is the project's own code (PLAN-v3 Milestone 21).
@immutable
class ProjectFrame {
  const ProjectFrame({
    required this.file,
    required this.line,
    required this.column,
    required this.method,
  });

  /// Project-relative when the frame is a `file:` URI under the project
  /// root; a `package:name/path.dart` URI for app code that the VM or the
  /// web compiler names by package. The bridge maps that to `lib/path.dart`.
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
/// runner, state packages and Pinpoint itself. A frame from any other
/// `package:` URI counts as the project's, because the VM and the web
/// compiler name an app's own `lib/` files `package:<app>/...` and the
/// app's package name is not known here.
///
/// One list, so a missing package is one line to add. A dependency that is
/// not listed and calls back into the app (a router, an HTTP client) can
/// show as the first project frame; `PinPointConfig.localPathHints` does
/// not change this (it is about creation locations).
const Set<String> infrastructurePackages = <String>{
  'flutter',
  'flutter_test',
  'flutter_web_plugins',
  'flutter_localizations',
  'integration_test',
  'pinpoint',
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

/// The first frame of [stack] that is the project's own code, or null.
///
/// Dart frames, [infrastructurePackages] and files outside the project
/// ([SourcePaths.isLocal]) are skipped. The parser is Flutter's
/// [StackFrame]: it reads the VM format (`#3  Foo.bar (package:app/a.dart:10:5)`)
/// and the web formats. A line it cannot read (an `elided` line, a frame
/// with no location) is skipped, never an error.
ProjectFrame? firstProjectFrame(
  StackTrace stack,
  SourcePaths paths, {
  int maxLines = 200,
}) => firstProjectFrameIn(stack.toString(), paths, maxLines: maxLines);

/// Same as [firstProjectFrame], for the text of a stack: Flutter's
/// `debugPrintStack` hands the stack over as one string.
ProjectFrame? firstProjectFrameIn(
  String stack,
  SourcePaths paths, {
  int maxLines = 200,
}) {
  var seen = 0;
  for (final raw in stack.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (++seen > maxLines) break;
    if (!line.startsWith('#')) {
      // The web formats have no `#n`: DDC (`file 12:3  member`) and wasm
      // (`at M.Class.member closure at file:12:3 (wasm url)`).
      final web = _webDebugFrame(line, paths) ?? _wasmFrame(line, paths);
      if (web != null) return web;
      continue;
    }
    final StackFrame? frame;
    try {
      // `fromStackTraceLine` asserts on a line that is not a frame.
      frame = StackFrame.fromStackTraceLine(line);
    } catch (_) {
      continue;
    }
    if (frame == null ||
        frame.line < 0 && frame.packageScheme.isEmpty ||
        frame.packageScheme == '<unknown>') {
      // No file: a frame of a build that has no debug info (wasm, profile).
      continue;
    }
    final uri = _uriOf(frame);
    if (uri == null || !_isProject(frame, uri, paths)) continue;
    final method = frame.className.isEmpty
        ? frame.method
        : frame.method.isEmpty
        ? frame.className
        : '${frame.className}.${frame.method}';
    return ProjectFrame(
      file: frame.packageScheme == 'package' ? uri : paths.relativePath(uri),
      line: frame.line < 0 ? 0 : frame.line,
      column: frame.column < 0 ? null : frame.column,
      method: method,
    );
  }
  return null;
}

// `file line:col  member`, as DDC prints a frame: `package:app/a.dart 12:3
// fetchDialog`, `dart-sdk/lib/async/zone.dart 710:7  run`, or for a test
// file only its name, `a_test.dart 197:5  toggle`.
//
// Flutter's own `StackFrame` reads this format too, but it throws the file
// away for every frame that is not a `package:` one (its path stays
// `<unknown>`), and the class name is not in it. Checked in Chrome (api-notes
// item 34).
final RegExp _webDebugLine = RegExp(r'^(\S+) (\d+):(\d+)\s+(.+)$');

// The compiled module of a package, as a URL: `http://host:1234/packages/app/a.dart`.
final RegExp _packageUrl = RegExp(r'^https?://[^/]+/packages/([^/]+)/(.+)$');

/// [line] as a project frame when it is a DDC frame in the project's code,
/// else null (not a frame of that format, or not the project's).
ProjectFrame? _webDebugFrame(String line, SourcePaths paths) {
  final match = _webDebugLine.firstMatch(line);
  if (match == null) return null;
  var file = match.group(1)!;
  if (file.startsWith('dart:') ||
      file.startsWith('dart-sdk/') ||
      file.contains('/dart-sdk/')) {
    return null;
  }
  final url = _packageUrl.firstMatch(file);
  if (url != null) {
    file = 'package:${url.group(1)}/${url.group(2)}';
  } else if (file.startsWith('packages/')) {
    // `packages/app/a.dart`: the same package, without its scheme.
    file = 'package:${file.substring('packages/'.length)}';
  } else if (file.startsWith('http://') || file.startsWith('https://')) {
    // Compiled output that is no package: nothing to name.
    return null;
  }
  final String shown;
  if (file.startsWith('package:')) {
    final slash = file.indexOf('/');
    final package = slash < 0 ? '' : file.substring('package:'.length, slash);
    if (!paths.isLocal(file) && infrastructurePackages.contains(package)) {
      return null;
    }
    shown = file;
  } else if (file.contains(':') || file.startsWith('/')) {
    // `file:` and `org-dartlang-app:` URIs, and absolute paths.
    if (!paths.isLocal(file)) return null;
    shown = paths.relativePath(file);
  } else {
    // A bare relative name: a test file in `flutter test --platform chrome`.
    shown = file;
  }
  return ProjectFrame(
    file: shown,
    line: int.parse(match.group(2)!),
    column: int.parse(match.group(3)!),
    method: match.group(4)!,
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

ProjectFrame? _wasmFrame(String line, SourcePaths paths) {
  final match = _wasmLine.firstMatch(line);
  if (match == null) return null;
  final file = match.group(2)!;
  if (file.startsWith('org-dartlang-sdk:') || file.contains('/dart-sdk/')) {
    return null;
  }
  final String shown;
  if (file.startsWith('package:')) {
    final slash = file.indexOf('/');
    final package = slash < 0 ? '' : file.substring('package:'.length, slash);
    if (!paths.isLocal(file) && infrastructurePackages.contains(package)) {
      return null;
    }
    shown = file;
  } else {
    if (!paths.isLocal(file)) return null;
    shown = paths.relativePath(file);
  }
  // `M.main closure`, `M.closure wrapper`: the member, as DDC names it.
  var member = match.group(1)!.replaceFirst(RegExp(r'^M\.'), '');
  member = member.replaceFirst(RegExp(r'\s+closure( wrapper)?$'), '');
  return ProjectFrame(
    file: shown,
    line: int.parse(match.group(3)!),
    column: int.parse(match.group(4)!),
    method: member,
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

bool _isProject(StackFrame frame, String uri, SourcePaths paths) {
  switch (frame.packageScheme) {
    case 'dart':
      return false;
    case 'package':
      return paths.isLocal(uri) ||
          !infrastructurePackages.contains(frame.package);
    default:
      return paths.isLocal(uri);
  }
}
