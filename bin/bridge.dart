// `dart run pinpoint:bridge`: the local bridge between the Pinpoint overlay
// and a coding agent (HTTP for the app, MCP for the agent).
//
// Plain Dart. Everything it imports stays free of `dart:ui` and
// `package:flutter` (test/bridge/bridge_options_test.dart checks this).

import 'dart:async';
import 'dart:io';

import 'package:pinpoint/src/bridge/bridge_options.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/setup.dart';

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
      timing: options.timing,
      log: stdout.writeln,
    );
  } on BridgeStartException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
    return;
  }
  final url = 'http://${bridge.address.address}:${bridge.port}';
  stdout
    ..writeln('pinpoint: bridge on $url, notes in ${bridge.openDir.path}')
    ..writeln(
      'pinpoint: MCP for your agent at $url/mcp '
      '(Claude Code: claude mcp add --transport http pinpoint $url/mcp)',
    )
    ..writeln('pinpoint: ${hotReloadHint(options.dir)}')
    ..writeln('pinpoint: Ctrl+C stops it.');

  late final StreamSubscription<ProcessSignal> interrupt;
  interrupt = ProcessSignal.sigint.watch().listen((_) async {
    await interrupt.cancel();
    await bridge.close();
  });
}
