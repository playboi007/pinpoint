// `dart run pinpoint:setup`: writes the agent instructions and an example
// MCP config, and with --write adds them to the project's agent files.
//
// Plain Dart. Everything it imports stays free of `dart:ui` and
// `package:flutter` (test/bridge/bridge_options_test.dart checks this).

import 'dart:io';

import 'package:pinpoint/src/bridge/setup.dart';

Future<void> main(List<String> args) async {
  final SetupOptions options;
  try {
    options = parseSetupArgs(args);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln()
      ..write(setupUsage);
    exitCode = 64; // usage error
    return;
  }
  if (options.help) {
    stdout.write(setupUsage);
    return;
  }
  try {
    final lines = await runSetup(options, Directory.current);
    lines.forEach(stdout.writeln);
  } on SetupException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}
