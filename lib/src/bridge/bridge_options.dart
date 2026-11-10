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
  -h, --help             Show this text.
''';

/// The bridge's flags.
class BridgeOptions {
  const BridgeOptions({
    this.port = defaultBridgePort,
    this.dir = '.pinpoint',
    this.lan = false,
    this.allowedOrigins = const <String>[],
    this.help = false,
  });

  final int port;
  final String dir;

  /// Listen on every interface instead of loopback only.
  final bool lan;

  /// Origins accepted besides pages served from this machine.
  final List<String> allowedOrigins;

  final bool help;
}

/// [args] as [BridgeOptions]. Throws a [FormatException] that says what is
/// wrong.
BridgeOptions parseBridgeArgs(List<String> args) {
  var port = defaultBridgePort;
  var dir = '.pinpoint';
  var lan = false;
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
      case '--allow-origin':
        origins.add(value());
      case '--lan' when equals < 0:
        lan = true;
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
    help: help,
  );
}
