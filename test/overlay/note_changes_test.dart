import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/note_view.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';
import 'package:pinpoint/src/theme/controls.dart';
import 'package:pinpoint/src/theme/pinpoint_theme.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

import '../fixtures/pin_fixture.dart';
import '../support/fake_bridge.dart';
import '../support/finish_send.dart';

/// PLAN-v3 Milestone 20, step 6: the undo actions of a note, behind the
/// `Changes · N` button.
Map<String, Object?> _round(
  int n, {
  List<Map<String, Object?>>? changes,
  List<String> undone = const [],
  bool open = false,
  bool git = true,
}) => {
  'n': n,
  'startedAt': '2026-11-20T09:00:00Z',
  if (!open) 'endedAt': '2026-11-20T09:10:00Z',
  if (git) 'start': 'aaa$n',
  if (git && !open) 'end': 'bbb$n',
  'changes':
      changes ??
      [
        {
          'id': 'c1',
          'summary': 'More space above the filters',
          'files': [
            {
              'path': 'lib/features/detail/widgets/detail_toolbar.dart',
              'added': 4,
              'removed': 1,
            },
          ],
        },
        {
          'id': 'c2',
          'summary': 'Bigger title',
          'files': [
            {'path': 'lib/title.dart', 'added': 2, 'removed': 2},
          ],
        },
      ],
  'undone': undone,
};

Annotation _note({
  String status = 'fixed',
  List<Map<String, Object?>>? rounds,
}) => Annotation.fromJson({
  'schema': annotationSchema,
  'id': 'pp_a',
  'createdAt': '2026-11-20T09:00:00Z',
  'status': status,
  'intent': 'bug',
  'comment': 'Fix it',
  'app': {'buildMode': 'debug', 'platform': 'web'},
  'page': <String, Object?>{},
  'target': {'widget': 'Text', 'sourceUnavailable': true},
  'rounds': rounds ?? [_round(1)],
})!;

typedef _Call = (String id, int round, List<String> changes, String? reason);

void main() {
  late List<_Call> calls;

  setUp(() => calls = []);

  NoteActions actions() => NoteActions(
    send: (_) {},
    sendAll: () {},
    delete: (_) {},
    accept: (_) {},
    reopen: (_, _) {},
    edit: (_, _) {},
    undo: (id, round, changes, reason) =>
        calls.add((id, round, changes, reason)),
  );

  Widget host(
    Annotation note, {
    PinPointPalette palette = PinPointPalette.redline,
    bool reduced = false,
  }) => MaterialApp(
    theme: pinPointThemeData(palette),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Material(
      child: SizedBox(
        width: 360,
        height: 640,
        child: NoteView(
          note: note,
          number: 1,
          drafts: 0,
          focusNode: FocusNode(),
          actions: actions(),
        ),
      ),
    ),
  );

  Finder changesButton() => find.byKey(NoteView.changesKey);
  Finder section() => find.byKey(NoteView.changesSectionKey);

  group('the Changes button', () {
    testWidgets('is hidden with no round', (tester) async {
      await tester.pumpWidget(host(_note(rounds: [])));
      expect(changesButton(), findsNothing);
    });

    testWidgets('is hidden for a draft', (tester) async {
      await tester.pumpWidget(host(_note(status: 'draft')));
      expect(changesButton(), findsNothing);
    });

    testWidgets('is hidden while the note is sent or in progress', (
      tester,
    ) async {
      for (final status in ['submitted', 'inProgress']) {
        await tester.pumpWidget(host(_note(status: status)));
        expect(changesButton(), findsNothing, reason: status);
      }
    });

    testWidgets('is hidden when the latest closed round has no changes', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          _note(
            rounds: [
              _round(1),
              _round(2, changes: const []),
            ],
          ),
        ),
      );
      expect(changesButton(), findsNothing);
    });

    testWidgets('is hidden when the only round is still open', (tester) async {
      await tester.pumpWidget(host(_note(rounds: [_round(1, open: true)])));
      expect(changesButton(), findsNothing);
    });

    testWidgets('shows the changes of a fixed note\'s round', (tester) async {
      await tester.pumpWidget(host(_note()));
      expect(find.text('Changes · 2'), findsOneWidget);
      expect(section(), findsNothing);
    });

    testWidgets('shows for a resolved note too', (tester) async {
      await tester.pumpWidget(host(_note(status: 'resolved')));
      expect(find.text('Changes · 2'), findsOneWidget);
    });
  });

  group('the section', () {
    testWidgets('opens and closes with the button', (tester) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(section(), findsOneWidget);
      expect(find.text('More space above the filters'), findsOneWidget);
      expect(find.text('Bigger title'), findsOneWidget);
      // Short path, then the counts with a real minus sign.
      expect(find.text('…/widgets/detail_toolbar.dart +4 −1'), findsOne);
      expect(find.text('lib/title.dart +2 −2'), findsOneWidget);

      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(section(), findsNothing);
    });

    testWidgets('starts unticked, and Undo selected waits for a tick', (
      tester,
    ) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      final undoSelected = find.byKey(NoteView.undoSelectedKey);
      expect(tester.widget<DraftButton>(undoSelected).onPressed, isNull);
      expect(
        tester.widget<DraftButton>(find.byKey(NoteView.undoAllKey)).onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(NoteView.changeKey('c1')));
      await tester.pump();
      expect(tester.widget<DraftButton>(undoSelected).onPressed, isNotNull);
      await tester.tap(find.byKey(NoteView.changeKey('c1')));
      await tester.pump();
      expect(tester.widget<DraftButton>(undoSelected).onPressed, isNull);
    });

    testWidgets('Undo selected sends the ticked id and the reason', (
      tester,
    ) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NoteView.changeKey('c2')));
      await tester.pump();
      await tester.enterText(find.byKey(NoteView.reasonKey), 'Too big');
      await tester.tap(find.byKey(NoteView.undoSelectedKey));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'pp_a');
      expect(calls.single.$2, 1);
      expect(calls.single.$3, ['c2']);
      expect(calls.single.$4, 'Too big');
      // The reason is used up, and the section closed.
      expect(
        tester
            .widget<TextField>(find.byKey(NoteView.reasonKey))
            .controller!
            .text,
        isEmpty,
      );
      expect(section(), findsNothing);
    });

    testWidgets('Undo all sends * and no reason when none was typed', (
      tester,
    ) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NoteView.undoAllKey));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single.$3, ['*']);
      expect(calls.single.$4, isNull);
    });

    testWidgets('the reason field takes up to four lines', (tester) async {
      await tester.pumpWidget(host(_note()));
      final field = tester.widget<TextField>(find.byKey(NoteView.reasonKey));
      expect(field.minLines, 1);
      expect(field.maxLines, 4);
      final before = tester.getSize(find.byKey(NoteView.reasonKey)).height;
      await tester.enterText(find.byKey(NoteView.reasonKey), 'a\nb\nc');
      await tester.pump();
      expect(
        tester.getSize(find.byKey(NoteView.reasonKey)).height,
        greaterThan(before),
      );
    });

    testWidgets('without git the labels ask the agent', (tester) async {
      await tester.pumpWidget(host(_note(rounds: [_round(1, git: false)])));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(find.text('Ask agent to undo selected'), findsOneWidget);
      expect(find.text('Ask agent to undo all'), findsOneWidget);
      expect(find.text('Undo selected'), findsNothing);
      await tester.tap(find.byKey(NoteView.changeKey('c1')));
      await tester.pump();
      await tester.tap(find.byKey(NoteView.undoSelectedKey));
      await tester.pump();
      expect(calls.single.$3, ['c1']);
    });

    testWidgets('with git the labels are Undo selected and Undo all', (
      tester,
    ) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(find.text('Undo selected'), findsOneWidget);
      expect(find.text('Undo all'), findsOneWidget);
    });

    testWidgets('an undone change is struck through and cannot be ticked', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          _note(
            rounds: [
              _round(1, undone: ['c1']),
            ],
          ),
        ),
      );
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      final struck = tester.widget<Text>(
        find.text('More space above the filters'),
      );
      expect(struck.style!.decoration, TextDecoration.lineThrough);
      final open = tester.widget<Text>(find.text('Bigger title'));
      expect(open.style!.decoration, isNot(TextDecoration.lineThrough));

      await tester.tap(find.byKey(NoteView.changeKey('c1')));
      await tester.pump();
      expect(
        tester
            .widget<DraftButton>(find.byKey(NoteView.undoSelectedKey))
            .onPressed,
        isNull,
      );
      // The other change still can be.
      await tester.tap(find.byKey(NoteView.changeKey('c2')));
      await tester.pump();
      await tester.tap(find.byKey(NoteView.undoSelectedKey));
      await tester.pump();
      expect(calls.single.$3, ['c2']);
    });

    testWidgets('when all changes are undone, nothing can be sent', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          _note(
            rounds: [
              _round(1, undone: ['*']),
            ],
          ),
        ),
      );
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(
        tester.widget<DraftButton>(find.byKey(NoteView.undoAllKey)).onPressed,
        isNull,
      );
    });

    testWidgets('a shared change has a tag', (tester) async {
      final round = _round(
        1,
        changes: [
          {
            'id': 'c1',
            'summary': 'Padding',
            'files': [
              {'path': 'lib/a.dart', 'added': 1, 'removed': 0, 'shared': true},
            ],
          },
          {
            'id': 'c2',
            'summary': 'Colour',
            'files': [
              {'path': 'lib/b.dart', 'added': 1, 'removed': 0},
            ],
          },
        ],
      );
      await tester.pumpWidget(host(_note(rounds: [round])));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(find.text('shared'), findsOneWidget);
    });

    testWidgets('the round picker switches rounds', (tester) async {
      final second = _round(
        2,
        changes: [
          {
            'id': 'c1',
            'summary': 'Round two change',
            'files': [
              {'path': 'lib/two.dart', 'added': 1, 'removed': 1},
            ],
          },
        ],
        undone: ['*'],
      );
      await tester.pumpWidget(host(_note(rounds: [_round(1), second])));
      // The button counts the latest round.
      expect(find.text('Changes · 1'), findsOneWidget);
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(find.text('Round two change'), findsOneWidget);
      expect(find.text('Bigger title'), findsNothing);

      await tester.tap(find.byKey(NoteView.roundKey(1)));
      await tester.pumpAndSettle();
      expect(find.text('Bigger title'), findsOneWidget);
      expect(find.text('Round two change'), findsNothing);
      await tester.tap(find.byKey(NoteView.changeKey('c2')));
      await tester.pump();
      await tester.tap(find.byKey(NoteView.undoSelectedKey));
      await tester.pump();
      expect(calls.single.$2, 1);
      expect(calls.single.$3, ['c2']);
    });

    testWidgets('a single round shows no picker', (tester) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(find.byKey(NoteView.roundKey(1)), findsNothing);
      expect(find.text('Round 1'), findsOneWidget);
    });

    testWidgets('the section closes when the agent works again', (
      tester,
    ) async {
      await tester.pumpWidget(host(_note()));
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(section(), findsOneWidget);
      await tester.pumpWidget(host(_note(status: 'inProgress')));
      await tester.pumpAndSettle();
      expect(section(), findsNothing);
      await tester.pumpWidget(host(_note()));
      await tester.pumpAndSettle();
      expect(section(), findsNothing, reason: 'closed, not just hidden');
    });
  });

  for (final palette in PinPointPalette.values) {
    testWidgets('the section works in the ${palette.name} palette', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          _note(
            rounds: [
              _round(1, undone: ['c1']),
            ],
          ),
          palette: palette,
        ),
      );
      await tester.tap(changesButton());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final tokens = PinPointTokens.of(tester.element(section()));
      expect(tokens, PinPointTokens.of(tester.element(changesButton())));
      final summary = tester.widget<Text>(find.text('Bigger title'));
      expect(summary.style!.color, tokens.ink);
      final undone = tester.widget<Text>(
        find.text('More space above the filters'),
      );
      expect(undone.style!.color, tokens.faint);
      final box = tester.widget<Container>(
        find.descendant(of: section(), matching: find.byType(Container)).first,
      );
      expect((box.decoration! as BoxDecoration).border!.top.color, tokens.rule);
    });
  }

  testWidgets('with reduced motion the section opens at once', (tester) async {
    await tester.pumpWidget(host(_note(), reduced: true));
    await tester.tap(changesButton());
    await tester.pump();
    expect(section(), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byType(AnimatedSize), findsNothing);
    await tester.tap(changesButton());
    await tester.pump();
    expect(section(), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('with motion the section grows in, then nothing runs', (
    tester,
  ) async {
    await tester.pumpWidget(host(_note()));
    await tester.tap(changesButton());
    await tester.pump();
    expect(find.byType(AnimatedSize), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  // The toasts: the full app, with the fake bridge answering the undo.
  group('after the call', () {
    late PinPointController controller;
    late FakeBridge bridge;

    setUp(() {
      controller = PinPointController();
      bridge = FakeBridge();
      BridgeClient.debugClient = bridge.client;
    });
    tearDown(() {
      BridgeClient.debugClient = null;
      controller.dispose();
    });

    Widget app() => MaterialApp(
      builder: (context, child) => PinPointWrapper(
        controller: controller,
        config: PinPointConfig(
          sinks: [HttpSink.bridge(port: 4747, client: bridge.client)],
        ),
        child: child,
      ),
      home: const PinFixture(),
    );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    /// A sent note the agent has fixed, with one closed round, and its pin
    /// open in the app.
    Future<String> fixedNote(WidgetTester tester) async {
      await tester.pumpWidget(app());
      controller.startPicking();
      controller.panelPosition = const Offset(300, 20);
      await tester.pump();
      await tester.tapAt(
        tester.getCenter(
          find.descendant(
            of: find.byType(Scaffold),
            matching: find.text('Title'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byKey(CommentForm.fieldKey), 'About Title');
      await tester.pump();
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await finishSend(tester, controller);
      await settle(tester);
      final id = controller.notes.notes.last.id;
      bridge.notes[id]!['rounds'] = [_round(1)];
      bridge.agentUpdate(id, 'fixed', message: 'Done.');
      controller.startPicking();
      await tester.pump(pollInterval);
      await settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('pinpoint.pin.$id')));
      await settle(tester);
      return id;
    }

    Future<void> undoAll(WidgetTester tester) async {
      await tester.tap(find.byKey(NoteView.changesKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(NoteView.reasonKey), 'Too tight');
      await tester.tap(find.byKey(NoteView.undoAllKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('done and reloaded', (tester) async {
      final id = await fixedNote(tester);
      await undoAll(tester);
      expect(bridge.undos.single, {
        'round': 1,
        'changes': ['*'],
        'reason': 'Too tight',
      });
      expect(find.text('Undone, reloaded'), findsOneWidget);
      // The note came back sent, with the user's message.
      expect(controller.notes.byId(id)!.status, NoteStatus.submitted);
      expect(find.byKey(NoteView.changesKey), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('done, not reloaded', (tester) async {
      bridge.undoAnswer = {
        'undo': 'done',
        'reverted': ['lib/a.dart'],
        'conflicts': <String>[],
        'reloaded': false,
      };
      await fixedNote(tester);
      await undoAll(tester);
      expect(find.text('Undone, press r to reload'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('requested with conflicts', (tester) async {
      bridge.undoAnswer = {
        'undo': 'requested',
        'reverted': <String>[],
        'conflicts': ['lib/a.dart'],
        'reloaded': false,
      };
      await fixedNote(tester);
      await undoAll(tester);
      expect(find.text('Asked the agent: files changed since'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    // The Ahem test font makes the no-git labels wider than the panel, so
    // this uses a round with checkpoints; the toast depends on the answer.
    testWidgets('requested without conflicts (no git)', (tester) async {
      bridge.undoAnswer = {
        'undo': 'requested',
        'reverted': <String>[],
        'conflicts': <String>[],
        'reloaded': false,
      };
      await fixedNote(tester);
      await undoAll(tester);
      expect(find.text('Asked the agent to undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a refusal shows no toast of its own', (tester) async {
      final id = await fixedNote(tester);
      // The bridge no longer has the note: the undo fails (404).
      bridge.notes.remove(id);
      await tester.tap(find.byKey(NoteView.changesKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(NoteView.undoAllKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Undone'), findsNothing);
      expect(find.textContaining('Asked the agent'), findsNothing);
      expect(find.textContaining('Undo failed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
