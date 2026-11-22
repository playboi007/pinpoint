part of 'commands.dart';

/// `stress_matrix`: the app under many environments.
extension AgentStress on AgentCommands {
  /// `stress_matrix` (plan Milestone 12, step 8): each run sets its
  /// environment, waits for idle, scans, and takes a 400 px thumbnail.
  /// Each distinct problem that a check can measure becomes a draft note
  /// with the environment of the first run that showed it. Truncation is
  /// often intended: an `info` finding is listed, never filed alone.
  ///
  /// The environment and every scroll position are put back afterwards,
  /// so a second run starts from the same state and reports the same
  /// findings; a draft already filed for a finding and environment is not
  /// filed again.
  Future<Map<String, Object?>> stressMatrix(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    final kinds = AgentView._kinds(args['kinds'], const {
      'overflow',
      'truncated_text',
      'accessibility',
    });
    List<T>? listOf<T>(String key, T? Function(Object? value) read) {
      final value = args[key];
      if (value == null) return null;
      if (value is! List<Object?>) throw AgentError('$key must be a list');
      return [
        for (final item in value)
          read(item) ?? (throw AgentError('$key: cannot read $item')),
      ];
    }

    double? positive(Object? v) => v is num && v > 0 ? v.toDouble() : null;
    T? byName<T extends Enum>(List<T> values, Object? v) {
      for (final value in values) {
        if (value.name == v) return value;
      }
      return null;
    }

    final base = controller.environment.value;
    final root = appRoot;
    final runs = stressRuns(
      base: base,
      height: base.viewport?.height ?? root.paintBounds.height,
      widths: listOf('widths', positive),
      textScales: listOf('textScales', positive),
      directions: listOf('directions', (v) => byName(TextDirection.values, v)),
      brightness: listOf('brightness', (v) => byName(Brightness.values, v)),
      full: args['full'] == true,
    );
    final thumbnails = args['thumbnails'] != false;

    await prepareToDrive();
    final scroll = scrollSnapshot();
    final runResults = <Map<String, Object?>>[];
    final distinct = <String, Map<String, Object?>>{};
    final drafts = <String>[];
    final existing = <String>[];
    // The rail's progress strip: one tick per run, gone at the end.
    StressProgress.start(runs.length);
    try {
      for (final (i, run) in runs.indexed) {
        cancel.check();
        controller.environment.value = run.environment;
        await waitIdle(AgentVerify.settleTimeout, cancel);
        final found = await findingsFor(kinds);
        cancel.check();
        for (final finding in found) {
          final seen = distinct[finding.key];
          if (seen != null) {
            (seen['runs']! as List<int>).add(i + 1);
            continue;
          }
          distinct[finding.key] = {
            ...findingJson(finding, limits),
            'runs': <int>[i + 1],
          };
          final filed = _fileDraft(finding, run);
          if (filed == null) continue;
          (filed.$2 ? existing : drafts).add(filed.$1);
        }
        final png = thumbnails ? await capturePng(null, maxWidth: 400) : null;
        runResults.add({
          'run': i + 1,
          'label': run.label,
          'environment': run.environment.toJson(),
          'findings': found.length,
          'png': ?png,
        });
        StressProgress.advance(i + 1);
      }
    } finally {
      StressProgress.finish();
      controller.environment.value = base;
      await AgentDrive._frame();
      AgentDrive.restoreScroll(scroll);
      await waitIdle(AgentVerify.settleTimeout, AgentCancel());
    }
    return {
      'runs': runResults,
      'findings': distinct.values.toList(),
      'drafts': drafts,
      if (existing.isNotEmpty) 'existing': existing,
      if (args['full'] == true && runs.length >= stressMaxRuns)
        'truncated': 'at most $stressMaxRuns runs',
    };
  }

  /// Files [finding] from [run] as a draft note on its nearest local
  /// widget: `(id, false)` for a new draft, `(id, true)` when one for the
  /// same finding and environment exists, null when not filed.
  (String, bool)? _fileDraft(Finding finding, StressRun run) {
    if (finding.severity == Severity.info) return null;
    final checks = checksFor(finding);
    if (checks.isEmpty) return null;
    final environment = run.environment.toJson();
    final envKey = jsonEncode(environment);
    for (final note in controller.notes.notes) {
      if (note.finding?['key'] == finding.key &&
          jsonEncode(note.environment ?? const {}) == envKey) {
        return (note.id, true);
      }
    }
    final element = finding.element;
    if (element == null || !element.mounted) return null;
    var pick = pickFor(element);
    // The widget written in this project, not the framework's inside it.
    final local = pick.chain.defaultIndex;
    if (local != null) pick = pick.selecting(local);
    final note = _collector
        .collect(
          pick,
          'Stress matrix (${run.label}): ${finding.summary}',
          AnnotationIntent.bug,
          context: pageContext(),
          environment: environment,
        )
        .copyWith(finding: () => finding.toJson(), checks: checks);
    final keep = onDraft;
    if (keep == null) {
      controller.notes.put(note);
    } else {
      keep(note, pick);
    }
    return (note.id, false);
  }
}
