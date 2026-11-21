import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/checkpoints.dart';

import '../support/temp_git.dart';

/// PLAN-v3 Milestone 20, step 1: trees of the working folder kept under
/// `refs/pinpoint/`, and the undo of the difference between two of them.
///
/// Every test makes its own repository in a temporary folder. None of them
/// runs git in this project.
void main() {
  final skip = gitAvailable ? null : 'git is not on the PATH';
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pinpoint_checkpoints_');
  });
  tearDown(() => temp.delete(recursive: true));

  File file(String path) => File('${temp.path}/$path');
  void write(String path, String text) {
    file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  Future<Checkpoints> open({Directory? project}) async {
    final found = await Checkpoints.open(
      project ?? temp,
      undoDir: Directory('${temp.path}/.pinpoint/undo'),
    );
    return found!;
  }

  void seed() {
    write('.gitignore', '.pinpoint/\nbuild/\n');
    write('lib/a.dart', 'one\ntwo\nthree\nfour\nfive\n');
    write('lib/b.dart', 'alpha\nbeta\n');
    write('README.md', 'readme\n');
  }

  test('without git, open gives null', () async {
    expect(await Checkpoints.open(temp), isNull);
  }, skip: skip);

  test('snapshot detects a same-size edit with the index timestamp', () async {
    final stamp = DateTime.utc(2020);
    final source = file('lib/a.dart');
    write('.gitignore', '.pinpoint/\n');
    write('lib/a.dart', 'before\n');
    source.setLastModifiedSync(stamp);
    initRepo(temp);
    runGit(temp, ['config', 'core.trustctime', 'false']);
    runGit(temp, ['config', 'core.checkStat', 'minimal']);
    final index = file('.git/index')..setLastModifiedSync(stamp);
    final cp = await open();
    final start = (await cp.snapshot('pp_one', 'r1-start'))!;

    source
      ..writeAsStringSync('edited\n')
      ..setLastModifiedSync(stamp);
    final end = (await cp.snapshot('pp_one', 'r1-end'))!;

    expect(await cp.patch(start, end), contains('+edited'));
    expect(index.lastModifiedSync().toUtc(), stamp);
  }, skip: skip);

  test('snapshot, edit two files, add one, snapshot: diff gives three files '
      'with counts', () async {
    seed();
    initRepo(temp);
    final cp = await open();
    final user = RepoState.of(temp);

    final start = await cp.snapshot('pp_one', 'r1-start');
    write('lib/a.dart', 'one\nTWO\nthree\nfour\nfive\nsix\n');
    write('lib/b.dart', 'alpha\n');
    write('lib/new.dart', 'x\ny\nz\n');
    write('build/out.txt', 'ignored\n');
    final end = await cp.snapshot('pp_one', 'r1-end');
    expect(start, isNotNull);
    expect(end, isNotNull);

    final files = {for (final f in (await cp.diff(start!, end!))!) f.path: f};
    expect(files.keys.toSet(), {'lib/a.dart', 'lib/b.dart', 'lib/new.dart'});
    expect([files['lib/a.dart']!.added, files['lib/a.dart']!.removed], [2, 1]);
    expect([files['lib/b.dart']!.added, files['lib/b.dart']!.removed], [0, 1]);
    expect(
      [files['lib/new.dart']!.added, files['lib/new.dart']!.removed],
      [3, 0],
    );
    expect(await cp.resolve('pp_one', 'r1-end'), end);
    expect(await cp.resolve('pp_one', 'r1-nothing'), isNull);
    expect(await cp.patch(start, end), contains('+TWO'));

    // The user's side did not move.
    expect(RepoState.of(temp).differsFrom(user), isNull);
    // The undo folder is not in the tree.
    expect(files.keys.any((p) => p.startsWith('.pinpoint')), isFalse);
  }, skip: skip);

  test(
    'revert puts one file back and leaves the user\'s index and HEAD alone',
    () async {
      seed();
      initRepo(temp);
      final cp = await open();
      final start = (await cp.snapshot('pp_one', 'r1-start'))!;
      write('lib/a.dart', 'one\nTWO\nthree\nfour\nfive\n');
      write('lib/b.dart', 'alpha\nBETA\n');
      write('lib/new.dart', 'x\n');
      final end = (await cp.snapshot('pp_one', 'r1-end'))!;
      final user = RepoState.of(temp);

      final result = await cp.revert(start, end, ['lib/a.dart']);
      expect(result.outcome, RevertOutcome.clean);
      expect(result.reverted, ['lib/a.dart']);
      expect(
        file('lib/a.dart').readAsStringSync(),
        'one\ntwo\nthree\nfour\nfive\n',
      );
      expect(file('lib/b.dart').readAsStringSync(), 'alpha\nBETA\n');
      expect(file('lib/new.dart').existsSync(), isTrue);
      expect(RepoState.of(temp).differsFrom(user), isNull);

      // An added file goes away; the other edit stays.
      final both = await cp.revert(start, end, ['lib/new.dart', 'lib/b.dart']);
      expect(both.outcome, RevertOutcome.clean);
      expect(file('lib/new.dart').existsSync(), isFalse);
      expect(file('lib/b.dart').readAsStringSync(), 'alpha\nbeta\n');
      expect(RepoState.of(temp).differsFrom(user), isNull);
    },
    skip: skip,
  );

  test(
    'a conflict changes no file: the reverted lines were edited again',
    () async {
      seed();
      initRepo(temp);
      final cp = await open();
      final start = (await cp.snapshot('pp_one', 'r1-start'))!;
      write('lib/a.dart', 'one\nTWO\nthree\nfour\nfive\n');
      write('lib/b.dart', 'alpha\nBETA\n');
      final end = (await cp.snapshot('pp_one', 'r1-end'))!;
      // The user edits the line the agent changed.
      write('lib/a.dart', 'one\nTWO and more\nthree\nfour\nfive\n');
      final user = RepoState.of(temp);

      final result = await cp.revert(start, end, ['lib/a.dart', 'lib/b.dart']);
      expect(result.outcome, RevertOutcome.conflict);
      expect(result.conflicts, ['lib/a.dart']);
      expect(result.reverted, isEmpty);
      // b.dart would have applied alone, and still it did not change.
      expect(file('lib/a.dart').readAsStringSync(), contains('TWO and more'));
      expect(file('lib/b.dart').readAsStringSync(), 'alpha\nBETA\n');
      expect(RepoState.of(temp).differsFrom(user), isNull);

      // The file the user deleted is a conflict too.
      file('lib/b.dart').deleteSync();
      final gone = await cp.revert(start, end, ['lib/b.dart']);
      expect(gone.outcome, RevertOutcome.conflict);
      expect(gone.conflicts, ['lib/b.dart']);
    },
    skip: skip,
  );

  test('a repository with no commit and no index works', () async {
    seed();
    initRepo(temp, commit: false);
    final cp = await open();
    expect(File('${temp.path}/.git/index').existsSync(), isFalse);
    final user = RepoState.of(temp);
    expect(user.head, 'none');

    final start = (await cp.snapshot('pp_one', 'base'))!;
    write('lib/a.dart', 'changed\n');
    write('lib/c.dart', 'new\n');
    final end = (await cp.snapshot('pp_one', 'r1-end'))!;
    final names = [for (final f in (await cp.diff(start, end))!) f.path]
      ..sort();
    expect(names, ['lib/a.dart', 'lib/c.dart']);

    final result = await cp.revert(start, end, ['lib/a.dart', 'lib/c.dart']);
    expect(result.outcome, RevertOutcome.clean);
    expect(file('lib/a.dart').readAsStringSync(), startsWith('one\n'));
    expect(file('lib/c.dart').existsSync(), isFalse);
    expect(File('${temp.path}/.git/index').existsSync(), isFalse);
    expect(RepoState.of(temp).differsFrom(user), isNull);
  }, skip: skip);

  test(
    'a bridge folder below the git top level: paths are repo-relative',
    () async {
      write('.gitignore', '.pinpoint/\n');
      write('README.md', 'top\n');
      write('app/lib/main.dart', 'void main() {}\n');
      initRepo(temp);
      final app = Directory('${temp.path}/app');
      final cp = (await Checkpoints.open(
        app,
        undoDir: Directory('${app.path}/.pinpoint/undo'),
      ))!;
      final start = (await cp.snapshot('pp_one', 'r1-start'))!;
      write('app/lib/main.dart', 'void main() { run(); }\n');
      write('README.md', 'top changed\n');
      final end = (await cp.snapshot('pp_one', 'r1-end'))!;
      final user = RepoState.of(temp);

      final paths = [for (final f in (await cp.diff(start, end))!) f.path]
        ..sort();
      expect(paths, ['README.md', 'app/lib/main.dart']);

      final known = paths.toSet();
      expect(cp.toRepoPath('lib/main.dart', known), 'app/lib/main.dart');
      expect(cp.toRepoPath('./lib/main.dart', known), 'app/lib/main.dart');
      expect(cp.toRepoPath('app/lib/main.dart', known), 'app/lib/main.dart');
      expect(
        cp.toRepoPath('${app.resolveSymbolicLinksSync()}/lib/main.dart', known),
        'app/lib/main.dart',
      );
      expect(
        cp.toRepoPath('${app.path}/lib/main.dart', known),
        'app/lib/main.dart',
      );
      expect(cp.toRepoPath('README.md', known), 'README.md');
      expect(cp.toRepoPath('lib/nope.dart', known), 'app/lib/nope.dart');

      final result = await cp.revert(start, end, ['app/lib/main.dart']);
      expect(result.outcome, RevertOutcome.clean);
      expect(file('app/lib/main.dart').readAsStringSync(), 'void main() {}\n');
      expect(file('README.md').readAsStringSync(), 'top changed\n');
      expect(RepoState.of(temp).differsFrom(user), isNull);
    },
    skip: skip,
  );

  test('drop deletes the refs of one note and keeps the others', () async {
    seed();
    initRepo(temp);
    final cp = await open();
    await cp.snapshot('pp_one', 'base');
    await cp.snapshot('pp_one', 'r1-start');
    await cp.snapshot('pp_two', 'base');
    expect(
      runGit(temp, ['for-each-ref', 'refs/pinpoint/']).split('\n'),
      hasLength(3),
    );

    await cp.drop('pp_one');
    final left = runGit(temp, ['for-each-ref', 'refs/pinpoint/']);
    expect(left, contains('refs/pinpoint/pp_two/base'));
    expect(left, isNot(contains('pp_one')));
    expect(await cp.resolve('pp_one', 'base'), isNull);
    expect(await cp.resolve('pp_two', 'base'), isNotNull);
    // Dropping what is not there is fine.
    await cp.drop('pp_one');
  }, skip: skip);

  test('a repository without user.name still snapshots', () async {
    seed();
    initRepo(temp);
    runGit(temp, ['config', '--unset', 'user.name']);
    runGit(temp, ['config', '--unset', 'user.email']);
    final cp = await open();
    expect(await cp.snapshot('pp_one', 'base'), isNotNull);
    expect(await cp.snapshot('pp_one', 'bad label!'), isNull);
  }, skip: skip);
}
