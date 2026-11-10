import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';

/// Milestone 6, build step 3: the screenshot in the payload. The base64
/// data goes only to sinks that ask for it.
void main() {
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

  Annotation note({ScreenshotInfo? screenshot}) => Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.bug,
    comment: 'Too tight',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(),
    target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
    screenshot: screenshot,
  );

  ScreenshotInfo shot({bool platformViews = false}) => ScreenshotInfo(
    file: 'pp_20261110_143205_a1f3.png',
    pixelRatio: 2,
    width: 640,
    height: 400,
    crop: const PayloadRect(10, 20, 320, 200),
    hasPlatformViews: platformViews,
    debugPaint: const ['debugPaintSizeEnabled'],
    png: png,
  );

  test(
    'acceptance: without a screenshot the payload has no screenshot key',
    () {
      final json = note().toJson();
      expect(json.containsKey('screenshot'), isFalse);
      expect(
        note().toJson(includeScreenshotData: true).containsKey('screenshot'),
        isFalse,
      );
    },
  );

  test('the screenshot is described, but its data is left out by default', () {
    final json = note(screenshot: shot()).toJson();
    expect(json['screenshot'], {
      'file': 'pp_20261110_143205_a1f3.png',
      'pixelRatio': 2,
      'width': 640,
      'height': 400,
      'crop': {'x': 10, 'y': 20, 'w': 320, 'h': 200},
      'hasPlatformViews': false,
      'debugPaint': ['debugPaintSizeEnabled'],
    });
  });

  test('a sink that wants the image gets it as base64 in screenshot.data', () {
    final json = jsonDecode(
      jsonEncode(note(screenshot: shot()).toJson(includeScreenshotData: true)),
    );
    final data = (json as Map<String, Object?>)['screenshot']! as Map;
    expect(base64Decode(data['data']! as String), png);
  });

  test('platform views in the crop are recorded, so the agent knows the '
      'image is partial', () {
    final json = note(screenshot: shot(platformViews: true)).toJson();
    expect((json['screenshot']! as Map)['hasPlatformViews'], isTrue);
  });

  test('the screenshot comes after the collected parts, before errors', () {
    final json = note(screenshot: shot())
        .withError('screenshot.hasPlatformViews')
        .toJson();
    final keys = json.keys.toList();
    expect(keys.indexOf('screenshot'), keys.indexOf('inherited') + 1);
    expect(keys.last, 'errors');
    expect(json['errors'], ['screenshot.hasPlatformViews']);
  });

  test('withScreenshot keeps every other part', () {
    final before = note();
    final after = before.withScreenshot(shot());
    final json = after.toJson()..remove('screenshot');
    expect(json, before.toJson());
    expect(after.screenshot!.png, png);
  });

  test('the size budget leaves the image data out', () {
    final big = ScreenshotInfo(
      file: 'a.png',
      pixelRatio: 2,
      width: 1600,
      height: 1000,
      png: Uint8List(200 * 1024),
    );
    final fitted = note(screenshot: big).fitToBudget();
    expect(fitted.truncated, isEmpty);
    expect(fitted.screenshot!.png, hasLength(200 * 1024));
  });
}
