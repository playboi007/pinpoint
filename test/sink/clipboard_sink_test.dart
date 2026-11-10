import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

/// Milestone 7, build step 3: the clipboard sink.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final note = Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.question,
    comment: 'Why is this grey?',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(),
    target: const TargetInfo(widget: 'Icon', sourceUnavailable: true),
    screenshot: ScreenshotInfo(
      file: 'pp_20261110_143205_a1f3.png',
      pixelRatio: 1,
      width: 1,
      height: 1,
      png: Uint8List.fromList(List.filled(64, 7)),
    ),
  );

  void onClipboard(Object? Function(MethodCall call) handler) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => handler(call),
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  test('copies the note as Markdown, with no image', () async {
    String? copied;
    onClipboard((call) {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    const sink = ClipboardSink();
    await sink.send(note);

    expect(sink.name, 'clipboard');
    expect(copied, note.toMarkdown());
    expect(copied, isNot(contains('BwcHBwcH')), reason: 'no base64 image');
  });

  test('fails when the platform refuses', () async {
    onClipboard((call) => throw PlatformException(code: 'copy_fail'));
    await expectLater(
      const ClipboardSink().send(note),
      throwsA(isA<PlatformException>()),
    );
  });
}
