part of 'commands.dart';

/// What the agent reads from the flight recorder: causes, stories, watches.
extension AgentTrace on AgentCommands {
  /// The running flight recorder, or an error the agent can act on.
  static TraceSession _trace() =>
      TraceSession.current ??
      (throw const AgentError(
        'the flight recorder is off (PinPointConfig.trace: '
        'TraceConfig(enabled: false))',
      ));

  /// `get_trace`: the recorded events as compact lines (PLAN-v2
  /// Milestone 13).
  Map<String, Object?> getTrace(Map<String, Object?> args) {
    try {
      return traceAnswer(_trace().recorder, TraceQuery.fromArgs(args));
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
  }

  /// `trace_detail`: starts or stops level 3 for the agent, and says which
  /// sources run.
  Map<String, Object?> traceDetail(Map<String, Object?> args) {
    final on = args['on'];
    if (on is! bool) throw const AgentError('on is required: true or false');
    final session = _trace();
    if (on) {
      session
        ..demand(TraceDemand.agent)
        ..retryRebuilds();
    } else {
      session.release(TraceDemand.agent);
    }
    return session.detailStatus();
  }

  /// `watch`: follows the widget's State and the local States above it.
  Map<String, Object?> watch(Map<String, Object?> args) {
    final session = _trace();
    final target = element(args);
    final ancestors = args['ancestors'];
    final TraceWatch watch;
    try {
      watch = session.watch(
        target,
        states: ancestors is num
            ? ancestors.round()
            : WatchSource.defaultStates,
      );
    } on StateError catch (error) {
      throw AgentError(error.message);
    }
    final shown = watch.shown;
    final total = shown.values.fold(0, (a, b) => a + b);
    return {
      'id': watch.id,
      'widget': watch.widget,
      'states': [
        for (final MapEntry(:key, :value) in shown.entries)
          {'type': key, 'shown': value},
      ],
      'shown': total,
      // A state dump reads only what the State shows in its diagnostics
      // (watch out for): say so, so the agent reaches for a probe instead
      // of trusting a short list.
      'note':
          'only values a State lists in debugFillProperties are watched; '
          'private fields need a probe (PinPoint.probe)',
      'level3': session.detailStatus(),
    };
  }

  /// `unwatch`: removes one watch, or all with no id.
  Map<String, Object?> unwatch(Map<String, Object?> args) {
    final session = _trace();
    final id = args['id'];
    final removed = session.unwatch(id is String ? id : null);
    if (removed == 0 && id is String) {
      throw AgentError('no watch $id');
    }
    return {
      'removed': removed,
      'watches': [for (final w in session.watchSource.watches) w.id],
      'level3': session.detailStatus(),
    };
  }

  /// `why`: walks back from one event to the entry that started it
  /// (PLAN-v2 Milestone 14).
  Map<String, Object?> why(Map<String, Object?> args) {
    final seq = args['seq'];
    if (seq is! num) throw const AgentError('seq is required: an event seq');
    try {
      return whyAnswer(_trace().recorder, seq.round());
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
  }

  /// `caused_by`: what the widget's subtree started (PLAN-v2 Milestone 14).
  Map<String, Object?> causedBy(Map<String, Object?> args) {
    final session = _trace();
    final target = element(args);
    final TraceBound? since;
    try {
      since = TraceBound.parse(args['since'], 'since');
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
    return causedByAnswer(
      session.recorder,
      sources: subtreeSources(target, resolver()),
      widget: target.widget.runtimeType.toString().split('<').first,
      since: since,
    );
  }

  /// `state_flow`: why a value changed, from the state lens (PLAN-v3
  /// Milestone 21, step 8). With no window on [target], it opens one and
  /// answers what the target reads; with one open (or one that ended less
  /// than [StateLens.recentFor] ago) it answers the chain since arming.
  Map<String, Object?> stateFlow(Map<String, Object?> args) {
    final session = _trace();
    final target = element(args);
    final lens = session.stateLens;
    final seconds = args['seconds'];
    if (seconds != null && (seconds is! num || seconds <= 0)) {
      throw const AgentError('seconds is a number above 0, at most 30');
    }
    final window = seconds is num
        ? Duration(milliseconds: (seconds * 1000).round())
        : StateLens.defaultWindow;
    final armNow = args['rearm'] == true || !lens.wasTarget(target);
    if (armNow) {
      lens.arm(target, window: window);
      if (!lens.armed) {
        throw const AgentError(
          'the state lens could not be armed (the widget is not mounted)',
        );
      }
    }
    final state = lens.value;
    final summary = lens.stacksSummary;
    final notes = <String>[
      ?session.recorder.causeHint,
      if (!state.rebuildsRecorded)
        'rebuilds are not recorded (another tool holds the rebuild slot): '
            'the notifies are listed, the readers that rebuilt are not',
      if (summary != null && summary.dropped > 0)
        '${summary.dropped} setState stacks were dropped (cap '
            '${BuildStacks.defaultMaxPerSecond} a second)',
      if (summary?.failure != null) 'setState stacks: ${summary!.failure}',
    ];
    return {
      'armedNow': armNow,
      'armed': lens.armed,
      'target': {'type': state.targetType, 'source': state.targetSource},
      'seconds': state.window.inSeconds,
      'secondsLeft': lens.secondsLeft,
      'ended': ?state.endedBecause,
      'readers': lens.readersJson(),
      // The story of changes per cause (PLAN-v3 Milestone 21b): the
      // bridge writes it as text; the card shows the same blocks.
      'story': lens
          .story(
            StoryFilter(
              showHover: args['hover'] == true,
              showControllers: args['controllers'] == true,
            ),
          )
          .toJson(),
      if (notes.isNotEmpty) 'notes': notes,
    };
  }

  /// `mark`: a moment the agent points at.
  Map<String, Object?> mark(Map<String, Object?> args) {
    final text = args['text'];
    final event = _trace().mark(
      text: text is String ? text : null,
      by: 'agent',
    );
    return {'seq': event.seq, 't': event.t, 'frame': event.frame};
  }
}
