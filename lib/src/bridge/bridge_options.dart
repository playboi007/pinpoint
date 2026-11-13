// Plain Dart: `bin/bridge.dart` parses its flags with this. No `args`
// package, so the bridge adds no dependency.

import 'bridge_protocol.dart';

/// How to run `dart run pinpoint:bridge`.
const String bridgeUsage =
    '''
Usage: dart run pinpoint:bridge [options]

Receives notes from the Pinpoint overlay and writes each one into
<dir>/open/ as <id>.md, <id>.json and <id>.png (drafts into <dir>/drafts/,
which no agent reads). Serves MCP tools for the agent at /mcp: list_notes,
get_note and update_note.

Options:
  --port <n>             Port to listen on (default $defaultBridgePort). The app must
                         use the same port: HttpSink.bridge(port: n) or
                         --dart-define=PINPOINT_BRIDGE_PORT=n.
  --dir <path>           Folder for the notes (default .pinpoint).
  --lan                  Listen on every network interface, for testing on a
                         phone. Without it only this machine can connect.
  --allow-origin <url>   Also accept notes from pages served at <url>, for
                         example http://192.168.1.20:5000. Repeatable. Pages
                         served from this machine are always accepted.
  --ttl <age>            Delete notes (any status, with their screenshots),
                         tapes and replay runs not changed for <age>: 30m,
                         24h or 7d. Checked at start and every hour. Without
                         it nothing is deleted.
  --timing               Log where the time of each agent command went: in
                         the queue, in the app, on the network.
  -h, --help             Show this text.
''';

/// The bridge's flags.
class BridgeOptions {
  const BridgeOptions({
    this.port = defaultBridgePort,
    this.dir = '.pinpoint',
    this.lan = false,
    this.allowedOrigins = const <String>[],
    this.timing = false,
    this.ttl,
    this.help = false,
  });

  final int port;
  final String dir;

  /// Listen on every interface instead of loopback only.
  final bool lan;

  /// Origins accepted besides pages served from this machine.
  final List<String> allowedOrigins;

  /// Log one timing line per agent command.
  final bool timing;

  /// How long notes, tapes and runs live after their last change; null
  /// keeps them.
  final Duration? ttl;

  final bool help;
}

/// [args] as [BridgeOptions]. Throws a [FormatException] that says what is
/// wrong.
BridgeOptions parseBridgeArgs(List<String> args) {
  var port = defaultBridgePort;
  var dir = '.pinpoint';
  var lan = false;
  var timing = false;
  Duration? ttl;
  var help = false;
  final origins = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    final equals = arg.indexOf('=');
    final name = equals < 0 ? arg : arg.substring(0, equals);
    String value() {
      final String text;
      if (equals >= 0) {
        text = arg.substring(equals + 1);
      } else if (i + 1 < args.length) {
        text = args[++i];
      } else {
        throw FormatException('$name needs a value');
      }
      if (text.isEmpty) throw FormatException('$name needs a value');
      return text;
    }

    switch (name) {
      case '--port':
        final text = value();
        final n = int.tryParse(text);
        if (n == null || n < 0 || n > 65535) {
          throw FormatException('--port must be 0 to 65535, not $text');
        }
        port = n;
      case '--dir':
        dir = value();
      case '--ttl':
        final text = value();
        ttl = parseTtl(text);
        if (ttl == null) {
          throw FormatException(
            '--ttl must be a number with m, h or d (30m, 24h, 7d), not $text',
          );
        }
      case '--allow-origin':
        origins.add(value());
      case '--lan' when equals < 0:
        lan = true;
      case '--timing' when equals < 0:
        timing = true;
      case '-h' || '--help' when equals < 0:
        help = true;
      default:
        throw FormatException('Unknown option: $arg');
    }
  }
  return BridgeOptions(
    port: port,
    dir: dir,
    lan: lan,
    allowedOrigins: origins,
    timing: timing,
    ttl: ttl,
    help: help,
  );
}

/// [text] such as `30m`, `24h` or `7d` as a duration, or null. Zero is
/// refused: it would delete a note as soon as it is written.
Duration? parseTtl(String text) {
  final match = RegExp(r'^(\d+)([mhd])$').firstMatch(text.trim());
  if (match == null) return null;
  final n = int.parse(match[1]!);
  if (n == 0) return null;
  return switch (match[2]) {
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(days: n),
  };
}
