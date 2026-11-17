import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/overlay/replay_blocker.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';
import 'package:pinpoint/src/tape/tape_boot.dart';
import 'package:pinpoint/src/tape/tape_player.dart';
import 'package:pinpoint/src/trace/sources/network_source.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/agent_host.dart';
import '../support/fake_bridge.dart';
import '../support/fake_page.dart';

/// PLAN-v2 Milestone 15, build step 5: a full tape replays after a restart.
/// The page is a [FakePage]: its reload is counted, and a "restart" is the
/// app mounted again with the flag the reload left.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;
  late _App app;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
    app = _App();
  });

  tearDown(() {
    TapePlayer.debugReset();
    TapeBoot.debugReset();
    controller.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      agentApp(
        controller: controller,
        home: _Home(app: app),
      ),
    );
    await tester.pump();
  }

  Future<String> recordFullTape(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Count'));
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 50));
    final answer = await drive(
      tester,
      controller.agent.run('save_tape', const {}),
    );
    final summary = answer['result']! as Map<String, Object?>;
    expect(summary['kind'], 'full');
    return summary['id']! as String;
  }

  testWidgets('replay of a full tape leaves the flag and reloads the page '
      'after its answer', (tester) async {
    final id = await recordFullTape(tester);
    final page = FakePage();
    TapeBoot.debugReset(page: page);
    controller.agent.enabled = true;
    final answer = await drive(
      tester,
      controller.agent.run('replay', {'tape': id, 'speed': 2}),
    );
    final result = answer['result']! as Map<String, Object?>;
    expect(result['state'], 'restarting');
    final flag = BootFlag.decode(page.sessionGet(TapeBoot.key))!;
    expect(flag.tape, id);
    expect(flag.run, result['run']);
    expect(flag.options['speed'], 2);
    expect(flag.control, isTrue);
    expect(page.reloads, 0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(page.reloads, 1);
    await bridge.shutdown(tester);
  });

  testWidgets('a restarted page answers from the tape before the app\'s '
      'first build, plays the tape and reports the run', (tester) async {
    final id = await recordFullTape(tester);
    expect(app.count, 1);

    // The restart: a new page with the flag, and the app from scratch.
    await tester.pumpWidget(const SizedBox.shrink());
    final page = FakePage();
    TapeBoot.debugReset(page: page);
    TapeBoot.arm(
      BootFlag(
        tape: id,
        run: 'run_restart_0001',
        bridge: AgentBridge.url.toString(),
        control: true,
      ),
    );
    // As PinPoint.run would, before runApp.
    await TapeBoot.load();
    TapeBoot.loadedBeforeApp = true;
    app = _App();
    await pumpApp(tester);
    expect(app.replayAtFirstBuild, isTrue);
    expect(page.sessionGet(TapeBoot.key), isNull);

    await drive(
      tester,
      Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return bridge.notes.runStatus['run_restart_0001']?['state'] != 'done';
      }),
    );
    final status = bridge.notes.runStatus['run_restart_0001']!;
    expect(status['state'], 'done', reason: '$status');
    expect(status['kind'], 'full');
    expect(app.count, 1);
    expect(controller.agent.enabled, isTrue);
    expect(ReplayGate.blocking.value, isFalse);
    expect(
      (TraceSession.current!.source('network')! as NetworkSource).replay,
      isNull,
    );
    await bridge.shutdown(tester);
  });

  testWidgets('a tape that does not load is reported, and input comes back', (
    tester,
  ) async {
    TapeBoot.debugReset(page: FakePage());
    TapeBoot.arm(
      BootFlag(
        tape: 'tp_missing_0000',
        run: 'run_missing_0001',
        bridge: AgentBridge.url.toString(),
      ),
    );
    await pumpApp(tester);
    await drive(
      tester,
      Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return !bridge.notes.runStatus.containsKey('run_missing_0001');
      }),
    );
    final status = bridge.notes.runStatus['run_missing_0001']!;
    expect(status['state'], 'stopped');
    expect('${status['reason']}', contains('tp_missing_0000'));
    expect(ReplayGate.blocking.value, isFalse);
    expect(TraceSession.current!.tapes.replaying, isFalse);
    await bridge.shutdown(tester);
  });

  group('PinPoint.run on a restarted page', () {
    late FakeBridge fake;

    setUp(() {
      fake = FakeBridge();
      BridgeClient.debugClient = fake.client;
    });

    tearDown(() => BridgeClient.debugClient = null);

    test('runs the app only once the tape is loaded, and puts storage back '
        'when TraceConfig.storage is on', () async {
      final tape = Tape(
        id: 'tp_storage_0000',
        kind: TapeKind.full,
        start: const TapeStart(
          t: 0,
          seq: 1,
          wallTime: 'w',
          storage: {
            'local': {'session': 'abc'},
          },
        ),
      );
      fake.tapes[tape.id] = {'tape': tape.toJson(), 'bodies': const {}};
      final page = FakePage(
        storage: {
          'local': {'session': 'expired'},
          'session': <String, String>{},
        },
      );
      TapeBoot.debugReset(page: page);
      TapeBoot.arm(
        BootFlag(
          tape: tape.id,
          run: 'run_storage_0001',
          bridge: 'http://127.0.0.1:4747',
        ),
      );
      var ran = false;
      PinPoint.run(() {
        ran = true;
      }, trace: const TraceConfig(storage: true));
      expect(ran, isFalse);
      await TapeBoot.load();
      await Future<void>.delayed(Duration.zero);
      expect(ran, isTrue);
      expect(TapeBoot.loadedBeforeApp, isTrue);
      expect(page.storage['local'], {'session': 'abc'});
    });

    test('with no flag, the body runs at once', () {
      TapeBoot.debugReset(page: FakePage());
      var ran = false;
      PinPoint.run(() {
        ran = true;
      });
      expect(ran, isTrue);
    });
  });
}

class _App {
  int count = 0;
  bool? replayAtFirstBuild;
}

class _Home extends StatefulWidget {
  const _Home({required this.app});

  final _App app;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    // Where an app makes its first request.
    final network = TraceSession.current?.source('network');
    widget.app.replayAtFirstBuild =
        network is NetworkSource && network.replay != null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => widget.app.count++,
        child: const Text('Count'),
      ),
    ),
  );
}
