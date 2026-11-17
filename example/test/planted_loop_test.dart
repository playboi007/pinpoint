import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint_example/screens/planted_loop_screen.dart';

/// The planted loop screen (PLAN-v2 Milestone 14): its bug is on purpose.
/// The loop must run, and it must stop, so the example stays usable.
void main() {
  testWidgets('each rebuild during the load starts the load again, up to '
      'the limit', (tester) async {
    final answers = <Completer<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PlantedLoopScreen(
          load: (type) {
            final answer = Completer<String>();
            answers.add(answer);
            return answer.future;
          },
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    // Six loads started before the first answer came back.
    expect(answers, hasLength(ImproveExistingConfig.maxLoads));
    for (final answer in answers) {
      answer.complete('{}');
    }
    await tester.pumpAndSettle();
    expect(answers, hasLength(ImproveExistingConfig.maxLoads));
    expect(find.text('Loaded (6 loads)'), findsOneWidget);
  });
}
