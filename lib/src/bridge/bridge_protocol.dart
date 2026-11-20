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

/// The lines of the method around a file and line (`GET /source?file=&line=
/// &before=`), for the state lens (PLAN-v3 Milestone 21).
const String sourcePath = '/source';

/// Where a class is declared (`GET /declaration?type=Name`).
const String declarationPath = '/declaration';

/// The MCP endpoint for the agent (Streamable HTTP, JSON answers).
const String mcpPath = '/mcp';

/// The app's long poll for agent commands (`GET /commands`), their
/// results (`POST /commands/<id>/result`) and the control switch
/// (`POST /commands/control`).
const String commandsPath = '/commands';

/// Tapes (PLAN-v2 Milestone 15): `POST /tapes` stores one with its bodies,
/// `GET /tapes/<id>` gives it back for a replay.
const String tapesPath = '/tapes';

/// Replay runs: `POST /runs/<id>/events` adds a batch of events,
/// `POST /runs/<id>/status` says where the replay is.
const String runsPath = '/runs';

/// The largest tape the bridge reads: 20 MB of bodies as base64, and the
/// tape itself.
const int maxTapeBytes = 40 * 1024 * 1024;

/// The app's service extension that counts its hot reloads. The bridge's
/// `hot_reload` reads it before and after a reload: on web the reload
/// service says success even when the code did not compile.
const String reloadsExtension = 'ext.pinpoint.reloads';

/// The file in the notes folder with the app's debug service address, as
/// `flutter run --vmservice-out-file=.pinpoint/vm-service.txt` writes it.
const String vmServiceFileName = 'vm-service.txt';

/// How long the app holds a command poll open.
const Duration commandWait = Duration(seconds: 25);

/// How often the app asks [changesPath] again after an error, or after an
/// answer from a bridge that does not hold the request. Only while the
/// overlay is active.
const Duration pollInterval = Duration(seconds: 2);

/// The longest the bridge holds a `GET /changes?wait=<seconds>` request
/// when nothing changed. The app asks for this long.
const Duration changesWait = Duration(seconds: 25);

/// The hold time asked for by the `wait` query value [raw] (whole
/// seconds): zero for none or a bad value, and at most [changesWait].
Duration changesWaitOf(String? raw) {
  final seconds = int.tryParse(raw ?? '');
  if (seconds == null || seconds <= 0) return Duration.zero;
  return Duration(seconds: seconds.clamp(1, changesWait.inSeconds));
}

/// The query name of the id that tells the bridge which tab wrote: on
/// writes (`POST /annotations`, `PATCH`, `DELETE`) and on `/changes`, so a
/// tab is not told about its own writes.
const String clientQuery = 'client';

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
