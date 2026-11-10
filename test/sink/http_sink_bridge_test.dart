import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationId;

/// Milestone 7: the HTTP sink against a real bridge over loopback, the
/// path a Send from Chrome takes (minus the browser).
///
/// Plain `test`, never `testWidgets`: the widget binding replaces
/// `HttpClient` with one that answers 400 to everything.
void main() {
  late Directory root;
  late PinPointBridge bridge;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_sink_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4b23wHwAGEQ'
    'Jq+GwfDQAAAABJRU5ErkJggg==',
  );

  Annotation note(String id) => Annotation(
    id: id,
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.improve,
    // A draft would go to drafts/, where no agent looks.
    status: NoteStatus.submitted,
    comment: 'Label truncates at narrow widths',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(route: '/orders/:id'),
    target: const TargetInfo(
      widget: 'Text',
      source: SourceRef(
        file: 'lib/widgets/save_bar.dart',
        line: 42,
        column: 18,
      ),
      sourceUnavailable: false,
    ),
    screenshot: ScreenshotInfo(
      file: '$id.png',
      pixelRatio: 1,
      width: 1,
      height: 1,
      png: Uint8List.fromList(png),
    ),
  );

  test('one send creates the .md, .json and .png, and the JSON holds no '
      'base64', () async {
    final id = annotationId(DateTime.utc(2026, 11, 10), math.Random(1));
    final sink = HttpSink.bridge(port: bridge.port);
    expect(await sink.isReachable(), isTrue);

    await sink.send(note(id));

    final open = bridge.openDir.path;
    expect(File('$open/$id.png').readAsBytesSync(), png);
    final json = File('$open/$id.json').readAsStringSync();
    expect(json, isNot(contains(base64Encode(png))));
    final markdown = File('$open/$id.md').readAsStringSync();
    expect(markdown, contains('Source: lib/widgets/save_bar.dart:42:18'));
    expect(markdown, contains('Screenshot: $id.png'));
  });

  test('a stopped bridge fails the send and the health check', () async {
    final sink = HttpSink.bridge(port: bridge.port);
    await bridge.close();
    expect(await sink.isReachable(), isFalse);
    await expectLater(
      sink.send(note('pp_x')),
      throwsA(isA<HttpSinkException>()),
    );
  });

  test('every id the app makes is one the bridge accepts', () {
    final random = math.Random(3);
    for (var i = 0; i < 1000; i++) {
      final time = DateTime.utc(
        1970 + random.nextInt(9000),
        1,
        1,
      ).add(Duration(seconds: random.nextInt(31536000)));
      final id = annotationId(time, random);
      expect(noteIdPattern.hasMatch(id), isTrue, reason: id);
    }
  });
}
