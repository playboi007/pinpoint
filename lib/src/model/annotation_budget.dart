part of 'annotation.dart';

/// The cuts that [Annotation.fitToBudget] makes.
extension _AnnotationBudget on Annotation {
  int get _bytes => utf8.encode(jsonEncode(toJson())).length;

  Annotation _marked(String name) => truncated.contains(name)
      ? this
      : copyWith(truncated: [...truncated, name]);

  /// The longest cut of [comment] that fits, or null when none does.
  Annotation? _fitComment(int maxBytes) {
    Annotation withLength(int n) => copyWith(comment: clipText(comment, n));
    if (withLength(1)._bytes > maxBytes) return null;
    var low = 1; // fits
    var high = comment.length; // does not fit
    while (high - low > 1) {
      final middle = (low + high) ~/ 2;
      if (withLength(middle)._bytes <= maxBytes) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return withLength(low);
  }

  Annotation? _target(TargetInfo? cut) =>
      cut == null ? null : copyWith(target: cut);

  Annotation? _subtreeLines(int max) {
    final lines = subtree?.split('\n');
    if (lines == null || lines.length <= max + 1) return null;
    return copyWith(subtree: () => [...lines.take(max), '…'].join('\n'));
  }

  /// [max] siblings around the target's branch.
  Annotation? _siblingWindow(int max) {
    final s = siblings;
    if (s == null || s.children.length <= max) return null;
    final offset = s.index - s.firstIndex;
    final from = math.max(
      0,
      math.min(offset - max ~/ 2, s.children.length - max),
    );
    return copyWith(
      siblings: () => SiblingsInfo(
        parent: s.parent,
        index: s.index,
        count: s.count,
        firstIndex: s.firstIndex + from,
        children: s.children.sublist(from, from + max),
      ),
    );
  }

  /// This note with only the newest [max] trace lines, keeping a first
  /// line that says rebuilds were not recorded; null when nothing to cut.
  Annotation? _traceLines(int max) {
    final current = trace;
    final lines = current?['lines'];
    if (current == null || lines is! List<Object?> || lines.length <= max) {
      return null;
    }
    final first = lines.isEmpty ? null : lines.first;
    final head = first is String && first.startsWith(traceNotRecorded);
    final body = head ? lines.sublist(1) : lines;
    final keep = head ? max - 1 : max;
    return copyWith(
      trace: () => {
        ...current,
        'lines': [if (head) first, ...body.sublist(body.length - keep)],
      },
    );
  }
}

/// The budget steps, in order. A step returns null when it has nothing
/// to cut.
final List<(String, Annotation? Function(Annotation))> _budgetSteps = [
  // The bridge keeps the rounds and puts them back, so they go first.
  ('rounds', (a) => a.rounds.isEmpty ? null : a.copyWith(rounds: const [])),
  // The agent can read the whole run with get_trace, so the trace goes next.
  ('trace', (a) => a._traceLines(20)),
  ('subtree', (a) => a._subtreeLines(10)),
  ('target.properties', (a) => a._target(a.target._clipProperties(60))),
  ('siblings', (a) => a._siblingWindow(5)),
  (
    'stateOwners.dependencies',
    (a) => a.stateOwners.every((o) => o.dependencies.isEmpty)
        ? null
        : a.copyWith(
            stateOwners: [
              for (final o in a.stateOwners) o.withoutDependencies(),
            ],
          ),
  ),
  (
    'stateOwners',
    (a) => a.stateOwners.length <= 2
        ? null
        : a.copyWith(stateOwners: a.stateOwners.take(2).toList()),
  ),
  (
    'ancestors',
    (a) => a.ancestors.length <= 4
        ? null
        : a.copyWith(ancestors: a.ancestors.take(4).toList()),
  ),
  ('target.sections', (a) => a._target(a.target._clipSections(60))),
  ('target.text', (a) => a._target(a.target._clipText(100))),
  ('target.description', (a) => a._target(a.target._clipDescription(80))),
  (
    'subtree',
    (a) => a.subtree == null ? null : a.copyWith(subtree: () => null),
  ),
  ('target.properties', (a) => a._target(a.target._firstProperties(8))),
  (
    'stateOwners',
    (a) => a.stateOwners.isEmpty
        ? null
        : a.copyWith(stateOwners: const <StateOwnerInfo>[]),
  ),
  (
    'siblings',
    (a) => a.siblings == null ? null : a.copyWith(siblings: () => null),
  ),
  (
    'ancestors',
    (a) => a.ancestors.length <= 1
        ? null
        : a.copyWith(ancestors: a.ancestors.take(1).toList()),
  ),
  ('target.sections', (a) => a._target(a.target._firstSections(0))),
  ('target.properties', (a) => a._target(a.target._firstProperties(0))),
];
