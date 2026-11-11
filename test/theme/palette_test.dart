import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/theme/palette_store.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

void main() {
  late MemoryPaletteStore store;
  late PinPointController controller;
  var hostBuilds = 0;
  late ThemeData hostTheme;

  setUp(() {
    store = MemoryPaletteStore();
    controller = PinPointController(paletteStore: store);
    hostBuilds = 0;
  });
  tearDown(() => controller.dispose());

  Widget host({PinPointConfig config = const PinPointConfig()}) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(config: config, controller: controller, child: child),
    home: Builder(
      builder: (context) {
        hostBuilds++;
        hostTheme = Theme.of(context);
        return const Scaffold(body: Text('app'));
      },
    ),
  );

  /// The tokens a widget inside Pinpoint's overlay sees.
  PinPointTokens overlayTokens(WidgetTester tester) {
    final context = tester.element(
      find
          .descendant(
            of: find.byType(InspectorOverlay),
            matching: find.byType(Material),
          )
          .first,
    );
    return PinPointTokens.of(context);
  }

  testWidgets('the overlay starts in the configured palette', (tester) async {
    await tester.pumpWidget(
      host(config: const PinPointConfig(palette: PinPointPalette.ember)),
    );
    expect(overlayTokens(tester), same(PinPointTokens.ember));
    expect(store.writes, 0, reason: 'restoring is not a pick');
  });

  testWidgets('a saved pick wins over the config', (tester) async {
    store.write(PinPointPalette.cobalt);
    await tester.pumpWidget(
      host(config: const PinPointConfig(palette: PinPointPalette.ember)),
    );
    expect(overlayTokens(tester), same(PinPointTokens.cobalt));
  });

  testWidgets('selecting a palette re-themes the overlay and saves it', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    expect(overlayTokens(tester), same(PinPointTokens.redline));
    final hostBuildsBefore = hostBuilds;

    controller.palette.select(PinPointPalette.cobalt);
    await tester.pump();

    expect(overlayTokens(tester), same(PinPointTokens.cobalt));
    expect(store.read(), PinPointPalette.cobalt);
    expect(store.writes, 1);
    // The host app is untouched: no rebuild, and no Pinpoint tokens in its
    // theme.
    expect(hostBuilds, hostBuildsBefore);
    expect(hostTheme.extension<PinPointTokens>(), isNull);
  });

  test('the controller restores only once', () {
    final palette = PaletteController(store: MemoryPaletteStore());
    addTearDown(palette.dispose);
    palette.restore(PinPointPalette.ember);
    palette.select(PinPointPalette.cobalt);
    palette.restore(PinPointPalette.ember);
    expect(palette.value, PinPointPalette.cobalt);
  });
}
