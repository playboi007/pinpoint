// `dart run pinpoint:bridge`: the local receiver for Pinpoint notes.
//
// Plain Dart. Everything it imports stays free of `dart:ui` and
// `package:flutter` (test/bridge/bridge_options_test.dart checks this).

import 'dart:async';
import 'dart:io';

import 'package:pinpoint/src/bridge/bridge_options.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';

Future<void> main(List<String> args) async {
  final BridgeOptions options;
  try {
    options = parseBridgeArgs(args);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln()
      ..write(bridgeUsage);
    exitCode = 64; // usage error
    return;
  }
  if (options.help) {
    stdout.write(bridgeUsage);
    return;
  }

  final PinPointBridge bridge;
  try {
    bridge = await PinPointBridge.start(
      dir: options.dir,
      port: options.port,
      lan: options.lan,
      allowedOrigins: options.allowedOrigins,
      log: stdout.writeln,
    );
  } on BridgeStartException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
    return;
  }
  stdout
    ..writeln(
      'pinpoint: bridge on http://${bridge.address.address}:${bridge.port}, '
      'notes in ${bridge.openDir.path}',
    )
    ..writeln('pinpoint: Ctrl+C stops it.');

  late final StreamSubscription<ProcessSignal> interrupt;
  interrupt = ProcessSignal.sigint.watch().listen((_) async {
    await interrupt.cancel();
    await bridge.close();
  });
}
