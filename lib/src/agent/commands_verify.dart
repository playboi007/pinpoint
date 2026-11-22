part of 'commands.dart';

/// `verify_note`: checks a note's fix in the running app.
extension AgentVerify on AgentCommands {
  /// How long a command waits for the app to settle after a change. A
  /// route transition takes 300 ms; a screen with a looping animation
  /// never settles, and then each wait costs this much.
  static const Duration settleTimeout = Duration(seconds: 1);

  /// Runs a note's checks (plan Milestone 12, step 7): applies the note's
  /// environment, goes to its route when its widget is not on screen,
  /// waits for idle, finds the widget by its anchor, runs each check and
  /// takes an "after" screenshot. Then it puts the environment, the route
  /// and every scroll position back, whatever happened.
  Future<Map<String, Object?>> verifyNote(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final note = args['note'];
    if (note is! Map<String, Object?>) {
      throw const AgentError('note is required');
    }
    final anchorJson = note['anchor'];
    final anchor = anchorJson is Map<String, Object?>
        ? NoteAnchor.fromJson(anchorJson)
        : null;
    var checks = [
      for (final check
          in note['checks'] is List<Object?>
              ? note['checks']! as List<Object?>
              : const <Object?>[])
        if (check is Map<String, Object?> && check['type'] is String) check,
    ];
    final defaulted = checks.isEmpty;
    if (defaulted) {
      checks = const [
        {'type': 'visible'},
      ];
    }
    final Environment environment;
    try {
      final json = note['environment'];
      environment = Environment.fromJson(
        json is Map<String, Object?> ? json : const {},
      );
    } on FormatException catch (error) {
      throw AgentError("the note's environment: ${error.message}");
    }
    final page = note['page'];
    final route =
        anchor?.route ??
        (page is Map<String, Object?> && page['route'] is String
            ? page['route']! as String
            : null);

    await prepareToDrive();
    final before = controller.environment.value;
    final scroll = scrollSnapshot();
    var pushed = false;
    try {
      // The note is checked as it was filed: under its environment.
      controller.environment.value = environment;
      await waitIdle(settleTimeout, cancel);
      // Watch out for: after a hot reload the lines have moved. The anchor
      // goes through the nearest-line matching of SourceIndex.resolve,
      // never through its stored line alone.
      Element? target = _resolveAnchor(anchor);
      if (target == null && route != null && route != currentRoute()) {
        pushed = await AgentDrive.pushRoute(route);
        await waitIdle(settleTimeout, cancel);
        target = _resolveAnchor(anchor);
      }
      if (target != null) {
        await ensureVisible(target);
        await waitIdle(settleTimeout, cancel);
      }
      cancel.check();
      final root = appRoot;
      final runner = CheckRunner(
        appRoot: root,
        content: contentRoot,
        resolver: resolver(),
        devicePixelRatio: devicePixelRatio,
      );
      final results = await runner.run(target, checks);
      cancel.check();
      final png = await capturePng(
        target == null ? null : AgentCommands.renderObjectOf(target),
      );
      return {
        'id': note['id'],
        'passed': results.every((r) => r.passed),
        'found': target == null ? null : sourceOf(target),
        'checks': [for (final r in results) r.toJson()],
        if (defaulted) 'defaulted': 'the note has no checks; checked visible',
        'environment': environment.toJson(),
        'png': ?png,
      };
    } finally {
      // Restored on every path, a failure or Esc included.
      if (pushed) await AgentDrive.popRoute();
      controller.environment.value = before;
      await AgentDrive._frame();
      AgentDrive.restoreScroll(scroll);
      await waitIdle(settleTimeout, AgentCancel());
    }
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
