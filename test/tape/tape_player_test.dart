import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/replay_blocker.dart';
import 'package:pinpoint/src/tape/tape_player.dart';
import 'package:pinpoint/src/trace/sources/network_source.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/agent_host.dart';

/// PLAN-v2 Milestone 15, build step 4: input replay of segment tapes, live,
/// with no restart. Real taps from `tester` are the user; the replay sends
/// its own.
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
    controller.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      agentApp(
        controller: controller,
        home: _Home(app: app),
        routes: {'/form': (_) => _FormPage(app: app)},
      ),
    );
    await tester.pump();
  }

  /// A real tap, with the zero timer that fills its anchor.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<String> save(WidgetTester tester, {Object since = 'mark:1'}) async {
    final answer = await drive(
      tester,
      controller.agent.run('save_tape', {'since': since}),
    );
    expect(answer['ok'], isTrue, reason: '$answer');
    return (answer['result']! as Map<String, Object?>)['id']! as String;
  }

  Future<Map<String, Object?>> replay(
    WidgetTester tester,
    String tape, [
    Map<String, Object?> args = const {},
  ]) async {
    controller.agent.enabled = true;
    final answer = await drive(
      tester,
      controller.agent.run('replay', {'tape': tape, ...args}),
    );
    expect(answer['ok'], isTrue, reason: '$answer');
    return answer['result']! as Map<String, Object?>;
  }

  List<TraceEvent> since(int seq, String kind) => [
    for (final e in TraceSession.current!.recorder.events)
      if (e.seq > seq && e.kind == kind) e,
  ];

  testWidgets('acceptance: with the button moved 200 px by a code change, '
      'the tap still lands on it', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark();
    await tap(tester, find.text('Count'));
    expect(app.count, 1);
    final id = await save(tester);

    app.shift.value = 200; // the "code change"
    await tester.pump();
    final result = await replay(tester, id);
    expect(result['state'], 'done', reason: '$result');
    expect(app.count, 2);
    expect(result['first_difference'], isNull);
    expect(ReplayGate.blocking.value, isFalse);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: with the button removed, the replay stops with '
      'replay.diverged and names the step', (tester) async {
    await pumpApp(tester);
    final start = TraceSession.current!.mark().seq;
    await tap(tester, find.text('Count'));
    final id = await save(tester);

    app.hidden.value = true;
    await tester.pump();
    final result = await replay(tester, id);
    expect(result['state'], 'diverged', reason: '$result');
    expect('${result['reason']}', contains('step 1'));
    expect((result['first_difference']! as Map)['step'], 1);
    final diverged = since(start, TraceKind.replayDiverged).single;
    expect(diverged.data['step'], 1);
    expect(diverged.data['widget'], 'Text');
    // Restored after the stop.
    expect(TapePlayer.current, isNull);
    expect(ReplayGate.blocking.value, isFalse);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance (segment): a form is filled and sent again: same '
      'route order, same field value', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark();
    await tap(tester, find.text('Open form'));
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('name')));
    await tester.enterText(find.byKey(const Key('name')), 'Ada');
    await tester.pump(const Duration(milliseconds: 50));
    await tap(tester, find.text('Send'));
    await tester.pumpAndSettle();
    expect(app.sent, ['Ada']);
    await tester.pump(const Duration(seconds: 1)); // the route's late read
    final id = await save(tester);

    final result = await replay(tester, id);
    expect(result['state'], 'done', reason: '$result');
    expect(app.sent, ['Ada', 'Ada']);
    expect(result['first_difference'], isNull, reason: '$result');
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: a replay at speed 4 gives the same route order as '
      'at speed 1', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark();
    await tap(tester, find.text('Open form'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tap(tester, find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    final id = await save(tester);

    List<Object?> routesOf(int from) => [
      for (final e in since(from, TraceKind.route)) e.data['to'],
    ];
    final one = TraceSession.current!.recorder.nextSeq;
    final slow = await replay(tester, id);
    final four = TraceSession.current!.recorder.nextSeq;
    final fast = await replay(tester, id, {'speed': 4});
    expect(slow['state'], 'done');
    expect(fast['state'], 'done');
    expect(routesOf(one).take(2), ['/form', '/']);
    expect(routesOf(four), routesOf(one).sublist(0, routesOf(four).length));
    expect(fast['first_difference'], isNull, reason: '$fast');
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: replay until mark:1 holds there; get_state and '
      'screenshot work; real taps do nothing; resume goes on', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark(text: 'start');
    await tap(tester, find.text('Count'));
    TraceSession.current!.mark(text: 'after one');
    await tap(tester, find.text('Count'));
    expect(app.count, 2);
    final id = await save(tester);

    final held = await replay(tester, id, {'until': 'mark:2'});
    expect(held['state'], 'held', reason: '$held');
    expect(held['step'], 2); // down and up of the first tap
    expect(app.count, 3);
    expect(find.byKey(ReplayBlocker.bannerKey), findsOneWidget);

    // Real input is blocked while it holds.
    await tester.tap(find.text('Count'), warnIfMissed: false);
    await tester.pump();
    expect(app.count, 3);

    final state = await drive(
      tester,
      controller.agent.run('get_state', {
        'target': {'type': '_Home'},
      }),
    );
    expect(state['ok'], isTrue, reason: '$state');
    final shot = await drive(
      tester,
      controller.agent.run('screenshot', const {}),
      realTime: true,
    );
    expect(shot['ok'], isTrue, reason: '$shot');

    final done = await drive(
      tester,
      controller.agent.run('resume_replay', const {}),
    );
    expect((done['result']! as Map)['state'], 'done', reason: '$done');
    expect(app.count, 4);
    expect(ReplayGate.blocking.value, isFalse);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: Esc during a replay restores input and the '
      'network source', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark();
    await tap(tester, find.text('Count'));
    TraceSession.current!.mark();
    final id = await save(tester, since: 'mark:1');

    final held = await replay(tester, id, {'until': 'mark:1'});
    expect(held['state'], 'held');
    final network =
        TraceSession.current!.source('network')! as NetworkSource;
    expect(network.replay, isNotNull);
    expect(TraceSession.current!.tapes.replaying, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    expect(TapePlayer.current, isNull);
    expect(ReplayGate.blocking.value, isFalse);
    expect(network.replay, isNull);
    expect(TraceSession.current!.tapes.replaying, isFalse);
    // Input reaches the app again.
    final before = app.count;
    await tap(tester, find.text('Count'));
    expect(app.count, before + 1);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance (stream): a replay\'s events and its end reach '
      'the bridge before the answer', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark();
    await tap(tester, find.text('Count'));
    final id = await save(tester);
    final result = await replay(tester, id);
    final run = result['run']! as String;
    final kinds = [
      for (final e in bridge.notes.runEvents[run]!) e['kind'],
    ];
    expect(kinds.first, TraceKind.replayStart);
    expect(kinds, contains(TraceKind.replayStep));
    expect(kinds.last, TraceKind.replayEnd);
    expect(bridge.notes.runStatus[run]!['state'], 'done');
    // Each event goes once.
    final seqs = [for (final e in bridge.notes.runEvents[run]!) e['seq']];
    expect(seqs.toSet().length, seqs.length);
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: the player\'s own taps are tagged agent and '
      'go into no new tape', (tester) async {
    await pumpApp(tester);
    TraceSession.current!.mark();
    await tap(tester, find.text('Count'));
    final id = await save(tester);
    await replay(tester, id);
    // A tape from app start can only start after the replay now, and the
    // replay's taps are not in it.
    final again = TraceSession.current!.saveTape();
    expect(again.inputs, isEmpty);
    expect(again.partialReason, contains('replay'));
    final agentDowns = [
      for (final e in TraceSession.current!.recorder.events)
        if (e.kind == TraceKind.pointer && e.data['by'] == 'agent') e,
    ];
    expect(agentDowns, isNotEmpty);
    await bridge.shutdown(tester);
  });
}

class _App {
  int count = 0;
  final List<String> sent = <String>[];
  final ValueNotifier<double> shift = ValueNotifier<double>(0);
  final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);
}

class _Home extends StatelessWidget {
  const _Home({required this.app});

  final _App app;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pushNamed('/form'),
          child: const Text('Open form'),
        ),
        ValueListenableBuilder<double>(
          valueListenable: app.shift,
          builder: (context, shift, _) => ValueListenableBuilder<bool>(
            valueListenable: app.hidden,
            builder: (context, hidden, _) => Padding(
              padding: EdgeInsets.only(top: 20 + shift),
              child: hidden
                  ? const SizedBox(width: 100, height: 40)
                  : ElevatedButton(
                      onPressed: () => app.count++,
                      child: const Text('Count'),
                    ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _FormPage extends StatefulWidget {
  const _FormPage({required this.app});

  final _App app;

  @override
  State<_FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<_FormPage> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Form')),
    body: Column(
      children: [
        TextField(key: const Key('name'), controller: _name),
        ElevatedButton(
          onPressed: () {
            widget.app.sent.add(_name.text);
            Navigator.of(context).pop();
          },
          child: const Text('Send'),
        ),
      ],
    ),
  );
}
