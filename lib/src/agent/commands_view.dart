part of 'commands.dart';

/// Screenshots, environment overrides and findings scans.
extension AgentView on AgentCommands {
  /// A PNG (base64) of [target] outlined, or of the whole app with no
  /// target, at most [maxWidth] wide. Null when the capture fails.
  Future<String?> capturePng(RenderObject? target, {int maxWidth = 800}) async {
    try {
      final boundary = appRoot;
      if (boundary is! RenderRepaintBoundary) return null;
      final rect = target == null
          ? RenderSearch.globalRectOf(boundary)
          : RenderSearch.globalRectOf(target);
      if (rect == null) return null;
      final shot = await captureScreenshot(
        boundary,
        rect,
        pixelRatio: devicePixelRatio,
        maxWidth: maxWidth,
        outline: target != null,
      ).timeout(const Duration(seconds: 5));
      return shot == null ? null : base64Encode(shot.png);
    } catch (_) {
      return null;
    }
  }

  /// `set_environment`: changes only the switches given (keys as in a
  /// note's `environment`); null clears one.
  Future<Map<String, Object?>> setEnvironment(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final changes = {
      for (final MapEntry(:key, :value) in args.entries)
        if (key != 'limit' && key != 'max_chars') key: value,
    };
    final Environment next;
    try {
      next = controller.environment.value.applyJson(changes);
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
    await prepareToDrive();
    controller.environment.value = next;
    await waitIdle(AgentVerify.settleTimeout, cancel);
    return {'environment': next.toJson(), 'summary': next.summary};
  }

  /// `reset_environment`: removes every what-if override.
  Future<Map<String, Object?>> resetEnvironment(AgentCancel cancel) async {
    await prepareToDrive();
    controller.environment.reset();
    await waitIdle(AgentVerify.settleTimeout, cancel);
    return {'environment': const <String, Object?>{}};
  }

  /// The kinds `scan` and `stress_matrix` know.
  static const Set<String> scanKinds = {
    'overflow',
    'truncated_text',
    'oversized_image',
    'accessibility',
  };

  /// The detectors of [kinds] on the screen as it is now.
  /// `accessibility` runs the audit: semantics for one frame, and a
  /// capture for contrast.
  Future<List<Finding>> findingsFor(Set<String> kinds) async {
    final root = appRoot;
    final locator = this.locator();
    final detectors = <Detector>[
      if (kinds.contains('overflow')) const OverflowDetector(),
      if (kinds.contains('truncated_text')) const TruncationDetector(),
      if (kinds.contains('oversized_image'))
        ImageDetector(devicePixelRatio: devicePixelRatio),
    ];
    final found = <Finding>[
      if (detectors.isNotEmpty)
        ...scanTree(root, detectors, locator: locator).findings,
    ];
    if (kinds.contains('accessibility')) {
      found.addAll(
        await runAccessibilityAudit(
          root,
          locator: locator,
          devicePixelRatio: devicePixelRatio,
        ),
      );
    }
    return dedupeFindings(found);
  }

  static Set<String> _kinds(Object? value, Set<String> fallback) {
    if (value == null) return fallback;
    if (value is! List<Object?>) {
      throw const AgentError('kinds must be a list');
    }
    final kinds = <String>{};
    for (final kind in value) {
      if (kind is! String || !scanKinds.contains(kind)) {
        throw AgentError('unknown kind: $kind; use ${scanKinds.join(', ')}');
      }
      kinds.add(kind);
    }
    return kinds;
  }

  /// [finding] as the agent sees it.
  Map<String, Object?> findingJson(Finding finding, OutputLimits limits) {
    final source = finding.source;
    final rect = finding.rect;
    return {
      'kind': finding.kind,
      'severity': finding.severity.name,
      'summary': limits.clip(finding.summary),
      if (source != null)
        'source': '${resolver().paths.relativePath(source.uri)}:${source.line}',
      'route': ?finding.route,
      if (rect != null) 'rect': AgentScreen.rectList(rect),
      'key': finding.key,
    };
  }

  /// `scan`: the detectors on the current screen.
  Future<Map<String, Object?>> scan(
    Map<String, Object?> args,
    OutputLimits limits,
  ) async {
    final kinds = _kinds(args['kinds'], const {
      'overflow',
      'truncated_text',
      'oversized_image',
    });
    final found = await findingsFor(kinds);
    final shown = found.take(limits.items).toList();
    return {
      'findings': [for (final f in shown) findingJson(f, limits)],
      if (found.length > shown.length) 'more': found.length - shown.length,
    };
  }

  /// `screenshot`: the whole app, or the handle's widget outlined, at most
  /// `max_width` wide (default 800).
  Future<Map<String, Object?>> screenshot(Map<String, Object?> args) async {
    final target = args['handle'] is String ? element(args) : null;
    final width = args['max_width'] is num
        ? (args['max_width']! as num).round().clamp(100, 1600)
        : 800;
    final png = await capturePng(
      target == null ? null : AgentCommands.renderObjectOf(target),
      maxWidth: width,
    );
    if (png == null) throw const AgentError('the capture failed');
    return {'handle': ?args['handle'], 'png': png};
  }
}
