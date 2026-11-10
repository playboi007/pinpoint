// Plain Dart: no `dart:ui` and no `package:flutter`, so the bridge (`bin/`)
// can use it too.

/// Where a widget's constructor call appears in source.
///
/// Read from the widget, so after an edit and a hot reload the new widget
/// instance carries the new line. Anything stored across edits (pins in
/// Milestone 8) must re-match by file, widget type and nearest line, not by
/// line alone.
class SourceLocation {
  const SourceLocation({
    required this.uri,
    required this.line,
    required this.column,
    this.name,
  });

  /// The file as the inspector reports it: a `file:///` URI on the VM and on
  /// web (docs/api-notes.md, item 2).
  final String uri;

  /// 1-based.
  final int line;

  /// 1-based.
  final int column;

  /// The constructor name, for example `Text`. Null when not reported.
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is SourceLocation &&
      other.uri == uri &&
      other.line == line &&
      other.column == column &&
      other.name == name;

  @override
  int get hashCode => Object.hash(uri, line, column, name);

  @override
  String toString() => '$uri:$line:$column';
}

/// [input] as a plain path with forward slashes, for comparing.
///
/// - `file:///…` (the normal case): the path, percent escapes decoded.
/// - A Windows drive (`file:///C:/…` or `C:\…`): `C:/…`.
/// - `org-dartlang-app:///name.dart`, seen only in `flutter test --platform
///   chrome`: `name.dart`. The directory is unknown; do not resolve it
///   against a project root.
/// - `package:…` URIs and plain paths: unchanged.
///
/// A trailing slash is dropped.
String normalizeSourcePath(String input) {
  var path = input.trim();
  if (path.startsWith('file:') || path.startsWith(_webTestScheme)) {
    final uri = Uri.tryParse(path);
    if (uri != null) {
      try {
        path = Uri.decodeComponent(uri.path);
      } on ArgumentError {
        path = uri.path;
      }
      if (uri.scheme == 'org-dartlang-app') {
        path = path.replaceFirst(RegExp('^/+'), '');
      }
    }
  }
  path = path.replaceAll(r'\', '/');
  if (RegExp('^/[A-Za-z]:/').hasMatch(path)) path = path.substring(1);
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

const String _webTestScheme = 'org-dartlang-app:';

/// Whether [path] is a generated file (`.g.dart`, `.freezed.dart`).
///
/// Generated files count as local, but the default selection passes over
/// them: nobody edits them by hand.
bool isGeneratedSource(String path) =>
    path.endsWith('.g.dart') || path.endsWith('.freezed.dart');

/// Decides which source files belong to the project, and how to show them.
///
/// The inspector's own `createdByLocalProject` flag is not used: with no
/// root directories registered (a plain `flutter run`), it calls everything
/// outside `packages/flutter/` local, pub-cache packages included
/// (docs/api-notes.md, item 1).
class SourcePaths {
  const SourcePaths({
    String? projectRoot,
    this.localPathHints = const <String>[],
    this.caseSensitive = false,
  }) : _rootSetting = projectRoot;

  final String? _rootSetting;

  /// Paths (or `package:` prefixes) that count as local even outside
  /// [projectRoot], for monorepo packages. A path dependency looks external
  /// unless it is listed here.
  final List<String> localPathHints;

  /// Whether path case matters. False on macOS and Windows, whose file
  /// systems ignore case by default; true on Linux.
  final bool caseSensitive;

  /// The project's root directory, or null when not set (an empty string,
  /// as `String.fromEnvironment` gives for a missing define, is not set).
  String? get projectRoot {
    final root = _rootSetting;
    return root == null || root.isEmpty ? null : normalizeSourcePath(root);
  }

  /// Path fragments of the Flutter SDK, the Dart SDK and the pub cache
  /// (`.pub-cache` on macOS and Linux, `Pub/Cache` on Windows). Compared
  /// without case. Checked even under [projectRoot]: an SDK or a cache can
  /// sit inside the project (for example fvm's `.fvm/flutter_sdk` link).
  static const List<String> _external = <String>[
    '/packages/flutter/',
    '/.pub-cache/',
    '/pub/cache/',
    '/bin/cache/',
  ];

  /// Whether [file] (a creation-location URI or a path) is the project's
  /// own source. In order:
  ///
  /// 1. A match in [localPathHints] is local.
  /// 2. The web test entrypoint (`org-dartlang-app:`) is local: it is the
  ///    app's own file with its directory dropped.
  /// 3. A `package:` URI is not: which package is the app cannot be told.
  /// 4. SDK and pub-cache paths are not.
  /// 5. With a [projectRoot], local means under it. Without one, everything
  ///    left is local.
  bool isLocal(String file) {
    final path = normalizeSourcePath(file);
    final compared = _fold(path);
    for (final hint in localPathHints) {
      if (_matchesHint(compared, _fold(normalizeSourcePath(hint)))) {
        return true;
      }
    }
    if (file.trimLeft().startsWith(_webTestScheme)) return true;
    if (path.startsWith('package:')) return false;
    final lower = path.toLowerCase();
    if (_external.any(lower.contains)) return false;
    final root = projectRoot;
    return root == null || _isUnder(compared, _fold(root));
  }

  /// [file] relative to [projectRoot] when under it, else the normalized
  /// path.
  String relativePath(String file) {
    final path = normalizeSourcePath(file);
    final root = projectRoot;
    if (root == null || !_isUnder(_fold(path), _fold(root))) return path;
    return path.substring(root.length + 1);
  }

  /// A short form of [file] for labels: relative to [projectRoot] when
  /// under it. Otherwise from the package directory, for example
  /// `example/lib/screens/form.dart`, or the whole path when there is no
  /// `lib`, `test`, `bin` or `web` directory in it.
  String displayPath(String file) {
    final path = normalizeSourcePath(file);
    final root = projectRoot;
    if (root != null && _isUnder(_fold(path), _fold(root))) {
      return path.substring(root.length + 1);
    }
    final segments = path.split('/');
    for (var i = segments.length - 2; i >= 1; i--) {
      if (_packageDirs.contains(segments[i]) && segments[i - 1].isNotEmpty) {
        return segments.sublist(i - 1).join('/');
      }
    }
    return path;
  }

  /// For example `lib/widgets/save_bar.dart:42`.
  String label(SourceLocation location) =>
      '${displayPath(location.uri)}:${location.line}';

  static const Set<String> _packageDirs = <String>{
    'lib',
    'test',
    'bin',
    'web',
    'integration_test',
  };

  String _fold(String path) => caseSensitive ? path : path.toLowerCase();

  /// Under [directory], on a directory boundary: `/a/app` holds
  /// `/a/app/lib`, not `/a/app2/lib`.
  static bool _isUnder(String path, String directory) =>
      path.length > directory.length &&
      path.startsWith(directory) &&
      path[directory.length] == '/';

  /// A hint matches as a prefix (`/repo/packages/ui`, `package:ui`) or, when
  /// relative, as a path fragment (`packages/ui`). Both on a directory
  /// boundary.
  static bool _matchesHint(String path, String hint) {
    if (hint.isEmpty) return false;
    if (path == hint || _isUnder(path, hint)) return true;
    if (hint.startsWith('/') || hint.contains(':')) return false;
    return path.contains('/$hint/');
  }
}
