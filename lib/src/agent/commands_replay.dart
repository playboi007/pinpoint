part of 'commands.dart';

/// Tapes and replays: saving, starting, resuming and stopping them.
extension AgentReplay on AgentCommands {
  /// `save_tape`: a tape of the run from `since`, stored on the bridge
  /// Answers its summary only: a tool answer never carries a body.
  Future<Map<String, Object?>> saveTape(Map<String, Object?> args) async {
    final session = AgentTrace._trace();
    final client = bridge?.call();
    if (client == null) {
      throw const AgentError('save_tape needs the bridge: no bridge is set');
    }
    final name = args['name'];
    final Tape tape;
    try {
      tape = session.saveTape(
        since: TapeSince.parse(args['since']),
        name: name is String && name.isNotEmpty ? name : null,
      );
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
    try {
      return await client.saveTape(tape);
    } on HttpSinkException catch (error) {
      throw AgentError('the bridge did not take the tape: ${error.message}');
    }
  }

  /// What the tape player needs from this app.
  ReplayHost replayHost(TraceSession session) => ReplayHost(
    session: session,
    resolve: (anchor) {
      try {
        final element = sourceIndex().resolve(anchor, root: contentRoot);
        return element != null && sameSpot(element, anchor) ? element : null;
      } on AgentError {
        return null;
      }
    },
    widgetAt: _widgetAt,
    prepare: prepareToDrive,
    postMessage: browserPage().postMessage,
    isOnApp: (point) {
      try {
        return RenderSearch.isOnApp(appRoot, point);
      } on AgentError {
        return false;
      }
    },
  );

  /// Whether [element] is where [anchor] was made, closely enough for a
  /// replay to tap it. The resolver's nearest-line match (made for pins
  /// after an edit) would take another widget of the same type in the file
  /// when the one in the tape is gone. A replay accepts a moved line only
  /// at the same column (the same nesting) and at most [maxLineShift]
  /// lines away; anything else counts as gone, and the player diverges.
  bool sameSpot(Element element, NoteAnchor anchor) {
    final line = anchor.line;
    if (line == null) return true;
    final location = resolver().locationOf(element);
    if (location == null) return false;
    if (location.line == line) return true;
    return location.column == anchor.column &&
        (location.line - line).abs() <= maxLineShift;
  }

  /// How far an edit may move a tapped widget's line for a replay.
  static const int maxLineShift = 50;

  /// The type of the local widget under [position], as a pick finds it.
  String? _widgetAt(Offset position) {
    final appContext = appKey.currentContext;
    final root = appContext?.findRenderObject();
    final content = contentKey.currentContext;
    if (appContext is! Element || root == null || content is! Element) {
      return null;
    }
    final pick = PickResult.fromSearch(
      RenderSearch.find(root, position),
      position: position,
      rootElement: appContext,
      chainBoundary: content,
      resolver: resolver(),
    );
    if (pick == null || pick.sourceUnavailable) return null;
    return pick.chain[pick.chainIndex].name;
  }

  /// The fastest `speed` a replay takes.
  static const double maxSpeed = 20;

  /// `replay`: plays a tape's inputs into the app while the network source
  /// answers from it. Answers when the replay ends
  /// or holds at `until`.
  Future<Map<String, Object?>> replay(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final session = AgentTrace._trace();
    if (TapePlayer.current != null) {
      throw AgentError(
        'a replay runs already (${TapePlayer.current!.runId}); use '
        'resume_replay or stop_replay',
      );
    }
    final id = args['tape'];
    if (id is! String || !tapeIdPattern.hasMatch(id)) {
      throw const AgentError('tape is required: a tape id (tp_…)');
    }
    final client = bridge?.call();
    if (client == null) {
      throw const AgentError('replay needs the bridge: no bridge is set');
    }
    final Tape? tape;
    try {
      tape = await client.loadTape(id);
    } on HttpSinkException catch (error) {
      throw AgentError('the bridge did not give the tape: ${error.message}');
    }
    if (tape == null) throw AgentError('no tape $id');
    if (tape.kind == TapeKind.full && args['restart'] != false) {
      return _restart(tape, args, client);
    }
    return _play(tapePlayer(tape, args, session), cancel);
  }

  /// The options of `replay` a restarted page needs again.
  static const List<String> _replayOptions = [
    'until',
    'speed',
    'unmatched',
    'latency',
  ];

  /// A full tape replays after a restart: in-memory state such as
  /// a parent's cache is part of most real bugs, and only a restart brings
  /// it back to a known value. The flag goes to `sessionStorage`, the page
  /// reloads, and at start Pinpoint loads the tape before the app runs.
  /// The bridge waits for the new page to report the run.
  Map<String, Object?> _restart(
    Tape tape,
    Map<String, Object?> args,
    BridgeClient client,
  ) {
    final page = TapeBoot.page;
    if (!page.available) {
      throw const AgentError(
        'a full tape replays after a restart, which works on web only. '
        'Give restart: false to play it from where the app is, or save a '
        'segment (save_tape since a mark)',
      );
    }
    // Checked now: the new page cannot answer a bad option.
    tapePlayer(tape, args, AgentTrace._trace());
    final run = args['run'] is String && runIdPattern.hasMatch('${args['run']}')
        ? args['run']! as String
        : newRunId();
    TapeBoot.arm(
      BootFlag(
        tape: tape.id,
        run: run,
        bridge: client.base.toString(),
        options: {
          for (final key in _replayOptions)
            if (args[key] != null) key: args[key],
        },
        control: controller.agent.enabled,
      ),
    );
    // After this answer has gone to the bridge. A page reload loads what
    // the web server serves. Whether that includes code a hot reload
    // compiled is unverified; if it does not, a full replay after a fix
    // needs a hot restart from Flutter Tools instead of a reload.
    Timer(const Duration(milliseconds: 500), page.reload);
    return {'run': run, 'tape': tape.id, 'kind': 'full', 'state': 'restarting'};
  }

  /// Starts the replay of a page a replay restarted, once, after
  /// the first frame. Reports each hold and the end to the bridge, where
  /// the agent's `replay` waits.
  Future<void> startBootReplay() async {
    final flag = TapeBoot.flag;
    if (flag == null || TapeBoot.started) return;
    TapeBoot.started = true;
    final client = BridgeClient(Uri.parse(flag.bridge));
    final session = TraceSession.current;
    final tape = await TapeBoot.load();
    if (session == null || tape == null) {
      ReplayGate.clear();
      session?.tapes.replaying = false;
      await _report(client, flag.run, {
        'run': flag.run,
        'tape': flag.tape,
        'state': 'stopped',
        'reason': session == null
            ? 'the flight recorder is off'
            : TapeBoot.error ?? 'the tape did not load',
      });
      return;
    }
    // The replay was the agent's: control comes back on, so it can resume
    // or stop it. Turned off after every restart otherwise.
    if (flag.control) controller.agent.enabled = true;
    final TapePlayer player;
    try {
      player = tapePlayer(
        tape,
        {...flag.options, 'run': flag.run},
        session,
        net: TapePlayer.bootNet,
        // The whole record of a restarted page is the run.
        streamFrom: 1,
        notes: [
          if (!TapeBoot.loadedBeforeApp)
            'no PinPoint.run in main: requests before the tape loaded '
                'reached the server',
        ],
      );
    } on AgentError catch (error) {
      ReplayGate.clear();
      session.tapes.replaying = false;
      await _report(client, flag.run, {
        'run': flag.run,
        'state': 'stopped',
        'reason': error.message,
      });
      return;
    }
    // The player reports each hold and the end to the bridge itself.
    await player.start();
  }

  static Future<void> _report(
    BridgeClient client,
    String run,
    Map<String, Object?> status,
  ) async {
    try {
      await client.postRunStatus(run, status);
    } catch (error) {
      debugPrint('pinpoint: could not report replay $run: $error');
    }
  }

  /// A player for [tape] with the options in [args]. Throws an
  /// [AgentError] for a bad option.
  TapePlayer tapePlayer(
    Tape tape,
    Map<String, Object?> args,
    TraceSession session, {
    NetReplay? net,
    List<String> notes = const <String>[],
    int? streamFrom,
  }) {
    final speed = args['speed'] ?? 1;
    if (speed is! num || speed <= 0 || speed > maxSpeed) {
      throw const AgentError('speed is a number above 0, at most 20');
    }
    final unmatched = Unmatched.byName(args['unmatched'] ?? 'fail');
    if (unmatched == null) {
      throw const AgentError('unmatched is fail, passthrough or last');
    }
    final latency = ReplayLatency.parse(args['latency']);
    if (latency == null) {
      throw const AgentError('latency is recorded, instant or a number of ms');
    }
    ReplayUntil? until;
    try {
      if (args['until'] != null) until = ReplayUntil.parse(args['until'], tape);
    } on FormatException catch (error) {
      throw AgentError(error.message);
    }
    final given = args['run'];
    final run = given is String && runIdPattern.hasMatch(given)
        ? given
        : newRunId();
    final client = bridge?.call();
    return TapePlayer(
      tape: tape,
      host: replayHost(session),
      speed: speed.toDouble(),
      until: until,
      unmatched: unmatched,
      latency: latency,
      runId: run,
      net: net,
      notes: notes,
      streamFrom: streamFrom,
      // The run lives on the bridge: its events in batches, and
      // where it is at each hold and at the end.
      stream: client == null
          ? null
          : (events) => client.postRunEvents(run, events),
      report: client == null
          ? null
          : (status) => client.postRunStatus(run, status),
    );
  }

  /// Runs [player] until it holds or ends. Esc, or control turned off,
  /// stops it.
  Future<Map<String, Object?>> _play(
    TapePlayer player,
    AgentCancel cancel,
  ) async {
    try {
      return await _untilSettled(player.start(), player, cancel);
    } on StateError catch (error) {
      throw AgentError(error.message);
    }
  }

  Future<Map<String, Object?>> _untilSettled(
    Future<Map<String, Object?>> settled,
    TapePlayer player,
    AgentCancel cancel,
  ) async {
    var done = false;
    final answer = settled.whenComplete(() => done = true);
    while (!done) {
      await Future.any([
        answer,
        Future<void>.delayed(const Duration(milliseconds: 50)),
      ]);
      if (!done && cancel.cancelled) {
        player.stop(reason: 'agent control turned off');
        return player.ended;
      }
    }
    return answer;
  }

  /// `resume_replay`: goes on after a hold.
  Future<Map<String, Object?>> resumeReplay(AgentCancel cancel) async {
    final player = TapePlayer.current;
    if (player == null || player.state != ReplayState.held) {
      throw const AgentError('no replay holds; start one with replay');
    }
    await prepareToDrive();
    return _untilSettled(player.resume(), player, cancel);
  }

  /// `stop_replay`: ends the replay and puts input and network back.
  Future<Map<String, Object?>> stopReplay() async {
    final player = TapePlayer.current;
    if (player == null) throw const AgentError('no replay runs');
    player.stop(reason: 'stop_replay');
    return player.ended;
  }
}
