part of 'commands.dart';

/// `stress_matrix`: the app under many environments.
extension AgentStress on AgentCommands {
  /// Runs each environment of the matrix: sets it, waits for idle, scans,
  /// and takes a 400 px thumbnail. Each distinct problem that a check can
  /// measure becomes a draft note with the environment of the first run
  /// that showed it. An `info` finding is listed, never filed alone.
  ///
  /// The environment and every scroll position are put back afterwards,
  /// and a draft already filed for a finding and environment is not filed
  /// again.
  Future<Map<String, Object?>> stressMatrix(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    final plan = _stressPlan(args);
    final thumbnails = args['thumbnails'] != false;

    await prepareToDrive();
    final scroll = scrollSnapshot();
    final tally = _StressTally();
    // The rail's progress strip: one tick per run, gone at the end.
    StressProgress.start(plan.runs.length);
    try {
      for (final (i, run) in plan.runs.indexed) {
        cancel.check();
        await _stressRun(
          i + 1,
          run,
          plan.kinds,
          tally,
          limits,
          cancel,
          thumbnails: thumbnails,
        );
      }
    } finally {
      StressProgress.finish();
      controller.environment.value = plan.base;
      await AgentDrive._frame();
      AgentDrive.restoreScroll(scroll);
      await waitIdle(AgentVerify.settleTimeout, AgentCancel());
    }
    return {
      'runs': tally.results,
      'findings': tally.distinct.values.toList(),
      'drafts': tally.drafts,
      if (tally.existing.isNotEmpty) 'existing': tally.existing,
      if (args['full'] == true && plan.runs.length >= stressMaxRuns)
        'truncated': 'at most $stressMaxRuns runs',
    };
  }

  _StressPlan _stressPlan(Map<String, Object?> args) {
    final kinds = AgentView._kinds(args['kinds'], const {
      'overflow',
      'truncated_text',
      'accessibility',
    });
    final base = controller.environment.value;
    final root = appRoot;
    final runs = stressRuns(
      base: base,
      height: base.viewport?.height ?? root.paintBounds.height,
      widths: _listArg(args, 'widths', _positive),
      textScales: _listArg(args, 'textScales', _positive),
      directions: _listArg(
        args,
        'directions',
        (v) => asEnum(TextDirection.values, v),
      ),
      brightness: _listArg(
        args,
        'brightness',
        (v) => asEnum(Brightness.values, v),
      ),
      full: args['full'] == true,
    );
    return (kinds: kinds, base: base, runs: runs);
  }

  /// Run number [n]: sets the environment, scans, files new findings.
  Future<void> _stressRun(
    int n,
    StressRun run,
    Set<String> kinds,
    _StressTally tally,
    OutputLimits limits,
    AgentCancel cancel, {
    required bool thumbnails,
  }) async {
    controller.environment.value = run.environment;
    await waitIdle(AgentVerify.settleTimeout, cancel);
    final found = await findingsFor(kinds);
    cancel.check();
    for (final finding in found) {
      _stressFinding(finding, run, n, tally, limits);
    }
    final png = thumbnails ? await capturePng(null, maxWidth: 400) : null;
    tally.results.add({
      'run': n,
      'label': run.label,
      'environment': run.environment.toJson(),
      'findings': found.length,
      'png': ?png,
    });
    StressProgress.advance(n);
  }

  void _stressFinding(
    Finding finding,
    StressRun run,
    int n,
    _StressTally tally,
    OutputLimits limits,
  ) {
    final seen = tally.distinct[finding.key];
    if (seen != null) {
      (seen['runs']! as List<int>).add(n);
      return;
    }
    tally.distinct[finding.key] = {
      ...findingJson(finding, limits),
      'runs': <int>[n],
    };
    if (_fileDraft(finding, run) case (final id, final isExisting)) {
      (isExisting ? tally.existing : tally.drafts).add(id);
    }
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

typedef _StressPlan = ({
  Set<String> kinds,
  Environment base,
  List<StressRun> runs,
});

/// What the runs of one matrix found, in the order they were found.
class _StressTally {
  final List<Map<String, Object?>> results = [];
  final Map<String, Map<String, Object?>> distinct = {};
  final List<String> drafts = [];
  final List<String> existing = [];
}

List<T>? _listArg<T>(
  Map<String, Object?> args,
  String key,
  T? Function(Object? value) read,
) {
  final value = args[key];
  if (value == null) return null;
  if (value is! List<Object?>) throw AgentError('$key must be a list');
  return [
    for (final item in value)
      read(item) ?? (throw AgentError('$key: cannot read $item')),
  ];
}

double? _positive(Object? v) => v is num && v > 0 ? v.toDouble() : null;
