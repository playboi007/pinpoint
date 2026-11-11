import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart' show PinPointPalette;
import 'package:pinpoint/src/theme/pinpoint_theme.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart' show PinPointTokens;

void main() {
  group('palettes', () {
    test('Redline has the design values', () {
      const t = PinPointTokens.redline;
      expect(t.paper, const Color(0xFFFFFFFF));
      expect(t.ink, const Color(0xFF111111));
      expect(t.accent, const Color(0xFFE1140A));
      expect(t.edit, const Color(0xFFE1140A));
      expect(t.shadow, const Color(0xFFE1140A));
      expect(t.halo, const Color(0xEBFFFFFF));
      expect(t.onAccent, const Color(0xFFFFFFFF));
    });

    test('Cobalt has the design values', () {
      const t = PinPointTokens.cobalt;
      expect(t.paper, const Color(0xFFF1EFE8));
      expect(t.ink, const Color(0xFF23262D));
      expect(t.accent, const Color(0xFF1F5BFF));
      expect(t.edit, const Color(0xFF0E8A4F));
      expect(t.shadow, const Color(0xD923262D));
      expect(t.halo, const Color(0xE6F1EFE8));
      expect(t.onAccent, const Color(0xFFFFFFFF));
    });

    test('Ember has the design values', () {
      const t = PinPointTokens.ember;
      expect(t.paper, const Color(0xFFFFDD9C));
      expect(t.ink, const Color(0xFF2A1408));
      expect(t.accent, const Color(0xFFE73F1E));
      expect(t.edit, const Color(0xFFE73F1E));
      expect(t.shadow, const Color(0xFFFB6C00));
      expect(t.halo, const Color(0xEBFFDD9C));
      expect(t.onAccent, const Color(0xFFFFFFFF));
    });

    test('each palette maps to its tokens and label', () {
      expect(PinPointPalette.redline.tokens, same(PinPointTokens.redline));
      expect(PinPointPalette.cobalt.tokens, same(PinPointTokens.cobalt));
      expect(PinPointPalette.ember.tokens, same(PinPointTokens.ember));
      expect(PinPointPalette.values.map((p) => p.label), [
        'Redline',
        'Cobalt',
        'Ember',
      ]);
    });

    test('parse accepts the three names and nothing else', () {
      expect(PinPointPalette.parse('redline'), PinPointPalette.redline);
      expect(PinPointPalette.parse('cobalt'), PinPointPalette.cobalt);
      expect(PinPointPalette.parse('ember'), PinPointPalette.ember);
      expect(PinPointPalette.parse('Redline'), isNull);
      expect(PinPointPalette.parse('neon'), isNull);
      expect(PinPointPalette.parse(null), isNull);
    });

    test('copyWith changes one colour; lerp snaps', () {
      final changed = PinPointTokens.redline.copyWith(accent: Colors.blue);
      expect(changed.accent, Colors.blue);
      expect(changed.ink, PinPointTokens.redline.ink);
      expect(
        PinPointTokens.redline.lerp(PinPointTokens.cobalt, 0.4),
        same(PinPointTokens.redline),
      );
      expect(
        PinPointTokens.redline.lerp(PinPointTokens.cobalt, 0.6),
        same(PinPointTokens.cobalt),
      );
    });
  });

  group('type and elevation', () {
    const t = PinPointTokens.cobalt;

    test('type styles have the design sizes', () {
      expect(
        (t.title.fontSize, t.title.height, t.title.fontWeight),
        (13, 16 / 13, FontWeight.w700),
      );
      expect((t.body.fontSize, t.body.height), (12, 16 / 12));
      expect(t.label.color, t.muted);
      expect(t.value.fontFamily, 'packages/pinpoint/RobotoMono');
      expect(
        (t.caps.fontSize, t.caps.letterSpacing, t.caps.fontWeight),
        (10, 0.8, FontWeight.w500),
      );
      expect((t.micro.fontSize, t.micro.height), (10, 14 / 10));
      expect(t.body.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('shadows are hard', () {
      expect(t.e1.single.spreadRadius, 1);
      expect(t.e2.last.offset, const Offset(3, 3));
      expect(t.e3.last.offset, const Offset(4, 4));
      for (final shadow in [...t.e1, ...t.e2, ...t.e3]) {
        expect(shadow.blurRadius, 0);
      }
      final surface = t.surface(3);
      expect(surface.color, t.paper);
      expect(surface.borderRadius, isNull);
      expect(surface.boxShadow, hasLength(2));
    });
  });

  group('theme', () {
    test('is cached per palette and carries the tokens', () {
      expect(
        pinPointThemeData(PinPointPalette.ember),
        same(pinPointThemeData(PinPointPalette.ember)),
      );
      for (final palette in PinPointPalette.values) {
        final theme = pinPointThemeData(palette);
        expect(theme.extension<PinPointTokens>(), same(palette.tokens));
        expect(theme.colorScheme.primary, palette.tokens.accent);
        expect(theme.colorScheme.surface, palette.tokens.paper);
        expect(theme.textTheme.bodyMedium?.fontSize, 12);
      }
    });

    testWidgets('PinPointTokens.of falls back to Redline', (tester) async {
      late PinPointTokens found;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              found = PinPointTokens.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(found, same(PinPointTokens.redline));
    });
  });
}
