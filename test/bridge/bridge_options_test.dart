import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_options.dart';

/// Milestone 7: the bridge's flags, and the rule that `bin/` stays plain
/// Dart.
void main() {
  group('parseBridgeArgs', () {
    test('defaults: port 4747, folder .pinpoint, loopback', () {
      final options = parseBridgeArgs(const []);
      expect(options.port, 4747);
      expect(options.dir, '.pinpoint');
      expect(options.lan, isFalse);
      expect(options.allowedOrigins, isEmpty);
      expect(options.help, isFalse);
    });

    test('reads each flag, with a space or an equals sign', () {
      final options = parseBridgeArgs(const [
        '--port',
        '5000',
        '--dir=notes',
        '--allow-origin',
        'http://192.168.1.20:5000',
        '--allow-origin=http://10.0.0.2:8080',
      ]);
      expect(options.port, 5000);
      expect(options.dir, 'notes');
      expect(options.allowedOrigins, [
        'http://192.168.1.20:5000',
        'http://10.0.0.2:8080',
      ]);
      expect(parseBridgeArgs(const ['--port=0']).port, 0);
      expect(parseBridgeArgs(const ['-h']).help, isTrue);
      expect(parseBridgeArgs(const ['--help']).help, isTrue);
    });

    test('LAN mode is an explicit flag, never the default', () {
      expect(parseBridgeArgs(const ['--lan']).lan, isTrue);
    });

    test('rejects a bad port, an unknown flag and a missing value', () {
      for (final args in [
        ['--port', 'abc'],
        ['--port', '70000'],
        ['--port', '-1'],
        ['--port'],
        ['--dir'],
        ['--dir='],
        ['--verbose'],
        ['extra'],
      ]) {
        expect(
          () => parseBridgeArgs(args),
          throwsFormatException,
          reason: '$args',
        );
      }
    });

    test('the usage text names every flag', () {
      for (final flag in [
        '--port',
        '--dir',
        '--lan',
        '--allow-origin',
        '--help',
      ]) {
        expect(bridgeUsage, contains(flag));
      }
    });
  });

  test('nothing bin/ imports uses dart:ui or package:flutter', () {
    // A plain Dart process (`dart run pinpoint:bridge`) cannot load them.
    final seen = <String>{};
    final pending = <String>['bin/bridge.dart', 'bin/setup.dart'];
    final bad = <String>[];
    final import = RegExp(
      r'''^(?:import|export)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    while (pending.isNotEmpty) {
      final path = pending.removeLast();
      if (!seen.add(path)) continue;
      final source = File(path).readAsStringSync();
      for (final match in import.allMatches(source)) {
        final uri = match.group(1)!;
        if (uri == 'dart:ui' || uri.startsWith('package:flutter/')) {
          bad.add('$path imports $uri');
        } else if (uri.startsWith('package:pinpoint/')) {
          pending.add('lib/${uri.substring('package:pinpoint/'.length)}');
        } else if (!uri.contains(':')) {
          pending.add(File(path).parent.uri.resolve(uri).toFilePath());
        }
      }
    }
    expect(bad, isEmpty);
    expect(seen, contains('lib/src/bridge/bridge_server.dart'));
    expect(seen, contains('lib/src/sink/markdown_formatter.dart'));
    expect(seen, contains('lib/src/bridge/mcp_server.dart'));
    expect(seen, contains('lib/src/bridge/setup.dart'));
  });
}
