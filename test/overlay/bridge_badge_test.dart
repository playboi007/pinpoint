import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/toast_layer.dart';
import 'package:pinpoint/src/overlay/toolbar.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/finish_send.dart';

/// Milestone 7, build step 3: the overlay checks the bridge when picking
/// starts and shows a badge when it does not answer.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  final badge = find.byKey(BridgeBadge.badgeKey);

  /// A bridge that answers [health] on /health, and refuses posts when
  /// [down]. Counts the health checks.
  ({HttpSink sink, List<Uri> checks}) bridge({
    bool down = false,
    bool postFails = false,
  }) {
    final checks = <Uri>[];
    final sink = HttpSink.bridge(
      client: MockClient((request) async {
        if (request.url.path == '/health') checks.add(request.url);
        if (down || (postFails && request.method == 'POST')) {
          throw http.ClientException('Connection refused', request.url);
        }
        return http.Response(
          '{"ok":true}',
          request.method == 'POST' ? 201 : 200,
        );
      }),
    );
    return (sink: sink, checks: checks);
  }

  Widget host(List<PinPointSink> sinks) => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(sinks: sinks),
      child: child,
    ),
    home: const FixturePage(),
  );

  Future<void> startPicking(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('acceptance: with the bridge stopped, the offline badge shows '
      'and the clipboard sink still works', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final stopped = bridge(down: true);
    await tester.pumpWidget(host([stopped.sink, const ClipboardSink()]));
    await startPicking(tester);

    expect(badge, findsOneWidget);
    expect(
      find.descendant(
        of: badge,
        matching: find.text('bridge offline: 127.0.0.1:4747'),
      ),
      findsOneWidget,
    );

    await tester.tapAt(
      tester.getCenter(
        find.descendant(of: find.byType(Scaffold), matching: find.text('Save')),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Too tight');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    await finishSend(tester, controller);

    expect(copied, isNotNull, reason: 'the clipboard sink took the note');
    expect(copied, contains('Comment: Too tight'));
    Finder toast(Pattern text) => find.descendant(
      of: find.byKey(ToastLayer.layerKey),
      matching: find.byWidgetPredicate(
        (w) => w is Text && text.allMatches(w.data ?? '').isNotEmpty,
      ),
    );
    expect(toast('Sent to clipboard'), findsOneWidget);
    expect(
      toast(RegExp('bridge failed: cannot reach 127.0.0.1:4747')),
      findsOneWidget,
    );
    expect(controller.draft.text.text, 'Too tight', reason: 'one sink failed');
    expect(badge, findsOneWidget);
  });

  testWidgets('no badge while the bridge answers', (tester) async {
    final running = bridge();
    await tester.pumpWidget(host([running.sink]));
    await startPicking(tester);
    expect(running.checks, hasLength(1));
    expect(badge, findsNothing);
  });

  testWidgets('checks once when picking starts, never while idle or per '
      'frame', (tester) async {
    final stopped = bridge(down: true);
    await tester.pumpWidget(host([stopped.sink]));
    await tester.pump(const Duration(seconds: 5));
    expect(stopped.checks, isEmpty, reason: 'idle: no request');

    await startPicking(tester);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(stopped.checks, hasLength(1));
    expect(tester.binding.hasScheduledFrame, isFalse);

    controller.stop();
    await tester.pump();
    expect(badge, findsNothing, reason: 'hidden while idle');

    await startPicking(tester);
    expect(stopped.checks, hasLength(2));
    expect(badge, findsOneWidget);
  });

  testWidgets('a failed send checks again', (tester) async {
    final flaky = bridge(postFails: true);
    await tester.pumpWidget(host([flaky.sink]));
    await startPicking(tester);
    expect(badge, findsNothing);

    await tester.tapAt(
      tester.getCenter(
        find.descendant(of: find.byType(Scaffold), matching: find.text('Save')),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Too tight');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    await finishSend(tester, controller);
    expect(flaky.checks, hasLength(2));
  });

  testWidgets('no HTTP sink, no check and no badge', (tester) async {
    await tester.pumpWidget(host(const [ClipboardSink()]));
    await startPicking(tester);
    expect(badge, findsNothing);
  });

  testWidgets('the badge takes no clicks, so picking works under it', (
    tester,
  ) async {
    await tester.pumpWidget(host([bridge(down: true).sink]));
    await startPicking(tester);
    final ignore = tester.widget<IgnorePointer>(
      find.ancestor(of: badge, matching: find.byType(IgnorePointer)).first,
    );
    expect(ignore.ignoring, isTrue);
  });
}
