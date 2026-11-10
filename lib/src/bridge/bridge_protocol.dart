// Plain Dart with no `dart:io`: the HTTP sink in the app and the bridge
// process share these.

/// The bridge's port when neither `--port` nor the app's config says
/// otherwise.
const int defaultBridgePort = 4747;

/// The bridge's port as the app sees it: the `PINPOINT_BRIDGE_PORT` define,
/// else [defaultBridgePort].
const int configuredBridgePort = int.fromEnvironment(
  'PINPOINT_BRIDGE_PORT',
  defaultValue: defaultBridgePort,
);

/// Where the app posts notes.
const String annotationsPath = '/annotations';

/// Answers 200 while the bridge runs.
const String healthPath = '/health';

/// What changed since a cursor, for the app's poll.
const String changesPath = '/changes';

/// The MCP endpoint for the agent (Streamable HTTP, JSON answers).
const String mcpPath = '/mcp';

/// How often the app asks [changesPath], only while the overlay is active.
const Duration pollInterval = Duration(seconds: 2);

/// The largest request body the bridge reads. Base64 makes the screenshot a
/// third larger than its PNG.
const int maxBodyBytes = 10 * 1024 * 1024;

/// What a note id may be. The id becomes a file name, so it can hold no
/// path separator and no dot. `annotationId` makes ids of this form.
final RegExp noteIdPattern = RegExp(r'^[a-z0-9_]{1,64}$');

/// Whether [origin] (an `Origin` header) is a page served from this machine.
bool isLoopbackOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == '::1' ||
      RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
}
