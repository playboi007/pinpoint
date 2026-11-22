part of 'commands.dart';

/// `verify_note`: checks a note's fix in the running app.
extension AgentVerify on AgentCommands {
  /// How long a command waits for the app to settle after a change. A
  /// route transition takes 300 ms; a screen with a looping animation
  /// never settles, and then each wait costs this much.
  static const Duration settleTimeout = Duration(seconds: 1);

  /// Runs a note's checks: applies the note's environment, goes to its
  /// route when its widget is not on screen, waits for idle, finds the
  /// widget by its anchor, runs each check and takes an "after"
  /// screenshot. Then it puts the environment, the route and every scroll
  /// position back, whatever happened.
  Future<Map<String, Object?>> verifyNote(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final job = _verifyJob(args);
    await prepareToDrive();
    final before = controller.environment.value;
    final scroll = scrollSnapshot();
    var pushed = false;
    try {
      // The note is checked as it was filed: under its environment.
      controller.environment.value = job.environment;
      await waitIdle(AgentVerify.settleTimeout, cancel);
      // After a hot reload the lines have moved: the anchor goes through
      // the nearest-line matching of SourceIndex.resolve, not its stored
      // line.
      Element? target = _resolveAnchor(job.anchor);
      final route = job.route;
      if (target == null && route != null && route != currentRoute()) {
        pushed = await AgentDrive.pushRoute(route);
        await waitIdle(AgentVerify.settleTimeout, cancel);
        target = _resolveAnchor(job.anchor);
      }
      if (target != null) {
        await ensureVisible(target);
        await waitIdle(AgentVerify.settleTimeout, cancel);
      }
      cancel.check();
      return await _verifyAnswer(job, target, cancel);
    } finally {
      // Restored on every path, a failure or Esc included.
      if (pushed) await AgentDrive.popRoute();
      controller.environment.value = before;
      await AgentDrive._frame();
      AgentDrive.restoreScroll(scroll);
      await waitIdle(AgentVerify.settleTimeout, AgentCancel());
    }
  }

  /// What `verify_note` was asked, read from the note. Throws an
  /// [AgentError] for a missing note or an environment that does not read.
  static _VerifyJob _verifyJob(Map<String, Object?> args) {
    final note = args['note'];
    if (note is! Map<String, Object?>) {
      throw const AgentError('note is required');
    }
    final anchor = switch (note['anchor']) {
      final Map<String, Object?> json => NoteAnchor.fromJson(json),
      _ => null,
    };
    final checks = [
      for (final check in asJsonList(note['checks']))
        if (check is Map<String, Object?> && check['type'] is String) check,
    ];
    final Environment environment;
    try {
      environment = Environment.fromJson(asJsonMap(note['environment']));
    } on FormatException catch (error) {
      throw AgentError("the note's environment: ${error.message}");
    }
    final page = asJsonMap(note['page']);
    return (
      note: note,
      anchor: anchor,
      checks: checks.isEmpty
          ? const [
              {'type': 'visible'},
            ]
          : checks,
      defaulted: checks.isEmpty,
      environment: environment,
      route: anchor?.route ?? asString(page['route']),
    );
  }

  Future<Map<String, Object?>> _verifyAnswer(
    _VerifyJob job,
    Element? target,
    AgentCancel cancel,
  ) async {
    final runner = CheckRunner(
      appRoot: appRoot,
      content: contentRoot,
      resolver: resolver(),
      devicePixelRatio: devicePixelRatio,
    );
    final results = await runner.run(target, job.checks);
    cancel.check();
    final png = await capturePng(
      target == null ? null : AgentCommands.renderObjectOf(target),
    );
    return {
      'id': job.note['id'],
      'passed': results.every((r) => r.passed),
      'found': target == null ? null : sourceOf(target),
      'checks': [for (final r in results) r.toJson()],
      if (job.defaulted) 'defaulted': 'the note has no checks; checked visible',
      'environment': job.environment.toJson(),
      'png': ?png,
    };
  }

  Element? _resolveAnchor(NoteAnchor? anchor) {
    if (anchor == null || !anchor.resolvable) return null;
    return sourceIndex().resolve(anchor, root: contentRoot);
  }

  /// `file:line` of [element]'s constructor call, or null.
  String? sourceOf(Element element) {
    final location = resolver().locationOf(element);
    if (location == null) return null;
    return '${resolver().paths.relativePath(location.uri)}:${location.line}';
  }
}

typedef _VerifyJob = ({
  Map<String, Object?> note,
  NoteAnchor? anchor,
  List<Map<String, Object?>> checks,
  bool defaulted,
  Environment environment,
  String? route,
});
