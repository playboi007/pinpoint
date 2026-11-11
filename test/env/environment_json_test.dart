import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

/// Milestone 12: a note's environment (its `toJson`) is applied again by
/// `verify_note`, and the agent sets switches with the same keys.
void main() {
  const full = Environment(
    viewport: Size(360, 800),
    textScale: 1.5,
    boldText: true,
    safeArea: EdgeInsets.fromLTRB(0, 24, 0, 34),
    keyboardHeight: 300,
    textDirection: TextDirection.rtl,
    brightness: Brightness.dark,
    themeVariant: 'brand',
    seedColor: Color(0xFF6750A4),
    platform: TargetPlatform.iOS,
    timeDilation: 5,
  );

  test('every field comes back from its JSON', () {
    expect(Environment.fromJson(full.toJson()), full);
    expect(Environment.fromJson(const {}), Environment.none);
  });

  test('applyJson changes only the given fields; null clears one', () {
    final next = full.applyJson({
      'textScale': 2,
      'viewport': null,
      'brightness': 'light',
    });
    expect(next.textScale, 2);
    expect(next.viewport, isNull);
    expect(next.brightness, Brightness.light);
    expect(next.boldText, isTrue);
    expect(next.platform, TargetPlatform.iOS);
  });

  test('a wrong value or an unknown field is a FormatException', () {
    for (final bad in <Map<String, Object?>>[
      {'textScale': 'big'},
      {'textScale': 0},
      {'viewport': 360},
      {'viewport': {'width': 360}},
      {'textDirection': 'up'},
      {'platform': 'amiga'},
      {'seedColor': 'blue'},
      {'sparkle': true},
    ]) {
      expect(
        () => Environment.none.applyJson(bad),
        throwsFormatException,
        reason: '$bad',
      );
    }
  });
}
