part of 'commands.dart';

/// `run_steps` and the reads that settle before they answer.
extension AgentSteps on AgentCommands {
  /// Tools a `run_steps` step may call. Not `inspect`, `screenshot`,
  /// `verify_note` or `stress_matrix`: the bridge shapes their answers,
  /// and inside a step they would come back as raw JSON or base64.
  static const Set<String> stepTools = {
    'get_screen',
    'find_widgets',
    'flash',
    'get_state',
    'scan',
    'wait_idle',
    'tap',
    'long_press',
    'enter_text',
    'scroll',
    'scroll_to',
    'navigate',
    'back',
    'set_environment',
    'reset_environment',
    'get_trace',
    'why',
    'caused_by',
  };

  /// The most steps in one `run_steps`.
  static const int maxSteps = 20;

  /// `run_steps`: runs each step in order and stops at the first that
  /// fails. One round trip instead of one per step. Each step answers as
  /// its tool would, so a later step names its widget with a `target`
  /// query, not with a handle from an earlier step.
  Future<Map<String, Object?>> runSteps(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final steps = args['steps'];
    if (steps is! List<Object?> || steps.isEmpty) {
      throw const AgentError('steps is required: a list of {tool, …args}');
    }
    if (steps.length > maxSteps) {
      throw const AgentError('at most $maxSteps steps');
    }
    // Every step is checked before the first runs: a typo in step 3 must
    // not leave steps 1 and 2 done.
    for (final (i, step) in steps.indexed) {
      final tool = step is Map<String, Object?> ? step['tool'] : null;
      if (tool is! String || !stepTools.contains(tool)) {
        throw AgentError(
          'step ${i + 1}: ${tool is String ? '$tool cannot run in '
                    'run_steps' : 'give tool'}; use one of '
          '${stepTools.join(', ')}',
        );
      }
    }
    final done = <Map<String, Object?>>[];
    // Whether the step before changed the app.
    var changed = false;
    for (final (i, step) in steps.cast<Map<String, Object?>>().indexed) {
      cancel.check();
      final tool = step['tool']! as String;
      final input = {...step}..remove('tool');
      Map<String, Object?> answer;
      try {
        answer = changed && settledReads.contains(tool)
            ? await settledRead(tool, input, cancel)
            : await run(tool, input, cancel);
      } on AgentAborted {
        rethrow;
      } on Object catch (failure) {
        answer = AgentControl.error('$tool failed: $failure');
      }
      done.add({'step': i + 1, 'tool': tool, ...answer});
      changed = AgentControl.drivingTools.contains(tool);
      if (answer['ok'] != true) {
        return {
          'steps': done,
          'stopped': 'at step ${i + 1} of ${steps.length}',
        };
      }
    }
    return {'steps': done};
  }

  /// Reads that [runSteps] settles after a step that changed the app.
  static const Set<String> settledReads = {
    'find_widgets',
    'get_screen',
    'get_state',
    'scan',
  };

  /// [tool], a read right after a step that changed the app, read again on
  /// each frame until two reads agree: an animation the change started (a
  /// route coming in, a box growing) has then ended.
  ///
  /// Nothing waits for the app to be idle. A tap's ink ripple, or a spinner
  /// elsewhere on screen, keeps the app drawing frames for a long time but
  /// does not change the read: it costs one more read, not a wait. A
  /// fade alone changes no rect and is not seen; `wait_idle` covers it.
  /// Gives up at [AgentVerify.settleTimeout] and says `settled: false`.
  Future<Map<String, Object?>> settledRead(
    String tool,
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    var answer = await run(tool, args, cancel);
    final watch = Stopwatch()..start();
    while (answer['ok'] == true && AgentCommands.appIsMoving) {
      if (watch.elapsed >= AgentVerify.settleTimeout) {
        return {...answer, 'settled': false};
      }
      await AgentCommands._nextFrame();
      cancel.check();
      final again = await run(tool, args, cancel);
      // The first read's handles are dropped: reading on every frame must
      // not push out handles the agent holds (the table keeps 500).
      handles.forget(
        _handlesIn(answer['result']).where((id) => id != args['handle']),
      );
      if (again['ok'] != true || _sameRead(answer['result'], again['result'])) {
        return again;
      }
      answer = again;
    }
    return answer;
  }

  /// Every handle in a read.
  static Iterable<String> _handlesIn(Object? value) sync* {
    switch (value) {
      case Map<String, Object?>():
        if (value['handle'] case final String id) yield id;
        for (final item in value.values) {
          yield* _handlesIn(item);
        }
      case List<Object?>():
        for (final item in value) {
          yield* _handlesIn(item);
        }
    }
  }

  /// Whether two reads say the same, new handles aside.
  static bool _sameRead(Object? a, Object? b) =>
      jsonEncode(_withoutHandles(a)) == jsonEncode(_withoutHandles(b));

  static Object? _withoutHandles(Object? value) => switch (value) {
    Map<String, Object?>() => {
      for (final MapEntry(:key, :value) in value.entries)
        if (key != 'handle') key: _withoutHandles(value),
    },
    List<Object?>() => [for (final item in value) _withoutHandles(item)],
    _ => value,
  };

  /// [args] with its `target` query turned into a new `handle`, so every
  /// tool that takes a handle takes a target too. A target is found again
  /// on each call: it does not go stale as a handle can.
  Map<String, Object?> withTarget(Map<String, Object?> args) {
    final target = args['target'];
    if (target == null) return args;
    if (args['handle'] != null) {
      throw const AgentError('give handle or target, not both');
    }
    if (target is! Map<String, Object?>) {
      throw const AgentError(
        'target must be an object: file, line, type, text, key, index',
      );
    }
    final at = target['index'];
    final index = at is int ? at : 0;
    final found = matching(target, take: index + 1);
    if (index < 0) throw const AgentError('index must be 0 or more');
    if (index >= found.length) {
      // Perhaps not built yet: a page or a list that is coming in.
      throw AgentNotReady(
        found.isEmpty
            ? 'no widget matches the target ${jsonEncode(target)}'
            : 'the target matches ${found.length} widgets; index $index is '
                  'out of range',
      );
    }
    final element = found[index];
    return {
      for (final MapEntry(:key, :value) in args.entries)
        if (key != 'target') key: value,
      'handle': handles.add(element, _anchorOf(element)),
    };
  }
}
