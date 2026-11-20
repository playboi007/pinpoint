import 'dart:io';

/// Whether `git` runs on this machine; git tests skip without it.
final bool gitAvailable = () {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Runs `git <args>` in [dir] and returns its trimmed output. Throws when
/// git fails. Git tests make their own repository in a temporary folder and
/// never run git in this project.
String runGit(Directory dir, List<String> args) {
  final result = Process.runSync(
    'git',
    args,
    workingDirectory: dir.path,
    environment: {'GIT_TERMINAL_PROMPT': '0'},
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

/// `git init` in [dir] with a local identity, and, with [commit], one
/// initial commit of the files already there.
void initRepo(Directory dir, {bool commit = true}) {
  runGit(dir, ['init', '-q']);
  runGit(dir, ['config', 'user.name', 'Test']);
  runGit(dir, ['config', 'user.email', 'test@example.com']);
  runGit(dir, ['config', 'commit.gpgsign', 'false']);
  if (commit) {
    runGit(dir, ['add', '-A']);
    runGit(dir, ['commit', '-q', '-m', 'initial']);
  }
}

/// The user's side of a repository, to compare before and after: HEAD, the
/// staged diff and the bytes of the index file.
class RepoState {
  RepoState._(this.head, this.staged, this.index);

  factory RepoState.of(Directory repo) {
    final headRun = Process.runSync('git', [
      'rev-parse',
      '-q',
      '--verify',
      'HEAD',
    ], workingDirectory: repo.path);
    final indexFile = File('${repo.path}/.git/index');
    return RepoState._(
      headRun.exitCode == 0 ? (headRun.stdout as String).trim() : 'none',
      runGit(repo, ['diff', '--cached']),
      indexFile.existsSync() ? indexFile.readAsBytesSync() : const <int>[],
    );
  }

  final String head;
  final String staged;
  final List<int> index;

  /// Fails with a reason when [other] differs.
  String? differsFrom(RepoState other) {
    if (head != other.head) return 'HEAD moved';
    if (staged != other.staged) return 'the staged diff changed';
    if (index.length != other.index.length) return 'the index file changed';
    for (var i = 0; i < index.length; i++) {
      if (index[i] != other.index[i]) return 'the index file changed';
    }
    return null;
  }
}
