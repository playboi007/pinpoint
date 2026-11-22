import 'package:flutter_test/flutter_test.dart';

import 'source_metrics.dart';
import 'source_scan.dart';

/// The ratchet for `lib/`. Each limit is the count at the last refactor phase.
/// A limit only goes down. When a count falls, lower its limit in the same
/// commit. Never raise one.
const _limits = (
  planComments: 147,
  storyComments: 43,
  filesOver500Lines: 25,
  functionsOver60Lines: 79,
  stringKindCompares: 188,
  jsonHelperCopies: 0,
  positionalBoolParameters: 22,
  plainDartHeadersCitingPlan: 12,
);

void main() {
  final files = scanDartFiles('lib');

  void expectAtMost(String rule, List<Hit> hits, int limit) {
    expect(
      hits.length,
      lessThanOrEqualTo(limit),
      reason:
          '$rule: ${hits.length} found, limit $limit. Remove the new ones:\n'
          '${hits.map((hit) => '  $hit').join('\n')}',
    );
  }

  test('the scan reads every file of lib/', () {
    expect(files.length, greaterThan(150));
  });

  test('comments do not name a plan, milestone, session number or step', () {
    expectAtMost('plan comment', planComments(files), _limits.planComments);
  });

  test('comments do not tell the history of the code', () {
    expectAtMost('story comment', storyComments(files), _limits.storyComments);
  });

  test('files stay under 500 lines', () {
    expectAtMost(
      'file over 500 lines',
      filesOver(files, 500),
      _limits.filesOver500Lines,
    );
  });

  test('functions stay under 60 lines', () {
    expectAtMost(
      'function over 60 lines',
      longFunctions(files, 60),
      _limits.functionsOver60Lines,
    );
  });

  test('kinds are not compared with string literals', () {
    expectAtMost(
      'string literal compare',
      stringKindCompares(files),
      _limits.stringKindCompares,
    );
  });

  test('JSON read helpers are not copied into feature files', () {
    expectAtMost('JSON helper', jsonHelpers(files), _limits.jsonHelperCopies);
  });

  test('a bool parameter does not pick a branch by position', () {
    expectAtMost(
      'positional bool parameter',
      positionalBoolParameters(files),
      _limits.positionalBoolParameters,
    );
  });

  test('Plain Dart headers do not cite a plan', () {
    expectAtMost(
      'Plain Dart header with a plan',
      plainDartHeadersCitingPlan(files),
      _limits.plainDartHeadersCitingPlan,
    );
  });
}
