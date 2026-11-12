// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so
// `dart run pinpoint:bridge` can run it. Never exported from pinpoint.dart;
// the app (web) cannot import `dart:io`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/annotation.dart' show NoteStatus, annotationSchema, clipText;
import 'agent_instructions.dart';
import 'bridge_protocol.dart';
import 'command_queue.dart';
import 'hot_reload.dart';
import 'mcp_server.dart';
import 'note_store.dart';

/// Why the bridge could not start.
class BridgeStartException implements Exception {
  const BridgeStartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The local bridge between the overlay and a coding agent.
///
/// It takes each note the overlay posts and writes it into `<dir>/open/` as
/// `<id>.md`, `<id>.json` and `<id>.png`, for a coding agent to read
/// (drafts go to `<dir>/drafts/`, which no agent reads). The app reloads
/// its pins from it, and polls it for what the agent changed.
///
/// HTTP for the app:
///
/// - `POST /annotations`: a new or changed note.
/// - `GET /annotations?status=a,b&origin=o`: notes, to restore pins.
/// - `PATCH /annotations/<id>`: `status`, `comment`, `intent`, `message`.
/// - `DELETE /annotations/<id>`.
/// - `GET /changes?since=<cursor>&origin=o`: what changed since a cursor.
/// - `GET /health`.
///
/// MCP for the agent: `POST /mcp` (Streamable HTTP with JSON answers; no
/// server-sent events) with the tools of [McpServer].
class PinPointBridge {
  PinPointBridge._(
    this._server,
    this.store,
    this._allowedOrigins,
    this._log, {
    required bool timing,
  }) : commands = CommandQueue(log: timing ? _log : null) {
    _subscription = _server.listen(_handle);
  }

  /// Creates `<dir>/drafts/`, `<dir>/open/` and `<dir>/resolved/`, reads
  /// the notes already there, and starts listening.
  ///
  /// Port 0 picks a free port; read it from [port]. Throws a
  /// [BridgeStartException] when the port cannot be bound.
  static Future<PinPointBridge> start({
    required String dir,
    int port = defaultBridgePort,
    bool lan = false,
    List<String> allowedOrigins = const <String>[],
    bool timing = false,
    void Function(String line) log = _noLog,
  }) async {
    final folder = Directory(dir).absolute;
    final store = await NoteStore.open(folder, log: log);

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
    return PinPointBridge._(server, store, allowedOrigins, log, timing: timing);
  }

  final HttpServer _server;

  /// The notes on disk.
  final NoteStore store;

  /// Agent commands on their way to the app (Milestone 12).
  final CommandQueue commands;

  final List<String> _allowedOrigins;
  late final McpServer _mcp = McpServer(
    store,
    commands: commands,
    reloader: HotReloader(store.root),
    log: _log,
  );
  final void Function(String line) _log;
  late final StreamSubscription<HttpRequest> _subscription;

  /// The port it listens on.
  int get port => _server.port;

  /// The address it listens on: loopback unless started in LAN mode.
  InternetAddress get address => _server.address;

  /// The folder an agent reads: `<dir>/open/`.
  Directory get openDir => store.openDir;

  /// Stops listening and drops open connections.
  Future<void> close() async {
    commands.close();
    await _subscription.cancel();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    // On every response, so the app can read errors too. It carries no
    // credentials, so `*` exposes nothing a page could not get anyway; the
    // origin check below decides who may read and change notes.
    response.headers.set('access-control-allow-origin', '*');
    try {
      final path = request.uri.path;
      final noteId = path.startsWith('$annotationsPath/')
          ? path.substring(annotationsPath.length + 1)
          : null;
      final known =
          path == annotationsPath ||
          path == healthPath ||
          path == changesPath ||
          path == mcpPath ||
          path == commandsPath ||
          path.startsWith('$commandsPath/') ||
          noteId != null;
      if (request.method == 'OPTIONS' && known) {
        // A browser sends this before every JSON POST, PATCH and DELETE.
        response.statusCode = HttpStatus.noContent;
        response.headers
          ..set(
            'access-control-allow-methods',
            'GET, POST, PATCH, DELETE, OPTIONS',
          )
          ..set(
            'access-control-allow-headers',
            'content-type, mcp-protocol-version, mcp-session-id',
          )
          // Chrome asks for this when a page calls a more private
          // address (Private Network Access), for example a page on the
          // LAN calling localhost.
          ..set('access-control-allow-private-network', 'true')
          ..set('access-control-max-age', '600');
      } else if (request.method == 'GET' && path == healthPath) {
        _json(response, HttpStatus.ok, {
          'ok': true,
          'schema': annotationSchema,
        });
      } else if (!known) {
        _error(response, HttpStatus.notFound, 'Not found: $path');
      } else if (_refusedOrigin(request) case final origin?) {
        // Any web page open in the browser can call localhost. Notes go to
        // a coding agent and hold comments and screenshots, so only pages
        // from this machine may send or read them, unless named with
        // --allow-origin.
        _log(
          'pinpoint: refused a request from $origin. Start the bridge '
          'with --allow-origin $origin to accept it.',
        );
        _error(
          response,
          HttpStatus.forbidden,
          'Requests from $origin are refused. Start the bridge with '
          '--allow-origin $origin to accept them.',
        );
      } else {
        await _route(request, path, noteId);
      }
    } on StoreException catch (error) {
      _error(response, error.status, error.message);
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

  Future<void> _route(HttpRequest request, String path, String? noteId) async {
    final response = request.response;
    final method = request.method;
    if (noteId != null) {
      // The id becomes a file name. A crafted id such as `../../x` would
      // reach outside the notes folder, so it must match the pattern.
      if (!noteIdPattern.hasMatch(noteId)) {
        return _error(
          response,
          HttpStatus.badRequest,
          'The id must match ${noteIdPattern.pattern}',
        );
      }
      switch (method) {
        case 'GET':
          final note = await store.read(noteId);
          return note == null
              ? _error(response, HttpStatus.notFound, 'No note $noteId')
              : _json(response, HttpStatus.ok, note);
        case 'PATCH':
          return _patch(request, noteId);
        case 'DELETE':
          return await store.delete(noteId)
              ? _json(response, HttpStatus.ok, {'id': noteId, 'deleted': true})
              : _error(response, HttpStatus.notFound, 'No note $noteId');
      }
      response.headers.set('allow', 'GET, PATCH, DELETE, OPTIONS');
      return _error(
        response,
        HttpStatus.methodNotAllowed,
        'Method not allowed',
      );
    }
    if (path == commandsPath || path.startsWith('$commandsPath/')) {
      return _command(request, path);
    }
    switch ((method, path)) {
      case ('POST', mcpPath):
        return _mcpCall(request);
      case ('POST', annotationsPath):
        return _receive(request);
      case ('GET', annotationsPath):
        final query = request.uri.queryParameters;
        final Set<NoteStatus>? statuses;
        try {
          statuses = _statuses(query['status']);
        } on FormatException catch (error) {
          return _error(response, HttpStatus.badRequest, error.message);
        }
        final notes = await store.list(
          statuses: statuses,
          origin: query['origin'],
        );
        return _json(response, HttpStatus.ok, {
          'cursor': store.cursor,
          'notes': notes,
        });
      case ('GET', changesPath):
        final query = request.uri.queryParameters;
        final changes = await store.changes(
          query['since'],
          origin: query['origin'],
        );
        return _json(response, HttpStatus.ok, changes.toJson());
    }
    response.headers.set('allow', switch (path) {
      healthPath || changesPath => 'GET, OPTIONS',
      _ => 'GET, POST, OPTIONS',
    });
    _error(response, HttpStatus.methodNotAllowed, 'Method not allowed');
  }

  /// The app's side of the command channel: its long poll, its answers,
  /// and the control switch.
  Future<void> _command(HttpRequest request, String path) async {
    final response = request.response;
    final method = request.method;
    if (method == 'GET' && path == commandsPath) {
      final wait = int.tryParse(request.uri.queryParameters['wait'] ?? '');
      final command = await commands.next(
        wait: Duration(seconds: (wait ?? commandWait.inSeconds).clamp(0, 30)),
      );
      return _json(response, HttpStatus.ok, {'command': command});
    }
    if (method == 'POST' && path == '$commandsPath/control') {
      final body = await _jsonBody(request);
      if (body == null) return;
      final enabled = body['enabled'] == true;
      commands.setControl(enabled);
      _log('pinpoint: agent control is ${enabled ? 'on' : 'off'} in the app');
      return _json(response, HttpStatus.ok, {'enabled': enabled});
    }
    final match = RegExp(
      '^${RegExp.escape(commandsPath)}/(c[0-9]{1,9})/result\$',
    ).firstMatch(path);
    if (method == 'POST' && match != null) {
      final body = await _jsonBody(request);
      if (body == null) return;
      return commands.complete(match.group(1)!, body)
          ? _json(response, HttpStatus.ok, {'ok': true})
          : _error(response, HttpStatus.notFound, 'No command ${match[1]}');
    }
    if (match == null &&
        path != commandsPath &&
        path != '$commandsPath/control') {
      return _error(response, HttpStatus.notFound, 'Not found: $path');
    }
    response.headers.set(
      'allow',
      method == 'GET' ? 'POST, OPTIONS' : 'GET, OPTIONS',
    );
    _error(response, HttpStatus.methodNotAllowed, 'Method not allowed');
  }

  /// One MCP message or batch. Answers 202 with no body when nothing is
  /// owed (notifications), else 200 with the JSON-RPC answer.
  Future<void> _mcpCall(HttpRequest request) async {
    final response = request.response;
    if (request.headers.contentType?.mimeType != ContentType.json.mimeType) {
      return _error(
        response,
        HttpStatus.unsupportedMediaType,
        'Send MCP messages as application/json',
      );
    }
    final body = await _readBody(request);
    Object? message;
    try {
      if (body == null) throw const FormatException('over the size cap');
      message = jsonDecode(utf8.decode(body));
    } on FormatException catch (error) {
      return _json(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error: ${error.message}'},
      });
    }
    final answer = await _mcp.handle(message);
    if (answer == null) {
      response.statusCode = HttpStatus.accepted;
      return;
    }
    _json(response, HttpStatus.ok, answer);
  }

  /// `a,b` as statuses; null for none or empty. Throws a
  /// [FormatException] for an unknown name.
  static Set<NoteStatus>? _statuses(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    return {
      for (final name in text.split(','))
        NoteStatus.byName(name.trim()) ??
            (throw FormatException('Unknown status: ${name.trim()}')),
    };
  }

  Future<void> _patch(HttpRequest request, String id) async {
    final response = request.response;
    final body = await _jsonBody(request);
    if (body == null) return;
    final status = body['status'];
    final parsed = status == null ? null : NoteStatus.byName(status);
    if (status != null && parsed == null) {
      return _error(response, HttpStatus.badRequest, 'Unknown status: $status');
    }
    for (final field in ['comment', 'intent', 'message']) {
      if (body[field] != null && body[field] is! String) {
        return _error(
          response,
          HttpStatus.badRequest,
          '$field must be a string',
        );
      }
    }
    final note = await store.update(
      id,
      status: parsed,
      comment: body['comment'] as String?,
      intent: body['intent'] as String?,
      message: body['message'] as String?,
    );
    _log('pinpoint: note $id is ${note['status']}');
    _json(response, HttpStatus.ok, note);
  }

  /// The request's JSON object, or null after answering with the error.
  Future<Map<String, Object?>?> _jsonBody(HttpRequest request) async {
    final response = request.response;
    if (request.headers.contentType?.mimeType != ContentType.json.mimeType) {
      _error(
        response,
        HttpStatus.unsupportedMediaType,
        'Send the body as application/json',
      );
      return null;
    }
    final body = await _readBody(request);
    if (body == null) {
      // Cap the body: base64 makes the screenshot a third larger, and an
      // endless body must not fill the memory. Close the connection after
      // this answer; it may hold more of the body.
      response.persistentConnection = false;
      _error(
        response,
        HttpStatus.requestEntityTooLarge,
        'The note is over ${maxBodyBytes ~/ (1024 * 1024)} MB',
      );
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException catch (error) {
      _error(response, HttpStatus.badRequest, 'Not JSON: ${error.message}');
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      _error(response, HttpStatus.badRequest, 'The body must be a JSON object');
      return null;
    }
    return decoded;
  }

  /// The request's origin when it may not use the bridge, else null. No
  /// `Origin` (curl, an agent) is allowed.
  String? _refusedOrigin(HttpRequest request) {
    final origin = request.headers.value('origin');
    return origin == null || _originAllowed(origin) ? null : origin;
  }

  Future<void> _receive(HttpRequest request) async {
    final response = request.response;
    final note = await _jsonBody(request);
    if (note == null) return;
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
    final status = note['status'];
    if (status != null && NoteStatus.byName(status) == null) {
      return _error(response, HttpStatus.badRequest, 'Unknown status: $status');
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
    }

    // A draft sent again (now submitted) after an app restart has no image
    // data; its PNG is already here.
    final path = await store.save(note, png, keepPng: png == null);

    final comment = note['comment'];
    final summary = comment is String
        ? ' "${clipText(comment.replaceAll(RegExp(r'\s+'), ' '), 60)}"'
        : '';
    final intent = note['intent'];
    final saved = note['status'];
    _log(
      'pinpoint: ${saved == 'draft' ? 'draft ' : ''}'
      '${intent is String ? '$intent ' : ''}note$summary -> $path',
    );
    _json(response, HttpStatus.created, {
      'id': id,
      'status': saved,
      if (saved != 'draft') 'markdown': path,
    });
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
