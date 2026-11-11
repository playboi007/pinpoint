// Plain Dart with `dart:io`: the MCP tools of `dart run pinpoint:bridge`.
//
// A small JSON-RPC 2.0 handler, written by hand: `package:dart_mcp` ships
// only a stdio transport (docs/api-notes.md, item 15), and the bridge
// serves MCP over HTTP on its own port. No dependency is added.

import 'dart:convert';
import 'dart:typed_data';

import '../model/annotation.dart' show NoteStatus;
import '../sink/markdown_formatter.dart' show verificationLines;
import 'agent_tools.dart';
import 'command_queue.dart';
import 'note_detail.dart';
import 'note_store.dart';
import 'png_resize.dart';

/// The MCP protocol versions this server speaks, newest first.
const List<String> mcpProtocolVersions = [
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// The widest screenshot a tool result holds. A large base64 image can
/// blow the agent's context.
const int mcpMaxImageWidth = 800;

/// The most notes one `list_notes` call returns.
const int mcpMaxListed = 50;

/// The agent's tools: `list_notes`, `get_note` and `update_note`, over the
/// notes in [store], and with [commands] the Milestone 12 tools that run in
/// the app ([agentToolNames]).
///
/// Drafts are invisible here: no tool lists, reads or changes one, so
/// half-written feedback never triggers an edit.
class McpServer {
  McpServer(
    this.store, {
    this.commands,
    this.version = '0.0.1',
    this._log = _noLog,
  });

  final NoteStore store;

  /// The way to the app; null: the note tools only.
  final CommandQueue? commands;

  final void Function(String line) _log;

  /// Reported as `serverInfo.version`.
  final String version;

  /// Answers [message]: one JSON-RPC message, or a batch (a list). Returns
  /// what to send back, or null when nothing is owed (notifications and
  /// responses).
  Future<Object?> handle(Object? message) async {
    if (message is List<Object?>) {
      if (message.isEmpty) return _error(null, -32600, 'Empty batch');
      final answers = [for (final m in message) ?await _one(m)];
      return answers.isEmpty ? null : answers;
    }
    return _one(message);
  }

  Future<Map<String, Object?>?> _one(Object? message) async {
    if (message is! Map<String, Object?> || message['jsonrpc'] != '2.0') {
      return _error(null, -32600, 'Not a JSON-RPC 2.0 message');
    }
    final id = message['id'];
    final method = message['method'];
    // A response from the client, or a notification: nothing to answer.
    if (method is! String) return null;
    if (!message.containsKey('id')) return null;
    final params = message['params'];
    final args = params is Map<String, Object?>
        ? params
        : const <String, Object?>{};
    try {
      return switch (method) {
        'initialize' => _result(id, _initialize(args)),
        'ping' => _result(id, const <String, Object?>{}),
        'tools/list' => _result(id, {
          'tools': [..._tools, if (commands != null) ...agentTools],
        }),
        'tools/call' => _result(id, await _call(args)),
        _ => _error(id, -32601, 'Method not found: $method'),
      };
    } on _InvalidParams catch (error) {
      return _error(id, -32602, error.message);
    } on Object catch (error) {
      return _error(id, -32603, '$error');
    }
  }

  Map<String, Object?> _initialize(Map<String, Object?> args) {
    final asked = args['protocolVersion'];
    return {
      'protocolVersion': mcpProtocolVersions.contains(asked)
          ? asked
          : mcpProtocolVersions.first,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': 'pinpoint', 'version': version},
      'instructions':
          'UI feedback from the running Flutter app. list_notes shows the '
          'open notes; get_note gives one with its screenshot. Work a note: '
          'set it inProgress, open the Source file at the line, make the '
          'change, run flutter analyze, then set it resolved (or fixed, or '
          'rejected) with a one-line message saying what you did. The user '
          'accepts the result in the app.',
    };
  }

  static final List<Map<String, Object?>> _tools = [
    {
      'name': 'list_notes',
      'title': 'List Pinpoint notes',
      'description':
          'Lists UI notes the user sent from the running app. Default: the '
          'open ones (submitted, inProgress, fixed). Drafts are never '
          'listed.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'status': {
            'type': 'string',
            'enum': [
              'open',
              'all',
              for (final s in NoteStatus.values)
                if (s != NoteStatus.draft) s.name,
            ],
            'description': 'Which notes. "all" is every sent note.',
          },
          'detail': _detailSchema,
        },
      },
    },
    {
      'name': 'get_note',
      'title': 'Get a Pinpoint note',
      'description':
          'One note by id. At standard and full detail the screenshot is '
          'attached, at most $mcpMaxImageWidth px wide; the widget is '
          'outlined in red.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'For example pp_20261110_143205_a1f3',
          },
          'detail': _detailSchema,
        },
        'required': ['id'],
      },
    },
    {
      'name': 'update_note',
      'title': 'Update a Pinpoint note',
      'description':
          'Sets a note\'s status and adds a message for the user. The pin '
          'in the app follows within seconds. resolved and rejected move '
          'the note to .pinpoint/resolved/.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'status': {
            'type': 'string',
            'enum': ['inProgress', 'fixed', 'resolved', 'rejected'],
          },
          'message': {
            'type': 'string',
            'description': 'One line for the user: what you did, or why not.',
          },
        },
        'required': ['id'],
      },
    },
  ];

  static const Map<String, Object?> _detailSchema = {
    'type': 'string',
    'enum': ['compact', 'standard', 'full'],
    'description':
        'compact: comment, source and rect. standard (default): adds layout, '
        'enclosing widgets and the screenshot. full: adds properties, '
        'subtree and environment.',
  };

  Future<Map<String, Object?>> _call(Map<String, Object?> args) async {
    final name = args['name'];
    final raw = args['arguments'];
    final input = raw is Map<String, Object?> ? raw : const <String, Object?>{};
    return switch (name) {
      'list_notes' => _listNotes(input),
      'get_note' => _getNote(input),
      'update_note' => _updateNote(input),
      'verify_note' when commands != null => _verifyNote(input),
      final String tool
          when commands != null && agentToolNames.contains(tool) =>
        _agent(tool, input),
      _ => throw _InvalidParams('Unknown tool: $name'),
    };
  }

  Future<Map<String, Object?>> _listNotes(Map<String, Object?> input) async {
    final detail = _detail(input);
    final status = input['status'] ?? 'open';
    if (status == 'draft') {
      return _text(
        'Drafts stay with the user until they send them.',
        isError: true,
      );
    }
    final Set<NoteStatus> statuses;
    if (status == 'open') {
      statuses = NoteStatus.open;
    } else if (status == 'all') {
      statuses = {...NoteStatus.values}..remove(NoteStatus.draft);
    } else if (NoteStatus.byName(status) case final one?) {
      statuses = {one};
    } else {
      throw _InvalidParams('Unknown status: $status');
    }
    await store.sync();
    final notes = await store.list(statuses: statuses);
    if (notes.isEmpty) return _text('No $status notes.');
    final shown = notes.take(mcpMaxListed).toList();
    final more = notes.length - shown.length;
    return _text(
      [
        '${notes.length} $status note${notes.length == 1 ? '' : 's'}:',
        for (final note in shown) noteText(note, detail),
        if (more > 0) '… and $more more. Ask for one status at a time.',
      ].join('\n\n'),
    );
  }

  Future<Map<String, Object?>> _getNote(Map<String, Object?> input) async {
    final id = _id(input);
    final detail = _detail(input);
    final note = await _sentNote(id);
    if (note == null) return _notFound(id);
    final content = <Map<String, Object?>>[
      {'type': 'text', 'text': noteText(note, detail)},
    ];
    // Never at compact, and never the full-size image: a large base64
    // image can blow the agent's context.
    if (detail != NoteDetail.compact) {
      final file = store.pngOf(id);
      if (file != null) {
        final small = downscalePng(
          await file.readAsBytes(),
          maxWidth: mcpMaxImageWidth,
        );
        content.add(
          small == null
              ? {
                  'type': 'text',
                  'text':
                      'Screenshot not attached (unsupported PNG): '
                      '${file.path}',
                }
              : {
                  'type': 'image',
                  'data': base64Encode(small),
                  'mimeType': 'image/png',
                },
        );
      }
    }
    return {'content': content, 'isError': false};
  }

  Future<Map<String, Object?>> _updateNote(Map<String, Object?> input) async {
    final id = _id(input);
    final status = input['status'];
    final message = input['message'];
    const allowed = {'inProgress', 'fixed', 'resolved', 'rejected'};
    if (status != null && !allowed.contains(status)) {
      throw _InvalidParams('status must be one of ${allowed.join(', ')}');
    }
    if (message != null && message is! String) {
      throw const _InvalidParams('message must be a string');
    }
    if (status == null && message == null) {
      throw const _InvalidParams('Give a status, a message or both');
    }
    if (await _sentNote(id) == null) return _notFound(id);
    final note = await store.update(
      id,
      status: NoteStatus.byName(status),
      message: message as String?,
      from: 'agent',
    );
    _log(
      'pinpoint: the agent set $id to ${note['status']}'
      '${message == null ? '' : ': $message'}',
    );
    return _text(
      'Note $id is ${note['status']}.\n\n'
      '${noteText(note, NoteDetail.compact)}',
    );
  }

  /// Runs [tool] in the app and turns its answer into tool content. An
  /// image in the answer (`png`, base64) becomes image content, at most
  /// [mcpMaxImageWidth] wide; the rest is compact JSON.
  Future<Map<String, Object?>> _agent(
    String tool,
    Map<String, Object?> input,
  ) async {
    final answer = await commands!.run(
      tool,
      input,
      timeout: agentToolTimeout(tool, input),
    );
    if (answer['ok'] != true) {
      return _text('${answer['error']}', isError: true);
    }
    final result = answer['result'];
    if (tool == 'inspect' && result is Map<String, Object?>) {
      if (result['note'] case final Map<String, Object?> note) {
        return _text(
          inspectText(
            '${result['handle']}',
            note,
            NoteDetail.byName(input['detail']) ?? NoteDetail.standard,
          ),
        );
      }
    }
    return _resultContent(
      result is Map<String, Object?> ? {...result} : result,
    );
  }

  /// Runs the note's checks in the app (`verify_note`), then stores the
  /// outcome in the note (`verification`), the after screenshot beside it
  /// and a one-line message from `pinpoint`.
  ///
  /// The status is left alone: `verified` means the user accepted the
  /// result (Milestone 8), and the pin shows the outcome for them to do so.
  Future<Map<String, Object?>> _verifyNote(Map<String, Object?> input) async {
    final id = _id(input);
    final note = await _sentNote(id);
    if (note == null) return _notFound(id);
    final page = note['page'];
    final answer = await commands!.run('verify_note', {
      'note': {
        'id': id,
        'anchor': note['anchor'],
        'checks': note['checks'] ?? const <Object?>[],
        'environment': note['environment'],
        'page': {if (page is Map<String, Object?>) 'route': page['route']},
      },
    }, timeout: agentToolTimeout('verify_note', input));
    if (answer['ok'] != true) {
      return _text('${answer['error']}', isError: true);
    }
    final result = answer['result'];
    if (result is! Map<String, Object?>) {
      return _text('The app gave no result', isError: true);
    }
    Uint8List? png;
    if (result['png'] case final String data) {
      try {
        png = base64Decode(data);
      } on FormatException {
        png = null;
      }
    }
    final after = png == null ? null : await store.saveAfter(id, png);
    final checks = result['checks'] is List<Object?>
        ? result['checks']! as List<Object?>
        : const <Object?>[];
    final passed = result['passed'] == true;
    final count = checks.where((c) => c is Map && c['passed'] == true).length;
    final verification = <String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'passed': passed,
      'checks': checks,
      'found': result['found'],
      'after': ?after,
    };
    final summary =
        'Checks ${passed ? 'passed' : 'failed'} ($count of ${checks.length} '
        'passed)';
    final updated = await store.update(
      id,
      verification: verification,
      message: summary,
      from: 'pinpoint',
    );
    _log('pinpoint: verified $id: $summary');
    final lines = [
      'Note $id: $summary.',
      for (final line in verificationLines(updated).skip(1)) line,
      if (result['found'] case final String found) 'Found at $found.',
      if (result['defaulted'] case final String why) 'Note: $why.',
      if (!passed)
        'Fix the code, ask for a hot reload, then call verify_note again.'
      else
        'Set the note fixed or resolved; the user accepts it in the app.',
    ];
    return {
      'content': [
        {'type': 'text', 'text': lines.join('\n')},
        if (png != null)
          {
            'type': 'image',
            'data': base64Encode(
              downscalePng(png, maxWidth: mcpMaxImageWidth) ?? png,
            ),
            'mimeType': 'image/png',
          },
      ],
      'isError': false,
    };
  }

  /// [result] as text, with its `png` (base64) as an image.
  Map<String, Object?> _resultContent(Object? result) {
    Map<String, Object?>? image;
    if (result is Map<String, Object?> && result['png'] is String) {
      final png = result.remove('png')! as String;
      try {
        final bytes = base64Decode(png);
        final small = downscalePng(bytes, maxWidth: mcpMaxImageWidth) ?? bytes;
        image = {
          'type': 'image',
          'data': base64Encode(small),
          'mimeType': 'image/png',
        };
      } on FormatException {
        result['image'] = 'not attached (not base64)';
      }
    }
    return {
      'content': [
        {'type': 'text', 'text': jsonEncode(result)},
        ?image,
      ],
      'isError': false,
    };
  }

  /// The note [id], unless it is a draft or unknown.
  Future<Map<String, Object?>?> _sentNote(String id) async {
    final note = await store.read(id);
    if (note == null || note['status'] == NoteStatus.draft.name) return null;
    return note;
  }

  static String _id(Map<String, Object?> input) {
    final id = input['id'];
    if (id is! String || id.isEmpty) {
      throw const _InvalidParams('id is required');
    }
    return id;
  }

  static NoteDetail _detail(Map<String, Object?> input) =>
      NoteDetail.byName(input['detail']) ??
      (throw _InvalidParams('Unknown detail: ${input['detail']}'));

  static Map<String, Object?> _notFound(String id) => _text(
    'No note $id. list_notes shows the open ones; drafts stay with the user.',
    isError: true,
  );

  static Map<String, Object?> _text(String text, {bool isError = false}) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': isError,
  };

  static Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}

void _noLog(String line) {}

class _InvalidParams implements Exception {
  const _InvalidParams(this.message);

  final String message;
}
