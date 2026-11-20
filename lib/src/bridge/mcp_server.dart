// Plain Dart with `dart:io`: the MCP tools of `dart run pinpoint:bridge`.
//
// A small JSON-RPC 2.0 handler, written by hand: `package:dart_mcp` ships
// only a stdio transport (docs/api-notes.md, item 15), and the bridge
// serves MCP over HTTP on its own port. No dependency is added.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/annotation.dart' show NoteStatus;
import '../model/note_round.dart';
import '../sink/markdown_formatter.dart' show verificationLines;
import '../trace/trace_format.dart';
import '../trace/trace_recorder.dart';
import 'agent_tools.dart';
import 'command_queue.dart';
import 'hot_reload.dart';
import 'note_detail.dart';
import 'note_rounds.dart';
import 'note_store.dart';
import 'png_resize.dart';
import 'probe_scan.dart';
import 'run_store.dart';
import 'source_lookup.dart';
import 'state_flow_text.dart';
import 'tape_store.dart';

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

/// The longest patch `get_note_diff` returns, in bytes. A longer one gets
/// the list of files only.
const int mcpMaxDiffBytes = 40 * 1024;

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
    this.reloader,
    TapeStore? tapes,
    RunStore? runs,
    SourceLookup? source,
    this.version = '0.0.1',
    void Function(String line) log = _noLog,
  }) : _tapes = tapes,
       _runs = runs,
       _source = source,
       _log = log;

  final TapeStore? _tapes;
  final RunStore? _runs;
  final SourceLookup? _source;

  /// The app's source for `state_flow`: the project folder is the one that
  /// holds the notes folder.
  late final SourceLookup source = _source ?? SourceLookup(store.root.parent);

  /// Replay runs on disk.
  late final RunStore runs = _runs ?? RunStore(store.root);

  final NoteStore store;

  /// The way to the app; null: the note tools only.
  final CommandQueue? commands;

  /// Gives the agent `hot_reload`; null: no such tool.
  final HotReloader? reloader;

  /// Tapes on disk (PLAN-v2 Milestone 15).
  late final TapeStore tapes = _tapes ?? TapeStore(store.root);

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
          'tools': [
            ..._tools,
            if (reloader != null) hotReloadTool,
            if (commands != null) ...agentTools,
          ],
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
          'accepts the result in the app. A note the user reopened is '
          'submitted again, "reopened" in its header, with their reason as '
          'the last reply: work it again, set it fixed again, and call '
          'verify_note again if it has checks. Finish every code change for '
          'a note that way, also when the user asked for it in chat: the pin '
          'shows only what update_note says. When you set a note fixed, '
          'give changes: one {summary, files} for each separate change, so '
          'the user can undo one of them. After an undo the note is '
          'submitted again: do not make the undone changes again. If the '
          'last reply says "Undo these changes yourself", revert those '
          'files (get_note_diff gives the patch), then continue.'
          '${commands == null ? '' : ' To operate the app, name widgets with '
                    'target queries and put several actions in one '
                    'run_steps call; check once at the end. To see what '
                    'happened over time, call get_trace (trace_detail or '
                    'watch add rebuilds and state). To learn what started '
                    'an event, call why with its seq; to learn what a '
                    'widget started, caused_by; to learn why two values '
                    'change together, or what changed a value, state_flow. '
                    'For a value no '
                    'diagnostics show, add a PinPoint.probe line, '
                    'hot_reload, read it with get_trace, and remove it '
                    'before you set the note fixed (list_probes). A note '
                    'that "has tape" can happen again: replay({tape}) '
                    'plays what the user did and answers first_difference; '
                    'until: "mark" holds at the user\'s mark for get_state '
                    'and screenshot. Read the run with get_trace({run}).'}',
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
          'the note to .pinpoint/resolved/. After each fix, also of a '
          'reopened note, set fixed or resolved: the user can accept only '
          'what you marked done. With fixed or resolved, give changes: one '
          '{summary, files} for each separate change you made, so the user '
          'can undo one of them. Files you did not name show as "other".',
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
          'changes': {
            'type': 'array',
            'description':
                'With fixed or resolved: your separate changes, so the user '
                'can undo one. Each has a short summary and the files it '
                'touched (paths relative to the app folder, or absolute). '
                'A file that is not in this round\'s diff is dropped.',
            'items': {
              'type': 'object',
              'properties': {
                'summary': {
                  'type': 'string',
                  'description': 'For example "Spacing between the filters".',
                },
                'files': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
              },
              'required': ['summary'],
            },
          },
        },
        'required': ['id'],
      },
    },
    {
      'name': 'get_note_diff',
      'title': 'Get what the agent changed for a note',
      'description':
          'The patch (before to after) of one round of a note, for all its '
          'changes or one change. Use it when the note says "Undo these '
          'changes yourself": revert those files, then continue. A patch '
          'over ${mcpMaxDiffBytes ~/ 1024} KB gives the file list only: ask '
          'for one change at a time. Without git it lists the files you '
          'named.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'round': {
            'type': 'integer',
            'description': 'The round number. Default: the latest closed one.',
          },
          'change': {
            'type': 'string',
            'description': 'One change id of the round, for example c1.',
          },
        },
        'required': ['id'],
      },
    },
    {
      'name': 'list_tapes',
      'title': 'List tapes',
      'description':
          'The tapes on the bridge, newest first: id, kind (full from app '
          'start, or segment from a mark), inputs, requests, marks, body '
          'size, and partial when a limit dropped data. A note with a tape '
          'says "has tape" and names it. No body is ever shown.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'get_tape',
      'title': 'Read a tape',
      'description':
          'One tape in short: its summary, start page, marks, route order, '
          'inputs (step, kind, widget, how many answers it waits for) and '
          'requests (method, masked URL, status). No body.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'For example tp_…'},
        },
        'required': ['id'],
      },
    },
    {
      'name': 'list_probes',
      'title': 'List probe lines',
      'description':
          'The PinPoint.probe( lines left under lib/, with file and line. '
          'A probe records values each time it runs (read them with '
          'get_trace kinds [probe]); remove every probe before you set a '
          'note fixed.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
  ];

  static const Map<String, Object?> _detailSchema = {
    'type': 'string',
    'enum': ['compact', 'standard', 'full'],
    'description':
        'compact: comment, source and rect. standard (default): adds layout, '
        'enclosing widgets and the screenshot. full: adds properties, '
        'subtree, state owners and environment.',
  };

  Future<Map<String, Object?>> _call(Map<String, Object?> args) async {
    final name = args['name'];
    final raw = args['arguments'];
    final input = raw is Map<String, Object?> ? raw : const <String, Object?>{};
    return switch (name) {
      'list_notes' => _listNotes(input),
      'get_note' => _getNote(input),
      'update_note' => _updateNote(input),
      'get_note_diff' => _getNoteDiff(input),
      'list_probes' => _listProbes(),
      'list_tapes' => _listTapes(),
      'get_trace' when input['run'] != null => _runTrace(input),
      'get_tape' => _getTape(input),
      'verify_note' when commands != null => _verifyNote(input),
      'hot_reload' when reloader != null => _hotReload(input),
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
    final List<ChangeLabel> labels;
    try {
      labels = ChangeLabel.parse(input['changes']);
    } on FormatException catch (error) {
      throw _InvalidParams(error.message);
    }
    if (status == null && message == null && labels.isEmpty) {
      throw const _InvalidParams('Give a status, a message or both');
    }
    if (await _sentNote(id) == null) return _notFound(id);
    final report = RoundsReport();
    final note = await store.update(
      id,
      status: NoteStatus.byName(status),
      message: message as String?,
      from: 'agent',
      changes: labels,
      report: report,
    );
    _log(
      'pinpoint: the agent set $id to ${note['status']}'
      '${message == null ? '' : ': $message'}',
    );
    // Probe lines are for finding a bug, not for the fix: say so while
    // any remain (PLAN-v2 Milestone 13, step 7).
    final probes = status == 'fixed' || status == 'resolved'
        ? await findProbes(store.root.parent)
        : const <ProbeLine>[];
    return _text(
      'Note $id is ${note['status']}.\n\n'
      '${noteText(note, NoteDetail.compact)}'
      '${_roundReport(report, labels.isNotEmpty)}'
      '${probes.isEmpty ? '' : '\n\n${_probeWarning(probes)}'}',
    );
  }

  /// What closing the round found, for the answer to `update_note`: the
  /// changes with their ids, and what was dropped.
  static String _roundReport(RoundsReport report, bool labelled) {
    final json = report.closed;
    final round = json == null ? null : NoteRound.fromJson(json);
    if (round == null) return '';
    final lines = <String>[
      if (round.changes.isNotEmpty) 'Round ${round.n}:',
      for (final c in round.changes)
        '  ${c.id}: ${c.summary} (${c.files.length} '
            'file${c.files.length == 1 ? '' : 's'})',
      for (final file in report.droppedFiles)
        'Dropped $file: it is not in this round\'s diff.',
      for (final summary in report.droppedChanges)
        'Dropped "$summary": none of its files is in this round\'s diff.',
      if (!labelled && round.changes.isNotEmpty)
        'Next time give changes: [{summary, files}] with fixed, so the user '
            'can undo one change.',
    ];
    return lines.isEmpty ? '' : '\n\n${lines.join('\n')}';
  }

  /// `get_note_diff`: the patch of one round, or of one change of it.
  Future<Map<String, Object?>> _getNoteDiff(Map<String, Object?> input) async {
    final id = _id(input);
    final note = await _sentNote(id);
    if (note == null) return _notFound(id);
    final asked = input['round'];
    if (asked != null && asked is! int) {
      throw const _InvalidParams('round is a number');
    }
    final change = input['change'];
    if (change != null && change is! String) {
      throw const _InvalidParams('change is a change id, for example c1');
    }
    final stored = note['rounds'];
    final rounds = [
      for (final r in stored is List<Object?> ? stored : const <Object?>[])
        if (r is Map<String, Object?>) ?NoteRound.fromJson(r),
    ];
    final closed = rounds.where((r) => !r.isOpen).toList();
    final round = asked == null
        ? closed.lastOrNull
        : rounds.where((r) => r.n == asked).firstOrNull;
    if (round == null) {
      return _text(
        asked == null
            ? 'Note $id has no finished round yet.'
            : 'Note $id has no round $asked. It has: '
                  '${rounds.map((r) => r.n).join(', ')}.',
        isError: true,
      );
    }
    if (round.isOpen) {
      return _text('Round ${round.n} is still open.', isError: true);
    }
    final changes = [
      for (final c in round.changes)
        if (change == null || c.id == change) c,
    ];
    if (changes.isEmpty) {
      return _text(
        change == null
            ? 'Round ${round.n} has no changes.'
            : 'Round ${round.n} has no change $change. It has: '
                  '${round.changes.map((c) => c.id).join(', ')}.',
        isError: true,
      );
    }
    final files = {
      for (final c in changes)
        for (final f in c.files) f.path: f,
    };
    final head = [
      'Round ${round.n} of $id'
          '${change == null ? '' : ', change $change'}'
          '${round.undone.isEmpty ? '' : ' (undone: ${round.undone.join(', ')})'}:',
      for (final c in changes) '  ${c.id}: ${c.summary}',
      'Files (relative to the git top level):',
      for (final f in files.values)
        '  ${f.path}'
            '${f.added == null ? '' : ' +${f.added} -${f.removed}'}'
            '${f.shared ? ' (shared: another note changed it too)' : ''}',
    ];
    final cp = await store.checkpoints;
    if (cp == null || !round.hasCheckpoints) {
      return _text(
        '${head.join('\n')}\n'
        'No patch: this round has no git checkpoints. The files are the ones '
        'you named.',
      );
    }
    final patch = await cp.patch(
      round.start!,
      round.end!,
      paths: files.keys.toList(),
    );
    if (patch == null) {
      return _text(
        '${head.join('\n')}\nNo patch: git could not read the checkpoints.',
        isError: true,
      );
    }
    final bytes = utf8.encode(patch).length;
    if (bytes > mcpMaxDiffBytes) {
      return _text(
        '${head.join('\n')}\n'
        'The patch is ${(bytes / 1024).ceil()} KB, over the '
        '${mcpMaxDiffBytes ~/ 1024} KB limit: files only. Ask for one '
        'change at a time with change.',
      );
    }
    return _text(
      '${head.join('\n')}\n'
      'The patch goes from before to after the round. To undo it, apply it '
      'in reverse.\n\n$patch',
    );
  }

  static String _probeWarning(List<ProbeLine> probes) => [
    'Warning: ${probes.length} PinPoint.probe line'
        '${probes.length == 1 ? ' is' : 's are'} still in lib/. Remove '
        '${probes.length == 1 ? 'it' : 'them'} before the fix is done:',
    for (final p in probes.take(10)) '  ${p.file}:${p.line}',
    if (probes.length > 10) '  … and ${probes.length - 10} more',
  ].join('\n');

  /// `get_trace({run})`: a stored replay run, read with the same query as
  /// the live record. A reload cleared the app's memory; the bridge kept
  /// the run (PLAN-v2 Milestone 15, step 14).
  Future<Map<String, Object?>> _runTrace(Map<String, Object?> input) async {
    final run = input['run'];
    if (run is! String) throw const _InvalidParams('run is a run id (run_…)');
    final events = await runs.events(run);
    if (events == null) return _text('No run $run', isError: true);
    final status = await runs.status(run);
    final Map<String, Object?> answer;
    try {
      answer = traceAnswer(
        TraceRecorder.of(events),
        TraceQuery.fromArgs(input),
      );
    } on FormatException catch (error) {
      return _text(error.message, isError: true);
    }
    answer.remove('hint');
    return _resultContent({'run': run, 'state': ?status?['state'], ...answer});
  }

  /// `list_tapes`: every tape's summary, newest first. Never a body.
  Future<Map<String, Object?>> _listTapes() async {
    final list = await tapes.list();
    if (list.isEmpty) {
      return _text(
        'No tapes. Save one with save_tape, or ask the user to attach what '
        'happened to a note.',
      );
    }
    return _text(
      [
        '${list.length} tape${list.length == 1 ? '' : 's'}:',
        for (final summary in list.take(mcpMaxListed)) jsonEncode(summary),
      ].join('\n'),
    );
  }

  /// `get_tape`: one tape's summary, its marks and its inputs in short.
  /// Masked headers stay masked and no body is shown (rule 16).
  Future<Map<String, Object?>> _getTape(Map<String, Object?> input) async {
    final id = input['id'];
    if (id is! String) throw const _InvalidParams('id is required');
    final tape = await tapes.read(id);
    if (tape == null) return _text('No tape $id', isError: true);
    final summary = await tapes.summary(id);
    return _text(
      jsonEncode({
        ...?summary,
        'start': {
          'url': tape.start.url,
          'width': tape.start.width,
          'height': tape.start.height,
          'storage': tape.start.storage == null ? 'not kept' : 'kept',
        },
        'marks': [for (final m in tape.marks) m.toJson()],
        'routes': tape.routes,
        'inputs': [
          for (final i in tape.inputs.take(60))
            '${i.step} ${i.kind.substring('input.'.length)} '
                '${i.data['phase'] ?? ''}${i.widget == null ? '' : ' ${i.widget}'}'
                '${i.after.isEmpty ? '' : ' after ${i.after.length} answers'}',
          if (tape.inputs.length > 60) '… ${tape.inputs.length - 60} more',
        ],
        'requests': [
          for (final e in tape.net.take(60))
            '${e.n} ${e.method} ${e.url} → ${e.error ?? e.status ?? '-'}'
                '${e.unsupported == null ? '' : ' (passes through: '
                          '${e.unsupported})'}',
          if (tape.net.length > 60) '… ${tape.net.length - 60} more',
        ],
      }),
    );
  }

  /// `list_probes`: the `PinPoint.probe(` lines left under `lib/`.
  Future<Map<String, Object?>> _listProbes() async {
    final probes = await findProbes(store.root.parent);
    if (probes.isEmpty) return _text('No PinPoint.probe lines in lib/.');
    return _text(
      [
        '${probes.length} PinPoint.probe line'
            '${probes.length == 1 ? '' : 's'} in lib/:',
        for (final p in probes) '$p',
      ].join('\n'),
    );
  }

  /// The `hot_reload` tool: not in [agentTools], because it goes to the
  /// app's debug service, not through the command queue.
  static const Map<String, Object?> hotReloadTool = {
    'name': 'hot_reload',
    'title': 'Hot reload the app',
    'description':
        'Hot reloads the running app after you edit its code, as r in '
        'flutter run does, and says whether the new code runs: a reload '
        'that did not compile is an error. Works with agent control off. '
        'The bridge finds the app in .pinpoint/vm-service.txt (start it '
        'with flutter run --vmservice-out-file=.pinpoint/vm-service.txt); '
        'else give vm_service once per flutter run. Handles from before the '
        'reload are gone.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'vm_service': {
          'type': 'string',
          'description':
              'The address flutter run prints: "A Dart VM Service on Chrome '
              'is available at: http://127.0.0.1:…". Kept for later calls.',
        },
      },
    },
  };

  Future<Map<String, Object?>> _hotReload(Map<String, Object?> input) async {
    final address = input['vm_service'];
    final answer = await reloader!.reload(
      address: address is String ? address : null,
    );
    if (answer['ok'] != true) {
      return _text('${answer['error']}', isError: true);
    }
    final result = answer['result'];
    if (result is Map<String, Object?>) {
      _log(
        'pinpoint: the agent hot reloaded the app '
        '(${result['confirmed'] == true ? 'confirmed' : 'not confirmed'}, '
        '${result['ms']} ms)',
      );
    }
    return _text(jsonEncode(result));
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
    // A full tape restarted the page (PLAN-v2 Milestone 15, step 7). The
    // new page reports the run when it holds or ends.
    if (tool == 'replay' &&
        result is Map<String, Object?> &&
        result['state'] == 'restarting' &&
        result['run'] is String) {
      final run = result['run']! as String;
      final status = await runs.nextStatus(
        run,
        timeout: agentToolTimeout(tool, input),
      );
      if (status == null) {
        return _text(
          'The page restarted for replay $run but did not report it within '
          '${agentToolTimeout(tool, input).inSeconds} s. Is the tab shown? '
          'Read what arrived with get_trace({run: "$run"}).',
          isError: true,
        );
      }
      return _resultContent({...status});
    }
    if (tool == 'state_flow' && result is Map<String, Object?>) {
      return _text(await stateFlowText(result, source));
    }
    if (tool == 'stress_matrix' && result is Map<String, Object?>) {
      return _text(jsonEncode(await _stressThumbnails({...result})));
    }
    return _resultContent(
      result is Map<String, Object?> ? {...result} : result,
    );
  }

  /// Writes each run's thumbnail to `<dir>/stress/run_<n>.png` and puts
  /// the path in its place: nine images in the tool result would cost the
  /// agent's context, and it can open the ones it needs.
  Future<Map<String, Object?>> _stressThumbnails(
    Map<String, Object?> result,
  ) async {
    final runs = result['runs'];
    if (runs is! List<Object?>) return result;
    final folder = Directory('${store.root.path}/stress');
    // Only this matrix's images: an older one may have had more runs.
    if (folder.existsSync()) await folder.delete(recursive: true);
    await folder.create(recursive: true);
    final dir = store.root.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    result['runs'] = [
      for (final (i, run) in runs.indexed)
        if (run is Map<String, Object?>)
          await _thumbnail({...run}, folder, dir, i + 1)
        else
          run,
    ];
    return result;
  }

  Future<Map<String, Object?>> _thumbnail(
    Map<String, Object?> run,
    Directory folder,
    String dir,
    int number,
  ) async {
    final data = run.remove('png');
    if (data is! String) return run;
    try {
      final name = 'run_$number.png';
      await File('${folder.path}/$name').writeAsBytes(base64Decode(data));
      run['thumbnail'] = '$dir/stress/$name';
    } on FormatException {
      run['thumbnail'] = null;
    }
    return run;
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
