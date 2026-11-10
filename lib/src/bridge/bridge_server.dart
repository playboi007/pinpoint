// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so
// `dart run pinpoint:bridge` can run it. Never exported from pinpoint.dart;
// the app (web) cannot import `dart:io`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/annotation.dart' show annotationSchema, clipText;
import '../sink/markdown_formatter.dart';
import 'agent_instructions.dart';
import 'bridge_protocol.dart';

/// Why the bridge could not start.
class BridgeStartException implements Exception {
  const BridgeStartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The local receiver: takes each note the overlay posts and writes it into
/// `<dir>/open/` as `<id>.md`, `<id>.json` and `<id>.png`, for a coding
/// agent to read.
class PinPointBridge {
  PinPointBridge._(this._server, this._dir, this._allowedOrigins, this._log) {
    _subscription = _server.listen(_handle);
  }

  /// Creates `<dir>/open/` and `<dir>/resolved/` and starts listening.
  ///
  /// Port 0 picks a free port; read it from [port]. Throws a
  /// [BridgeStartException] when the port cannot be bound.
  static Future<PinPointBridge> start({
    required String dir,
    int port = defaultBridgePort,
    bool lan = false,
    List<String> allowedOrigins = const <String>[],
    void Function(String line) log = _noLog,
  }) async {
    final folder = Directory(dir).absolute;
    await Directory('${folder.path}/open').create(recursive: true);
    await Directory('${folder.path}/resolved').create(recursive: true);
    // Keeps the notes (comments, screenshots) out of git without editing
    // the project's own .gitignore: `*` here ignores the folder, this file
    // included.
    final ignore = File('${folder.path}/.gitignore');
    if (!ignore.existsSync()) await ignore.writeAsString('*\n');

    // Loopback only by default: a note becomes files a coding agent acts
    // on, so no other machine may send one. Flutter Agentation binds
    // 0.0.0.0 first; this does not. LAN mode is an explicit flag.
    final address = lan
        ? InternetAddress.anyIPv4
        : InternetAddress.loopbackIPv4;
    final HttpServer server;
    try {
      server = await HttpServer.bind(address, port);
    } on SocketException catch (error) {
      final reason = error.osError?.message ?? error.message;
      throw BridgeStartException(
        'Could not listen on ${address.address}:$port ($reason).\n'
        'If the port is taken, start the bridge on another one with '
        '--port <n>, and give the app the same port: '
        'HttpSink.bridge(port: <n>) or '
        '--dart-define=PINPOINT_BRIDGE_PORT=<n>.',
      );
    }
    _hintInstructions(folder, log);
    if (lan) {
      log(
        'pinpoint: LAN mode. Every device on this network can reach port '
        '${server.port}.',
      );
    }
    return PinPointBridge._(server, folder, allowedOrigins, log);
  }

  final HttpServer _server;
  final Directory _dir;
  final List<String> _allowedOrigins;
  final void Function(String line) _log;
  late final StreamSubscription<HttpRequest> _subscription;

  /// The port it listens on.
  int get port => _server.port;

  /// The address it listens on: loopback unless started in LAN mode.
  InternetAddress get address => _server.address;

  /// The folder an agent reads: `<dir>/open/`.
  Directory get openDir => Directory('${_dir.path}/open');

  Directory get _resolvedDir => Directory('${_dir.path}/resolved');

  /// Stops listening and drops open connections.
  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    // On every response, so the app can read errors too. It carries no
    // credentials, so `*` exposes nothing.
    response.headers.set('access-control-allow-origin', '*');
    try {
      final path = request.uri.path;
      final known = path == annotationsPath || path == healthPath;
      switch (request.method) {
        case 'OPTIONS' when known:
          // A browser sends this before every JSON POST.
          response.statusCode = HttpStatus.noContent;
          response.headers
            ..set('access-control-allow-methods', 'POST, GET, OPTIONS')
            ..set('access-control-allow-headers', 'content-type')
            // Chrome asks for this when a page calls a more private
            // address (Private Network Access), for example a page on the
            // LAN calling localhost.
            ..set('access-control-allow-private-network', 'true')
            ..set('access-control-max-age', '600');
        case 'GET' when path == healthPath:
          _json(response, HttpStatus.ok, {'ok': true, 'schema': annotationSchema});
        case 'POST' when path == annotationsPath:
          await _receive(request);
        case _ when known:
          response.headers.set(
            'allow',
            path == healthPath ? 'GET, OPTIONS' : 'POST, OPTIONS',
          );
          _error(response, HttpStatus.methodNotAllowed, 'Method not allowed');
        default:
          _error(response, HttpStatus.notFound, 'Not found: $path');
      }
    } catch (error) {
      _log('pinpoint: request failed: $error');
      try {
        _error(response, HttpStatus.internalServerError, '$error');
      } catch (_) {
        // Headers already sent; nothing more to say.
      }
    }
    try {
      await response.close();
    } catch (_) {
      // The client went away.
    }
  }

  Future<void> _receive(HttpRequest request) async {
    final response = request.response;

    final origin = request.headers.value('origin');
    if (origin != null && !_originAllowed(origin)) {
      // Any web page open in the browser can post to localhost. The note
      // goes to a coding agent, so only pages from this machine may, unless
      // named with --allow-origin.
      _log(
        'pinpoint: refused a note from $origin. Start the bridge with '
        '--allow-origin $origin to accept it.',
      );
      return _error(
        response,
        HttpStatus.forbidden,
        'Notes from $origin are refused. Start the bridge with '
        '--allow-origin $origin to accept them.',
      );
    }
    if (request.headers.contentType?.mimeType != ContentType.json.mimeType) {
      return _error(
        response,
        HttpStatus.unsupportedMediaType,
        'Send the note as application/json',
      );
    }

    final body = await _readBody(request);
    if (body == null) {
      // Cap the body: base64 makes the screenshot a third larger, and an
      // endless body must not fill the memory. Close the connection after
      // this answer; it may hold more of the body.
      response.persistentConnection = false;
      return _error(
        response,
        HttpStatus.requestEntityTooLarge,
        'The note is over ${maxBodyBytes ~/ (1024 * 1024)} MB',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException catch (error) {
      return _error(
        response,
        HttpStatus.badRequest,
        'Not JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      return _error(
        response,
        HttpStatus.badRequest,
        'The note must be a JSON object',
      );
    }
    final note = decoded;
    if (note['schema'] != annotationSchema) {
      return _error(
        response,
        HttpStatus.badRequest,
        'Unsupported schema ${note['schema']}; this bridge reads schema '
        '$annotationSchema. Update the pinpoint package on one side.',
      );
    }
    // The id becomes a file name. A crafted id such as `../../x` would
    // write outside the notes folder, so it must match the pattern.
    final id = note['id'];
    if (id is! String || !noteIdPattern.hasMatch(id)) {
      return _error(
        response,
        HttpStatus.badRequest,
        'The id must match ${noteIdPattern.pattern}',
      );
    }
    if (File('${_resolvedDir.path}/$id.md').existsSync() ||
        File('${_resolvedDir.path}/$id.json').existsSync()) {
      return _error(
        response,
        HttpStatus.conflict,
        'Note $id is already resolved',
      );
    }

    Uint8List? png;
    if (note['screenshot'] case final Map<String, Object?> shot) {
      final data = shot.remove('data');
      if (data != null) {
        try {
          png = base64Decode(data as String);
        } catch (_) {
          return _error(
            response,
            HttpStatus.badRequest,
            'screenshot.data is not base64',
          );
        }
        if (!_isPng(png)) {
          return _error(
            response,
            HttpStatus.badRequest,
            'screenshot.data is not a PNG',
          );
        }
      }
      // The bridge names the file, so the note always points at the image
      // beside it.
      shot['file'] = png == null ? null : '$id.png';
    }

    final open = openDir.path;
    final markdown = File('$open/$id.md');
    // Image first and Markdown last: an agent that lists *.md sees a note
    // only when everything it points at is in place.
    if (png != null) {
      await _writeAtomic(File('$open/$id.png'), png);
    } else {
      final stale = File('$open/$id.png');
      if (stale.existsSync()) await stale.delete();
    }
    await _writeAtomic(
      File('$open/$id.json'),
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(note)}\n'),
    );
    await _writeAtomic(markdown, utf8.encode(markdownFromJson(note)));

    final comment = note['comment'];
    final summary = comment is String
        ? ' "${clipText(comment.replaceAll(RegExp(r'\s+'), ' '), 60)}"'
        : '';
    final intent = note['intent'];
    _log(
      'pinpoint: ${intent is String ? '$intent ' : ''}note$summary -> '
      '${markdown.path}',
    );
    _json(response, HttpStatus.created, {'id': id, 'markdown': markdown.path});
  }

  /// Prints the agent section when no agent file in the project (the
  /// folder above [folder]) has it yet. Never edits those files; Milestone
  /// 8's `setup --write` does that on request.
  static void _hintInstructions(Directory folder, void Function(String) log) {
    final project = folder.parent.path;
    for (final name in ['CLAUDE.md', 'AGENTS.md']) {
      final file = File('$project/$name');
      try {
        if (file.existsSync() &&
            file.readAsStringSync().contains(agentSectionHeading)) {
          return;
        }
      } on FileSystemException {
        // Unreadable: treat it as missing.
      }
    }
    final dir = folder.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    log(
      'pinpoint: so your coding agent can work the notes, add this section '
      'to CLAUDE.md (Claude Code) or AGENTS.md in $project:\n\n'
      '${agentInstructions(dir: dir)}',
    );
  }

  bool _originAllowed(String origin) =>
      isLoopbackOrigin(origin) ||
      _allowedOrigins.contains('*') ||
      _allowedOrigins.contains(origin);

  /// The whole body, or null when it is over [maxBodyBytes].
  ///
  /// Past the cap the rest is read and dropped, up to [_drainLimit]. A
  /// server that closes a connection with unread data resets it, and the
  /// client then loses the 413 too. Past [_drainLimit] it stops reading.
  static Future<Uint8List?> _readBody(HttpRequest request) async {
    if (request.contentLength > _drainLimit) return null;
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total <= maxBodyBytes) {
        bytes.add(chunk);
      } else if (total > _drainLimit) {
        break;
      }
    }
    return total > maxBodyBytes ? null : bytes.takeBytes();
  }

  /// How much of a body over [maxBodyBytes] is read only to drop it.
  static const int _drainLimit = 4 * maxBodyBytes;

  /// Writes [bytes] to a hidden temporary name in the same folder, then
  /// renames it. A rename within one folder is atomic, so an agent never
  /// reads a half-written note.
  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final name = file.uri.pathSegments.last;
    final temp = File('${file.parent.path}/.$name.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  static bool _isPng(Uint8List bytes) {
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  static void _json(HttpResponse response, int status, Object body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  static void _error(HttpResponse response, int status, String message) =>
      _json(response, status, {'error': message});
}

void _noLog(String line) {}
