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
      ttl: options.ttl,
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
    ..writeln(
      options.ttl == null
          ? 'pinpoint: notes, tapes and runs are kept until you delete them '
                '(--ttl 24h deletes them a day after their last change).'
          : 'pinpoint: notes, tapes and runs are deleted '
                '${_age(options.ttl!)} after their last change (--ttl).',
    )
    ..writeln('pinpoint: Ctrl+C stops it.');

  late final StreamSubscription<ProcessSignal> interrupt;
  interrupt = ProcessSignal.sigint.watch().listen((_) async {
    await interrupt.cancel();
    await bridge.close();
  });
}

String _age(Duration ttl) => ttl.inMinutes % (60 * 24) == 0
    ? '${ttl.inDays} d'
    : ttl.inMinutes % 60 == 0
    ? '${ttl.inHours} h'
    : '${ttl.inMinutes} min';
