import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/state/state_lens.dart';
import 'package:pinpoint/src/trace/trace_session.dart';
import 'package:pinpoint_example/main.dart';
import 'package:pinpoint_example/screens/state_coupling_screen.dart';

/// The state lens demo (PLAN-v3 Milestone 21): the three shapes work
/// without Pinpoint's State tab, so the example stays usable.
void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const ExampleApp());
    // The tile sits below the clean screens: scroll to it.
    await tester.scrollUntilVisible(
      find.text(StateCouplingScreen.title),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(StateCouplingScreen.title));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Fetch sets both values with one notify', (tester) async {
    await open(tester);
    expect(find.text('loading: false'), findsOneWidget);

    await tester.tap(find.text('Fetch'));
    await tester.pump();
    expect(find.text('loading: true'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(find.text('loading: false'), findsOneWidget);
  });

  testWidgets('the dialog reads the same model as the screen', (tester) async {
    await open(tester);
    await tester.tap(find.text('Open dialog'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('dialog loading: false'), findsOneWidget);

    // The dialog's own Fetch: the screen below it changes too.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Fetch'),
      ),
    );
    await tester.pump();
    expect(find.text('dialog loading: true'), findsOneWidget);
    expect(find.text('loading: true'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a quantity notifier sets the total through its listener', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Total: 0'), findsOneWidget);

    await tester.tap(find.text('Add to cart'));
    await tester.pump();
    await tester.tap(find.text('Add to cart'));
    await tester.pump();

    expect(find.text('Quantity: 2'), findsOneWidget);
    expect(find.text('Total: 24'), findsOneWidget);
  });

  group('with the state lens', lensTests);
}

/// The lens on the demo: each shape gets its hint (PLAN-v3 Milestone 21).
void lensTests() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.scrollUntilVisible(
      find.text(StateCouplingScreen.title),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(StateCouplingScreen.title));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Element elementOf(WidgetTester tester, String type) => tester.element(
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type).first,
  );

  List<Map<String, Object?>> causes(StateLens lens) => [
    for (final c in lens.chain()['causes']! as List<Object?>)
      c! as Map<String, Object?>,
  ];

  String hints(StateLens lens) => [
    for (final c in causes(lens))
      if (c['hint'] is String) c['hint'],
  ].join(' | ');

  testWidgets('shapes 1 and 3: one notify, the screen and the dialog both '
      'rebuild', (tester) async {
    await open(tester);
    await tester.tap(find.text('Open dialog'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final lens = TraceSession.current!.stateLens;
    try {
      lens.arm(elementOf(tester, '_Status'));
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Fetch'),
        ),
      );
      await tester.pump();
      await tester.pump();
      final all = hints(lens);
      expect(all, contains('widgets read'), reason: '${lens.chain()}');
      expect(all, contains('read the same'), reason: '${lens.chain()}');
      // One tag on both readers: the same object.
      final rebuilt = [
        for (final c in causes(lens)) ...c['rebuilt']! as List<Object?>,
      ];
      expect({
        for (final r in rebuilt) (r! as Map<String, Object?>)['tag'],
      }, hasLength(1));
      expect({
        for (final r in rebuilt) (r! as Map<String, Object?>)['type'],
      }, containsAll(<String>['_Status', '_FetchDialog']));
    } finally {
      lens.stop();
    }
  });

  testWidgets('shape 2: a notify inside another notify', (tester) async {
    await open(tester);
    final lens = TraceSession.current!.stateLens;
    try {
      lens.arm(elementOf(tester, 'StateCouplingScreen'));
      await tester.tap(find.text('Add to cart'));
      await tester.pump();
      await tester.pump();
      expect(
        hints(lens),
        contains('sets off another'),
        reason: '${lens.chain()}',
      );
    } finally {
      lens.stop();
    }
  });
}
