import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/search/source_index.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../support/agent_host.dart';
import '../support/markers.dart';

const String _file = 'test/agent/verify_note_test.dart';

/// Milestone 12, build step 3: `verify_note` closes the loop. It applies
/// the note's environment, goes to its route, waits for idle, finds the
/// widget by its anchor, runs each check, takes an after screenshot and
/// restores everything.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;
  late ValueNotifier<bool> fixed;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
    fixed = ValueNotifier<bool>(false);
  });
  tearDown(() {
    controller.dispose();
    fixed.dispose();
  });

  Future<void> pumpApp(WidgetTester tester, {Widget? home}) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      agentApp(
        controller: controller,
        home: home ?? _Planted(fixed: fixed),
        routes: {'/zoo': (_) => _Planted(fixed: fixed)},
      ),
    );
    await tester.pump();
    controller.agent.enabled = true;
    await tester.pump();
  }

  /// The anchor of the planted Row, as the note was filed with it.
  NoteAnchor rowAnchor({int shift = 0, String? route}) {
    final line = markerLine(_file, 'row');
    return NoteAnchor(
      file: _file,
      line: line + shift,
      column: shift == 0 ? markerColumn(_file, 'row', 'Row(') : null,
      widget: 'Row',
      route: route,
    );
  }

  Map<String, Object?> note(
    NoteAnchor anchor, {
    List<Object?>? checks,
    Map<String, Object?>? environment = const {
      'viewport': {'width': 360, 'height': 800},
    },
  }) => {
    'id': 'pp_overflow',
    'anchor': anchor.toJson(),
    'environment': environment,
    'checks':
        checks ??
        [
          {'type': 'no_overflow'},
        ],
  };

  Future<Map<String, Object?>> verify(
    WidgetTester tester,
    Map<String, Object?> note,
  ) async {
    final answer = await drive(
      tester,
      controller.agent.run('verify_note', {'note': note}),
      realTime: true,
    );
    expect(answer['ok'], isTrue, reason: '$answer');
    return answer['result']! as Map<String, Object?>;
  }

  List<Map<String, Object?>> checksOf(Map<String, Object?> result) =>
      (result['checks']! as List<Object?>).cast<Map<String, Object?>>();

  testWidgets('acceptance: for the planted overflow, verify_note fails '
      'before the fix and passes after a hot reload with the fix', (
    tester,
  ) async {
    await pumpApp(tester);
    // At 800 wide the Row fits: only the note's 360 viewport shows it.
    expect(tester.takeException(), isNull);

    final before = await verify(tester, note(rowAnchor()));
    expect(before['passed'], isFalse);
    final failed = checksOf(before).single;
    expect(failed['type'], 'no_overflow');
    expect(failed['passed'], isFalse);
    expect(failed['message'], contains('overflows by 72 px'));
    expect(before['png'], isA<String>(), reason: 'the after screenshot');
    // Flutter reported the overflow while the note's viewport was on.
    expect(tester.takeException(), isFlutterError);

    // The agent's fix, then a hot reload. Edits above the Row moved its
    // line: the anchor still names the old one.
    fixed.value = true;
    await drive(tester, tester.binding.reassembleApplication());
    final after = await verify(tester, note(rowAnchor(shift: 2)));
    expect(after['passed'], isTrue, reason: '${after['checks']}');
    expect(checksOf(after).single['passed'], isTrue);
    expect(after['found'], endsWith('$_file:${markerLine(_file, 'row')}'));
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: the environment and the scroll position are '
      'restored after verify_note', (tester) async {
    await pumpApp(tester, home: _Long(fixed: fixed));
    controller.environment.update((e) => e.copyWith(textScale: () => 1.2));
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    scroll.position.jumpTo(300);
    await tester.pump();

    final result = await verify(
      tester,
      note(
        NoteAnchor(
          file: _file,
          line: markerLine(_file, 'deep'),
          widget: 'Text',
        ),
        checks: [
          {'type': 'visible'},
          {'type': 'text_contains', 'text': 'Deep'},
        ],
        // Filed with no override: verify takes the text scale off, then
        // puts it back.
        environment: null,
      ),
    );
    // Scrolled into view to measure it.
    expect(result['passed'], isTrue, reason: '${result['checks']}');
    expect(controller.environment.value.textScale, 1.2);
    expect(controller.environment.value.viewport, isNull);
    expect(scroll.position.pixels, 300);
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: a widget that no longer resolves fails every '
      'check with "anchor not found"', (tester) async {
    await pumpApp(tester);
    final result = await verify(
      tester,
      note(
        const NoteAnchor(file: _file, line: 3, widget: 'Placeholder'),
        checks: [
          {'type': 'no_overflow'},
          {'type': 'visible'},
        ],
      ),
    );
    expect(result['passed'], isFalse);
    expect(result['found'], isNull);
    // The note's 360 viewport made the planted Row overflow meanwhile.
    expect(tester.takeException(), isFlutterError);
    for (final check in checksOf(result)) {
      expect(check['passed'], isFalse);
      expect(check['message'], 'anchor not found');
    }
    await bridge.shutdown(tester);
  });

  testWidgets("goes to the note's route when the widget is not on screen, "
      'and comes back', (tester) async {
    await pumpApp(tester, home: const _Home());
    final result = await verify(
      tester,
      note(rowAnchor(route: '/zoo')),
    );
    expect(result['passed'], isFalse, reason: 'found and measured');
    expect(result['found'], isNotNull);
    expect(tester.takeException(), isFlutterError);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(_Planted), findsNothing, reason: 'popped again');
    await bridge.shutdown(tester);
  });

  testWidgets('a note with no checks is checked for visible', (tester) async {
    await pumpApp(tester);
    final result = await verify(tester, note(rowAnchor(), checks: const []));
    expect(checksOf(result).map((c) => c['type']), ['visible']);
    expect(tester.takeException(), isFlutterError);
    await bridge.shutdown(tester);
  });

  testWidgets('the anchor of a note resolves through SourceIndex', (
    tester,
  ) async {
    await pumpApp(tester);
    final index = SourceIndex(resolver: const SourceResolver());
    final root = tester.element(find.byType(_Planted));
    expect(index.resolve(rowAnchor(shift: 2), root: root), isNotNull);
    await bridge.shutdown(tester);
  });
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Home')));
}

class _Planted extends StatelessWidget {
  const _Planted({required this.fixed});

  final ValueNotifier<bool> fixed;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ValueListenableBuilder<bool>(
        valueListenable: fixed,
        builder: (context, isFixed, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // PIN:row
            Row(
              children: [
                SizedBox(width: isFixed ? 100 : 200, height: 24),
                SizedBox(width: isFixed ? 100 : 200, height: 24),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _Long extends StatelessWidget {
  const _Long({required this.fixed});

  final ValueNotifier<bool> fixed;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        // At 960 px: built (in the cache extent) but below the screen
        // at a scroll of 300.
        for (var i = 0; i < 16; i++) SizedBox(height: 60, child: Text('row $i')),
        const Text('Deep'), // PIN:deep
        for (var i = 0; i < 30; i++) const SizedBox(height: 60),
      ],
    ),
  );
}
