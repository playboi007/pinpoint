import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/reload_counter.dart';

/// The app's side of `hot_reload`: the count that tells the bridge the new
/// code runs.
void main() {
  testWidgets('a hot reload raises the count the extension reports', (
    tester,
  ) async {
    final controller = PinPointController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PinPointWrapper(controller: controller, child: child),
        home: const Scaffold(body: Text('app')),
      ),
    );
    final before = ReloadCounter.count;
    // It waits for a frame, which a widget test draws only on a pump.
    final reassembled = tester.binding.reassembleApplication();
    await tester.pump();
    await reassembled;
    expect(ReloadCounter.count, before + 1);
    expect(jsonDecode(ReloadCounter.answer()), {'reloads': before + 1});
  });
}
