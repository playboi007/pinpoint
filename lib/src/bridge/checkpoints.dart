// Plain Dart with `dart:io` (`Process`): no `dart:ui` and no
// `package:flutter`, so `dart run pinpoint:bridge` can run it. Never
// exported from pinpoint.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How [Checkpoints.revert] ended.
enum RevertOutcome {
  /// Every chosen file went back.
  clean,

  /// A chosen file changed since: no file was changed.
  conflict,

  /// Git failed for another reason (a timeout, a bad tree): no file was
  /// changed.
  failed,
}

/// One file in a [Checkpoints.diff]. [path] is relative to the git top
/// level, not to the bridge's folder (see [Checkpoints]).
class FileDiff {
  const FileDiff(this.path, this.added, this.removed);

  final String path;

  /// Lines added; null for a binary file.
  final int? added;

  /// Lines removed; null for a binary file.
  final int? removed;

  Map<String, Object?> toJson() => {
    'path': path,
    'added': added,
    'removed': removed,
  };
}

/// What [Checkpoints.revert] did.
class RevertResult {
  const RevertResult(
    this.outcome, {
    this.reverted = const <String>[],
    this.conflicts = const <String>[],
    this.error,
  });

  final RevertOutcome outcome;

  /// The files that went back (empty unless [RevertOutcome.clean]).
  final List<String> reverted;

  /// The files that no longer fit the patch (for [RevertOutcome.conflict]).
  final List<String> conflicts;

  /// What git said, for [RevertOutcome.failed].
  final String? error;
}

/// Git trees of the working folder at chosen moments, kept under
/// `refs/pinpoint/<noteId>/<label>`, and the undo of the difference between
/// two of them (PLAN-v3 Milestone 20).
///
/// **Git safety (PLAN-v3 engineering rule 1).** This class never runs
/// `checkout`, `reset`, `stash` or `commit` on a branch, never moves `HEAD`
/// and never writes the user's index. Every command that needs an index
/// gets `GIT_INDEX_FILE` set to a copy in the undo folder. It writes only
/// objects and refs under `refs/pinpoint/`, and it changes files only with
/// `git apply`, after `git apply --check` passed on the same patch.
///
/// **Paths.** Git reports paths relative to the repository's top level. The
/// bridge's folder may sit below it (an app in `app/` inside the repo), so
/// every path this class takes or gives, and the paths stored in a note's
/// `rounds`, are **relative to the git top level**, with `/` separators.
/// [toRepoPath] turns what an agent writes (absolute, or relative to the
/// bridge's folder) into that form.
class Checkpoints {
  Checkpoints._(
    this.top,
    this._projectPrefix,
    this._projectPaths,
    this.undoDir,
    this.timeout,
  );

  /// Finds the git repository that holds [project] (the bridge's folder).
  /// Returns null when there is none, or when `git` is not installed:
  /// both mean "no git" to the bridge.
  ///
  /// [undoDir] holds the temporary index copy; it defaults to
  /// `<project>/.pinpoint/undo`. [timeout] limits each git command.
  static Future<Checkpoints?> open(
    Directory project, {
    Directory? undoDir,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final folder = project.absolute;
    final top = await _probe(folder, ['rev-parse', '--show-toplevel']);
    if (top == null || top.isEmpty) return null;
    // Empty at the top level, `app/` for a folder one level below.
    final prefix = await _probe(folder, ['rev-parse', '--show-prefix']) ?? '';
    final paths = <String>{folder.path};
    try {
      paths.add(folder.resolveSymbolicLinksSync());
    } on FileSystemException {
      // Only the unresolved form is known.
    }
    return Checkpoints._(
      top,
      prefix,
      paths,
      undoDir ?? Directory('${folder.path}/.pinpoint/undo'),
      timeout,
    );
  }

  /// One git call for [open]: its trimmed output, or null for any failure
  /// (not a repository, no `git` on the PATH).
  static Future<String?> _probe(Directory cwd, List<String> args) async {
    try {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: cwd.path,
        environment: _environment,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    } on ProcessException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// The git top level of the repository.
  final String top;

  /// The bridge folder's place below [top], with a trailing `/`; empty when
  /// it is [top] itself.
  final String _projectPrefix;

  /// The bridge folder as the OS names it, with symlinks resolved and not.
  final Set<String> _projectPaths;

  /// Where the temporary index copy is made.
  final Directory undoDir;

  /// The longest one git command may run.
  final Duration timeout;

  /// One operation at a time: they share the index copy.
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static const Map<String, String> _environment = {
    // Plain output for the error lines [revert] reads, and no locks that a
    // status call would take on the user's repository.
    'LC_ALL': 'C',
    'GIT_OPTIONAL_LOCKS': '0',
    'GIT_TERMINAL_PROMPT': '0',
  };

  /// A name that git accepts for the commit that keeps a tree alive, even
  /// when the user has no `user.name` set.
  static const Map<String, String> _identity = {
    'GIT_AUTHOR_NAME': 'Pinpoint',
    'GIT_AUTHOR_EMAIL': 'pinpoint@localhost',
    'GIT_COMMITTER_NAME': 'Pinpoint',
    'GIT_COMMITTER_EMAIL': 'pinpoint@localhost',
  };

  static final RegExp _label = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
  static final RegExp _sha = RegExp(r'^[0-9a-f]{40,64}$');

  String _ref(String noteId, String label) => 'refs/pinpoint/$noteId/$label';

  /// [path] (what an agent writes: absolute, or relative to the bridge's
  /// folder, or already relative to the git top level) as a path relative
  /// to the top level. Of the forms that could be meant, the first one in
  /// [known] wins; with no match, the folder-relative form.
  String toRepoPath(String path, Set<String> known) {
    final text = path.trim().replaceAll(r'\', '/');
    for (final dir in _projectPaths) {
      final folder = dir.replaceAll(r'\', '/');
      if (text.startsWith('$folder/')) {
        return _tidy('$_projectPrefix${text.substring(folder.length + 1)}');
      }
    }
    final root = top.replaceAll(r'\', '/');
    if (text.startsWith('$root/')) {
      return _tidy(text.substring(root.length + 1));
    }
    final tidy = _tidy(text);
    final below = _tidy('$_projectPrefix$tidy');
    if (known.contains(below)) return below;
    return known.contains(tidy) ? tidy : below;
  }

  static String _tidy(String path) {
    final parts = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(part);
    }
    return parts.join('/');
  }

  // ---------------------------------------------------------------- git

  /// Runs `git <args>` in the top level. Never throws: a missing `git` or
  /// a timeout comes back as exit code -1 with the reason in `err`.
  Future<_Run> _git(
    List<String> args, {
    String? indexFile,
    Map<String, String> env = const {},
    List<int>? stdin,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        'git',
        ['--literal-pathspecs', ...args],
        workingDirectory: top,
        environment: {..._environment, 'GIT_INDEX_FILE': ?indexFile, ...env},
      );
    } on ProcessException catch (error) {
      return _Run(-1, const <int>[], 'git is not available: ${error.message}');
    }
    final out = <int>[];
    final err = <int>[];
    final outDone = process.stdout.forEach(out.addAll);
    final errDone = process.stderr.forEach(err.addAll);
    try {
      if (stdin != null) process.stdin.add(stdin);
      await process.stdin.close();
    } on Object {
      // git quit before it read the patch; its exit code says why.
    }
    try {
      final code = await process.exitCode.timeout(timeout);
      await Future.wait([outDone, errDone]);
      return _Run(code, out, utf8.decode(err, allowMalformed: true));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return _Run(-1, const <int>[], 'git ${args.first} timed out');
    }
  }

  /// A copy of the user's index at [undoDir]`/index`, or no file when the
  /// repository has none yet (a fresh repo): git reads a missing index as
  /// an empty one. Never writes the real index.
  Future<String> _indexCopy({bool empty = false}) async {
    await undoDir.create(recursive: true);
    final copy = File('${undoDir.absolute.path}/index');
    for (final file in [copy, File('${copy.path}.lock')]) {
      if (file.existsSync()) await file.delete();
    }
    if (!empty) {
      final located = await _git(['rev-parse', '--git-path', 'index']);
      if (located.ok) {
        final raw = located.text.trim();
        final real = File(raw.startsWith('/') ? raw : '$top/$raw');
        try {
          if (real.existsSync()) {
            final modified = await real.lastModified();
            await real.copy(copy.path);
            // A fresh index timestamp can hide same-size edits that share
            // the cached file timestamp. Keep Git's racy-file check intact.
            await copy.setLastModified(modified);
          }
        } on FileSystemException {
          // Start from an empty index: slower, and the tree is the same.
          if (copy.existsSync()) await copy.delete();
        }
      }
    }
    return copy.path;
  }

  // ----------------------------------------------------------- snapshots

  /// The tree of the working folder now, kept alive under
  /// `refs/pinpoint/<noteId>/<label>`, or null when git failed.
  ///
  /// Commands: `git rev-parse --git-path index` (to find the index to
  /// copy), `git add -A` and `git write-tree` with `GIT_INDEX_FILE` set to
  /// the copy, `git commit-tree <tree>` and `git update-ref`.
  /// `.gitignore` applies, so `.pinpoint/` and `build/` are not in the tree.
  Future<String?> snapshot(String noteId, String label) => _serial(() async {
    if (!_label.hasMatch(label)) return null;
    var tree = await _writeTree(empty: false);
    // A split or sparse index does not copy well: the same tree comes from
    // an empty index, only slower.
    tree ??= await _writeTree(empty: true);
    if (tree == null) return null;
    final commit = await _git([
      '-c',
      'commit.gpgsign=false',
      'commit-tree',
      tree,
      '-m',
      'pinpoint $noteId $label',
    ], env: _identity);
    final sha = commit.text.trim();
    if (!commit.ok || !_sha.hasMatch(sha)) return null;
    final ref = await _git(['update-ref', _ref(noteId, label), sha]);
    return ref.ok ? tree : null;
  });

  Future<String?> _writeTree({required bool empty}) async {
    final index = await _indexCopy(empty: empty);
    final add = await _git(['add', '-A'], indexFile: index);
    if (!add.ok) return null;
    final write = await _git(['write-tree'], indexFile: index);
    final tree = write.text.trim();
    return write.ok && _sha.hasMatch(tree) ? tree : null;
  }

  /// The tree kept as [label] of [noteId], or null when there is none.
  Future<String?> resolve(String noteId, String label) async {
    if (!_label.hasMatch(label)) return null;
    final run = await _git([
      'rev-parse',
      '--verify',
      '-q',
      '${_ref(noteId, label)}^{tree}',
    ]);
    final tree = run.text.trim();
    return run.ok && _sha.hasMatch(tree) ? tree : null;
  }

  /// Deletes every ref of note [noteId]. The trees go at git's next
  /// `gc`. Never throws.
  Future<void> drop(String noteId) => _serial(() async {
    final listed = await _git([
      'for-each-ref',
      '--format=%(refname)',
      'refs/pinpoint/$noteId/',
    ]);
    if (!listed.ok) return;
    final refs = const LineSplitter()
        .convert(listed.text)
        .where((r) => r.startsWith('refs/pinpoint/$noteId/'))
        .toList();
    if (refs.isEmpty) return;
    await _git([
      'update-ref',
      '--stdin',
    ], stdin: utf8.encode([for (final r in refs) 'delete $r\n'].join()));
  });

  // ---------------------------------------------------------------- diff

  /// The files that differ between tree [start] and tree [end], with the
  /// lines added and removed: `git diff-tree -r --numstat -z`. Null when
  /// git failed.
  Future<List<FileDiff>?> diff(String start, String end) async {
    if (!_sha.hasMatch(start) || !_sha.hasMatch(end)) return null;
    final run = await _git([
      'diff-tree',
      '-r',
      '--no-renames',
      '--numstat',
      '-z',
      start,
      end,
    ]);
    if (!run.ok) return null;
    final files = <FileDiff>[];
    for (final entry in run.text.split('\u0000')) {
      final cut = entry.split('\t');
      if (cut.length < 3) continue;
      files.add(
        FileDiff(
          cut.sublist(2).join('\t'),
          int.tryParse(cut[0]),
          int.tryParse(cut[1]),
        ),
      );
    }
    return files;
  }

  /// The patch between tree [start] and tree [end] for [paths] (all files
  /// without): `git diff-tree -r -p`. Null when git failed.
  Future<String?> patch(String start, String end, {List<String>? paths}) async {
    if (!_sha.hasMatch(start) || !_sha.hasMatch(end)) return null;
    final run = await _git([
      'diff-tree',
      '-r',
      '-p',
      '--no-renames',
      '--no-color',
      '--no-ext-diff',
      '--no-textconv',
      start,
      end,
      if (paths != null) ...['--', ...paths],
    ]);
    return run.ok ? run.text : null;
  }

  // -------------------------------------------------------------- revert

  /// Puts [paths] back to what they were in tree [start], when [end] is
  /// what they are now: applies the reverse of the patch from [start] to
  /// [end] for those paths.
  ///
  /// Commands: `git diff-tree -r -p --binary -R <start> <end> -- <paths>`,
  /// then `git apply --check` on that patch, then `git apply` on it, both
  /// with `GIT_INDEX_FILE` set to a copy of the index. A file that no
  /// longer fits gives [RevertOutcome.conflict] and no file is changed.
  Future<RevertResult> revert(String start, String end, List<String> paths) =>
      _serial(() async {
        if (paths.isEmpty) return const RevertResult(RevertOutcome.clean);
        if (!_sha.hasMatch(start) || !_sha.hasMatch(end)) {
          return const RevertResult(
            RevertOutcome.failed,
            error: 'not a checkpoint',
          );
        }
        final made = await _git([
          'diff-tree',
          '-r',
          '-p',
          '--binary',
          '-R',
          '--no-renames',
          '--no-color',
          '--no-ext-diff',
          '--no-textconv',
          start,
          end,
          '--',
          ...paths,
        ]);
        if (!made.ok) {
          return RevertResult(RevertOutcome.failed, error: made.err.trim());
        }
        if (made.out.isEmpty) return const RevertResult(RevertOutcome.clean);
        final index = await _indexCopy();
        const flags = ['--whitespace=nowarn'];
        final check = await _git(
          ['apply', '--check', ...flags, '-'],
          indexFile: index,
          stdin: made.out,
        );
        if (!check.ok) {
          final bad = _conflictFiles(check.err, paths);
          if (check.code == 1 && bad.isNotEmpty) {
            return RevertResult(RevertOutcome.conflict, conflicts: bad);
          }
          return RevertResult(RevertOutcome.failed, error: check.err.trim());
        }
        final applied = await _git(
          ['apply', ...flags, '-'],
          indexFile: await _indexCopy(),
          stdin: made.out,
        );
        if (!applied.ok) {
          return RevertResult(RevertOutcome.failed, error: applied.err.trim());
        }
        return RevertResult(RevertOutcome.clean, reverted: [...paths]);
      });

  static final RegExp _failedAt = RegExp(r'^error: patch failed: (.+):\d+$');
  static final RegExp _cannotApply = RegExp(
    r'^error: (.+): (?:patch does not apply|No such file or directory|'
    r'already exists in working directory|does not exist in working directory)$',
  );

  /// The files named in the `error:` lines of `git apply --check`, among
  /// [wanted]. When git named none of them (a different message), all of
  /// [wanted]: the patch does not apply, and no file changed.
  static List<String> _conflictFiles(String stderr, List<String> wanted) {
    final named = <String>{};
    for (final line in const LineSplitter().convert(stderr)) {
      final match = _failedAt.firstMatch(line) ?? _cannotApply.firstMatch(line);
      if (match != null) named.add(match.group(1)!);
    }
    final bad = [
      for (final path in wanted)
        if (named.contains(path)) path,
    ];
    return bad.isEmpty && stderr.contains('error:') ? [...wanted] : bad;
  }
}

class _Run {
  const _Run(this.code, this.out, this.err);

  final int code;
  final List<int> out;
  final String err;

  bool get ok => code == 0;

  String get text => utf8.decode(out, allowMalformed: true);
}
