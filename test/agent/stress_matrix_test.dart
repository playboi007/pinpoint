import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/stress_matrix.dart';

import '../support/agent_host.dart';

/// Milestone 12, build step 5: `stress_matrix`, orchestration over the
/// what-if switches and the detectors, and the small tools it uses.
void main() {
  group('the runs', () {
    const base = Environment(textScale: 1.1);

    test('one axis at a time around the current environment: 4 widths, '
        '3 text scales, RTL, dark', () {
      final runs = stressRuns(base: base, height: 800);
      expect(runs.map((r) => r.label), [
        'width 320',
        'width 360',
        'width 414',
        'width 768',
        'text 1.3×',
        'text 1.6×',
        'text 2×',
        'RTL',
        'dark',
      ]);
      expect(runs.first.environment.viewport, const Size(320, 800));
      expect(runs.first.environment.textScale, 1.1, reason: 'kept');
      expect(runs[4].environment.viewport, isNull);
      expect(runs.last.environment.brightness, Brightness.dark);
    });

    test('full runs the whole product, at most 48', () {
      final small = stressRuns(
        base: Environment.none,
        height: 800,
        widths: [320, 768],
        textScales: [1, 2],
        directions: [TextDirection.ltr, TextDirection.rtl],
        brightness: [Brightness.light],
        full: true,
      );
      expect(small, hasLength(8));
      expect(small.first.label, 'width 320 · text 1× · LTR · light');
      final big = stressRuns(
        base: Environment.none,
        height: 800,
        widths: [for (var w = 300; w < 1000; w += 50) w.toDouble()],
        textScales: [1, 1.5, 2],
        directions: [TextDirection.ltr, TextDirection.rtl],
        full: true,
      );
      expect(big, hasLength(stressMaxRuns));
    });
  });

  group('in the app', () {
    late PinPointController controller;
    late AgentBridge bridge;

    setUp(() {
      controller = PinPointController();
      bridge = AgentBridge();
    });
    tearDown(() => controller.dispose());

    Future<void> pumpApp(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(agentApp(controller: controller, home: home));
      await tester.pump();
      controller.agent.enabled = true;
      await tester.pump();
    }

    Future<Map<String, Object?>> ok(
      WidgetTester tester,
      String tool, [
      Map<String, Object?> args = const {},
    ]) async {
      final answer = await drive(
        tester,
        controller.agent.run(tool, args),
        realTime: true,
      );
      expect(answer['ok'], isTrue, reason: '$tool: $answer');
      return answer['result']! as Map<String, Object?>;
    }

    List<Map<String, Object?>> list(Object? value) =>
        (value! as List<Object?>).cast<Map<String, Object?>>();

    /// Flutter's own reports of the planted overflow, one per width that
    /// shows it the first time.
    void takeOverflowReports(WidgetTester tester) {
      while (tester.takeException() != null) {}
    }

    testWidgets('the width-dependent overflow shows only at the narrow '
        'widths; each distinct problem becomes one draft note with its '
        'environment and check; text cut off is never filed alone', (
      tester,
    ) async {
      await pumpApp(tester, const _Zoo());
      final result = await ok(tester, 'stress_matrix', {
        'kinds': ['overflow', 'truncated_text'],
        'thumbnails': false,
      });
      takeOverflowReports(tester);
      final runs = list(result['runs']);
      expect(runs, hasLength(9));
      final findings = list(result['findings']);
      final overflow = findings.singleWhere((f) => f['kind'] == 'overflow');
      // Two 180 px boxes and 32 px padding: over at 320 and 360 only.
      expect(overflow['runs'], [1, 2]);
      final cut = findings.singleWhere((f) => f['kind'] == 'truncated_text');
      expect((cut['runs']! as List).length, greaterThan(1));

      final drafts = (result['drafts']! as List<Object?>).cast<String>();
      expect(drafts, hasLength(1), reason: 'the overflow, not the cut text');
      final note = controller.notes.byId(drafts.single)!;
      expect(note.status, NoteStatus.draft);
      expect(note.environment, {
        'viewport': {'width': 320, 'height': 900},
      });
      expect(note.checks, [
        {'type': 'no_overflow'},
      ]);
      expect(note.finding?['kind'], 'overflow');
      expect(note.comment, contains('Row overflows'));
      await bridge.shutdown(tester);
    });

    testWidgets('run twice, it reports the same findings and files no '
        'second draft: no state leaks between runs', (tester) async {
      await pumpApp(tester, const _Zoo());
      final args = {
        'widths': [320, 768],
        'textScales': <num>[],
        'directions': <String>[],
        'brightness': <String>[],
        'kinds': ['overflow', 'truncated_text'],
        'thumbnails': false,
      };
      final first = await ok(tester, 'stress_matrix', args);
      takeOverflowReports(tester);
      final second = await ok(tester, 'stress_matrix', args);
      takeOverflowReports(tester);
      String shape(Map<String, Object?> r) =>
          [for (final f in list(r['findings'])) '${f['key']} ${f['runs']}']
              .join('\n');
      expect(shape(second), shape(first));
      expect(second['drafts'], isEmpty);
      expect(second['existing'], first['drafts']);
      expect(controller.notes.drafts, hasLength(1));
      await bridge.shutdown(tester);
    });

    testWidgets('acceptance: the environment and the scroll position are '
        'restored after stress_matrix', (tester) async {
      await pumpApp(tester, const _Zoo());
      controller.environment.update((e) => e.copyWith(boldText: () => true));
      await tester.pump();
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      scroll.position.jumpTo(40);
      await tester.pump();
      await ok(tester, 'stress_matrix', {
        'widths': [320],
        'textScales': [2],
        'directions': ['rtl'],
        'brightness': ['dark'],
        'kinds': ['overflow'],
      });
      takeOverflowReports(tester);
      expect(controller.environment.value, const Environment(boldText: true));
      expect(scroll.position.pixels, 40);
      await bridge.shutdown(tester);
    });

    testWidgets('thumbnails and the accessibility kinds', (tester) async {
      await pumpApp(tester, const _Zoo());
      final result = await ok(tester, 'stress_matrix', {
        'widths': [768],
        'textScales': <num>[],
        'directions': <String>[],
        'brightness': <String>[],
      });
      final run = list(result['runs']).single;
      expect(run['png'], isA<String>(), reason: 'a 400 px thumbnail');
      final kinds = {for (final f in list(result['findings'])) f['kind']};
      expect(kinds, contains('small_tap_target'));
      expect(kinds, contains('truncated_text'));
      await bridge.shutdown(tester);
    }, semanticsEnabled: false);

    testWidgets('set_environment changes only the given switches; '
        'reset_environment removes them', (tester) async {
      await pumpApp(tester, const _Zoo());
      final set = await ok(tester, 'set_environment', {
        'viewport': {'width': 390, 'height': 844},
        'textDirection': 'rtl',
      });
      takeOverflowReports(tester);
      expect(set['environment'], {
        'viewport': {'width': 390, 'height': 844},
        'textDirection': 'rtl',
      });
      await ok(tester, 'set_environment', {'viewport': null});
      expect(controller.environment.value.viewport, isNull);
      expect(controller.environment.value.textDirection, TextDirection.rtl);
      final bad = await drive(
        tester,
        controller.agent.run('set_environment', {'textScale': 'huge'}),
      );
      expect(bad['error'], contains('textScale'));
      await ok(tester, 'reset_environment');
      expect(controller.environment.isActive, isFalse);
      await bridge.shutdown(tester);
    });

    testWidgets('scan lists findings with their source; screenshot gives a '
        'PNG of the app or one widget', (tester) async {
      await pumpApp(tester, const _Zoo());
      final scan = await ok(tester, 'scan');
      final cut = list(scan['findings']).single;
      expect(cut['kind'], 'truncated_text');
      expect(cut['source'], contains('stress_matrix_test.dart:'));
      final whole = await ok(tester, 'screenshot');
      expect(whole['png'], isA<String>());
      final found = await ok(tester, 'find_widgets', {'type': 'IconButton'});
      final handle = list(found['widgets']).single['handle'];
      final one = await ok(tester, 'screenshot', {'handle': handle});
      expect(one['png'], isA<String>());
      await bridge.shutdown(tester);
    });
  });
}

class _Zoo extends StatelessWidget {
  const _Zoo();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Row(
          children: [
            SizedBox(
              width: 180,
              height: 24,
              child: ColoredBox(color: Colors.teal),
            ),
            SizedBox(
              width: 180,
              height: 24,
              child: ColoredBox(color: Colors.amber),
            ),
          ],
        ),
        const Text(
          'A long title that is cut with an ellipsis at the end of its one '
          'line at every width this matrix tries',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        IconButton(
          onPressed: () {},
          tooltip: 'Add',
          icon: const Icon(Icons.add, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(height: 2000),
      ],
    ),
  );
}
