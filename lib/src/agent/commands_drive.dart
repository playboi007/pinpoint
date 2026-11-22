part of 'commands.dart';

/// Waiting for the app to settle, routes and scroll positions.
extension AgentDrive on AgentCommands {
  /// The device pixel ratio, read from Pinpoint's own context.
  double get devicePixelRatio =>
      MediaQuery.maybeDevicePixelRatioOf(pageContext()) ?? 1;

  /// Gets the app ready for a driving command. Picking mode's pointer trap
  /// would swallow synthetic events (watch out for), so picking stops
  /// first. While the user writes a note, the agent waits its turn.
  Future<void> prepareToDrive() async {
    switch (controller.mode) {
      case PinPointMode.idle:
        return;
      case PinPointMode.picking:
        controller.stop();
        // The trap goes in the frame the stop scheduled.
        await _frame();
      case PinPointMode.commenting when controller.reviewing:
        // Only reading a note, with no trap: the app is live.
        return;
      case PinPointMode.commenting:
      case PinPointMode.sending:
        throw const AgentError(
          'the user is writing a note in Pinpoint; try again when they are '
          'done',
        );
    }
  }

  /// Returns when no frame is scheduled and no animation runs, twice in a
  /// row, or false at [timeout]. A frame the app draws anyway is waited
  /// for; none is forced while idle (engineering rule 2), and a looping
  /// spinner ends at the timeout instead of hanging.
  Future<bool> waitIdle(Duration timeout, AgentCancel cancel) async {
    final expired = Completer<void>();
    final timer = Timer(timeout, expired.complete);
    try {
      final scheduler = SchedulerBinding.instance;
      var quiet = 0;
      while (!expired.isCompleted) {
        cancel.check();
        if (AgentCommands.appIsMoving) {
          quiet = 0;
          await Future.any([scheduler.endOfFrame, expired.future]);
          continue;
        }
        if (++quiet >= 2) return true;
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 16)),
          expired.future,
        ]);
      }
      return false;
    } finally {
      timer.cancel();
    }
  }

  /// Waits for the frame a change scheduled; returns at once when none is.
  static Future<void> _frame() async {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.hasScheduledFrame ||
        scheduler.schedulerPhase != SchedulerPhase.idle) {
      await scheduler.endOfFrame;
    }
  }

  /// Pushes [path] as if the platform asked, through the navigation
  /// channel: `WidgetsBinding.handlePushRoute` is protected and
  /// visible-for-testing (docs/api-notes.md, item 12). Named-route apps and
  /// Router apps both listen to it. Returns whether someone handled it.
  static Future<bool> pushRoute(String path) => _navigation(
    MethodCall('pushRouteInformation', <String, Object?>{
      'location': path,
      'state': null,
    }),
  );

  /// Pops the current route as the back button does.
  static Future<bool> popRoute() => _navigation(const MethodCall('popRoute'));

  static Future<bool> _navigation(MethodCall call) {
    const codec = JSONMethodCodec();
    final done = Completer<bool>();
    // channelBuffers.push, not BinaryMessenger.handlePlatformMessage,
    // which is deprecated (docs/api-notes.md, item 12).
    ServicesBinding.instance.channelBuffers.push(
      SystemChannels.navigation.name,
      codec.encodeMethodCall(call),
      (reply) {
        if (done.isCompleted) return;
        try {
          done.complete(reply != null && codec.decodeEnvelope(reply) == true);
        } catch (_) {
          done.complete(false);
        }
      },
    );
    return done.future;
  }

  /// Every scroll position in the app and its offset, to put back after a
  /// command that moves things (verify, stress).
  List<(ScrollableState, double)> scrollSnapshot() {
    final found = <(ScrollableState, double)>[];
    var visited = 0;
    void visit(Element element) {
      if (++visited > 20000) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        try {
          if (state.position.hasPixels) {
            found.add((state, state.position.pixels));
          }
        } catch (_) {
          // No position yet.
        }
      }
      element.visitChildren(visit);
    }

    try {
      visit(contentRoot);
    } catch (_) {
      // The app is not on screen: nothing to put back.
    }
    return found;
  }

  /// Puts every scroll position of [snapshot] that is still there back.
  static void restoreScroll(List<(ScrollableState, double)> snapshot) {
    for (final (state, pixels) in snapshot) {
      if (!state.mounted) continue;
      try {
        final position = state.position;
        if (!position.hasContentDimensions) continue;
        position.jumpTo(
          pixels.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      } catch (_) {
        // Detached meanwhile.
      }
    }
  }

  /// Scrolls every scrollable above [element] so it shows. Uses
  /// `findAncestorStateOfType`, which subscribes nothing (engineering rule
  /// 3); `Scrollable.ensureVisible` would depend on the scope.
  Future<void> ensureVisible(Element element) async {
    final renderObject = AgentCommands.renderObjectOf(element);
    if (renderObject == null) return;
    if (RenderSearch.visibleRectOf(renderObject) case final shown?
        when shown.width > 0 && shown.height > 0) {
      final rect = RenderSearch.globalRectOf(renderObject);
      // Already wholly on screen.
      if (rect != null &&
          shown.width >= rect.width - 0.5 &&
          shown.height >= rect.height - 0.5) {
        return;
      }
    }
    var context = element;
    for (var steps = 0; steps < 8; steps++) {
      final scrollable = context.findAncestorStateOfType<ScrollableState>();
      if (scrollable == null) break;
      if (!renderObject.attached) break;
      await scrollable.position.ensureVisible(renderObject, alignment: 0.5);
      context = scrollable.context as Element;
    }
  }
}
