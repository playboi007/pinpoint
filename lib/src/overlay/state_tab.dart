import 'dart:async';

import 'package:flutter/material.dart';

import '../model/source_location.dart';
import '../search/pick_result.dart';
import '../sink/bridge_client.dart';
import '../state/dependencies.dart';
import '../state/state_lens.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import '../trace/code_lines.dart';
import '../trace/trace_session.dart';
import 'panel_parts.dart';

/// The State tab of the Info panel (PLAN-v3 Milestone 21, step 7).
///
/// Three parts:
/// 1. What the picked widget reads: its state owners and the objects they
///    depend on, with identity tags. Cheap, so it shows with no arming.
/// 2. "Watch state" arms the [StateLens] on the picked element for one
///    window. While it runs the tab shows one static line with the end
///    time, never a countdown: the lens publishes only after frames with
///    real rebuilds, and Pinpoint must not draw frames on a timer (an agent
///    waits until the app stops drawing).
/// 3. The chain per cause, newest first: what notified (owner, tag, method,
///    file:line), the code line from the bridge when there is one, the
///    values before and after, the readers that rebuilt, and the coupling
///    hint. All of it comes from [StateLens.chain] (`state_flow.dart`).
class StateTab extends StatefulWidget {
  const StateTab({
    super.key,
    required this.selection,
    required this.session,
    this.bridge,
  });

  /// The "Watch state" button.
  static const Key watchKey = ValueKey<String>('pinpoint.stateTab.watch');

  /// The "Stop" button, shown while a window is open.
  static const Key stopKey = ValueKey<String>('pinpoint.stateTab.stop');

  /// "Watching until HH:MM:SS".
  static const Key watchingKey = ValueKey<String>('pinpoint.stateTab.watching');

  /// "Stopped:" and the reason.
  static const Key stoppedKey = ValueKey<String>('pinpoint.stateTab.stopped');

  /// The section that lists what the widget reads.
  static const Key readsKey = ValueKey<String>('pinpoint.stateTab.reads');

  /// The section that lists the causes.
  static const Key chainKey = ValueKey<String>('pinpoint.stateTab.chain');

  /// One cause block: [id] is `c<cause>`, or `f<frame>` for a change with
  /// no cause.
  static Key causeKey(String id) => ValueKey<String>('pinpoint.stateTab.$id');

  /// The coupling hint of one cause block.
  static Key hintKey(String id) =>
      ValueKey<String>('pinpoint.stateTab.$id.hint');

  final PickResult selection;

  /// The flight recorder's session; null while the recorder is off.
  final TraceSession? session;

  /// The bridge that reads source lines for the chain; null, or one that
  /// returns null, shows no code line.
  final BridgeClient? Function()? bridge;

  @override
  State<StateTab> createState() => _StateTabState();
}

class _StateTabState extends State<StateTab> {
  StateLens? _lens;

  /// The code lines per `file:line`, null for "the bridge has none". A key
  /// that is absent was not asked yet.
  final Map<String, List<String>?> _code = <String, List<String>?>{};
  final Set<String> _asked = <String>{};

  /// When the open window ends, fixed when the tab first sees it armed.
  DateTime? _until;

  // The readers are read again only when the element or the lens changes.
  Element? _readersOf;
  StateLensState? _readersAt;
  List<ReaderRef> _readers = const <ReaderRef>[];

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(StateTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) _follow();
  }

  @override
  void dispose() {
    _lens?.removeListener(_onLens);
    super.dispose();
  }

  void _follow() {
    _lens?.removeListener(_onLens);
    _lens = widget.session?.stateLens;
    _lens?.addListener(_onLens);
  }

  // After a frame with real rebuilds, and when a window opens or ends.
  void _onLens() {
    if (mounted) setState(() {});
  }

  void _arm(StateLens lens) {
    final element = widget.selection.element;
    if (!element.mounted) return;
    lens.arm(element);
    _until = DateTime.now().add(lens.value.window);
  }

  List<ReaderRef> _readersFor(StateLens lens, Element element) {
    final at = lens.value;
    if (identical(_readersOf, element) && identical(_readersAt, at)) {
      return _readers;
    }
    _readersOf = element;
    _readersAt = at;
    try {
      _readers = nearestReaders(
        element,
        lens.resolver,
        boundary: lens.content(),
        tags: lens.tags,
      );
    } catch (_) {
      // Diagnostics run code written by widget authors.
      _readers = const <ReaderRef>[];
    }
    return _readers;
  }

  /// Asks the bridge for the lines around [file]:[line], once.
  void _need(Object? file, Object? line) {
    if (file is! String || line is! int || line < 1) return;
    final key = '$file:$line';
    if (_asked.contains(key)) return;
    final client = widget.bridge?.call();
    if (client == null) return;
    _asked.add(key);
    unawaited(_fetch(key, client, file, line));
  }

  Future<void> _fetch(
    String key,
    BridgeClient client,
    String file,
    int line,
  ) async {
    List<String>? lines;
    try {
      final snippet = await client.source(file, line);
      if (snippet != null) {
        lines = codeLinesAt(snippet.text, snippet.start, line);
      }
    } catch (_) {
      lines = null;
    }
    if (!mounted) return;
    // One more frame, and only when there is something new to show.
    if (lines == null || lines.isEmpty) {
      _code[key] = null;
      return;
    }
    setState(() => _code[key] = lines);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final lens = _lens;
    if (lens == null) {
      return Text(
        'The state lens needs the flight recorder, and it is off.',
        style: tokens.label,
      );
    }
    final element = widget.selection.element;
    final value = lens.value;
    final mine = identical(value.target, element);
    final armedHere = mine && value.armed;
    if (armedHere) {
      _until ??= DateTime.now().add(Duration(seconds: lens.secondsLeft));
    } else {
      _until = null;
    }
    final readers = _readersFor(lens, element);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Reads(key: StateTab.readsKey, readers: readers, lens: lens),
        const SizedBox(height: PinPointSizes.sectionGap),
        _watch(tokens, lens, value, mine: mine, armedHere: armedHere),
        if (mine) ...[
          const SizedBox(height: PinPointSizes.sectionGap),
          _chain(tokens, lens),
        ],
      ],
    );
  }

  Widget _watch(
    PinPointTokens tokens,
    StateLens lens,
    StateLensState value, {
    required bool mine,
    required bool armedHere,
  }) {
    final until = _until;
    final String? status;
    Key? statusKey;
    if (armedHere && until != null) {
      status = 'Watching until ${formatClock(until)}';
      statusKey = StateTab.watchingKey;
    } else if (mine && value.endedBecause != null) {
      status = 'Stopped: ${value.endedBecause}';
      statusKey = StateTab.stoppedKey;
    } else if (value.armed) {
      status =
          'Watching ${value.targetType ?? 'another widget'} now. '
          'Watch state here moves it.';
    } else {
      status = null;
    }
    return PanelSection(
      heading: sectionHeading(2, 'Watch'),
      children: [
        Row(
          children: [
            if (armedHere)
              DraftButton.outline(
                key: StateTab.stopKey,
                label: 'Stop',
                onPressed: lens.stop,
              )
            else
              DraftButton.primary(
                key: StateTab.watchKey,
                label: 'Watch state',
                onPressed: () => _arm(lens),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status ?? 'Records what changes it for 30 s.',
                key: statusKey,
                style: tokens.label,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chain(PinPointTokens tokens, StateLens lens) {
    final Map<String, Object?> chain;
    try {
      chain = lens.chain();
    } catch (_) {
      return const SizedBox.shrink();
    }
    final causes = [
      for (final c in _list(chain['causes']))
        if (c is Map<String, Object?>) c,
    ].reversed.toList();
    final dropped = chain['dropped'];
    final children = <Widget>[];
    if (causes.isEmpty) {
      children.add(
        Text('Nothing changed yet — use the app', style: tokens.label),
      );
    }
    for (final cause in causes) {
      for (final n in _list(cause['notifies'])) {
        if (n is Map<String, Object?>) _need(n['file'], n['line']);
      }
      for (final s in _list(cause['setStates'])) {
        if (s is Map<String, Object?>) _need(s['file'], s['line']);
      }
      children.add(_cause(tokens, cause));
    }
    if (dropped is int && dropped > 0) {
      children.add(
        Text('$dropped setState stacks dropped (cap)', style: tokens.micro),
      );
    }
    return PanelSection(
      key: StateTab.chainKey,
      heading: sectionHeading(3, 'Changes'),
      detail: causes.isEmpty ? null : '${chain['events']} events',
      children: children,
    );
  }

  Widget _cause(PinPointTokens tokens, Map<String, Object?> cause) {
    final id = cause['cause'];
    final frame = cause['frame'];
    final entry = cause['entry'];
    final idText = id is int ? 'c$id' : 'f$frame';
    final title = id is int
        ? (entry is String ? entry : '${cause['kind'] ?? 'a change'}')
        : 'a change in frame f$frame';
    final notifies = [
      for (final n in _list(cause['notifies']))
        if (n is Map<String, Object?>) n,
    ];
    final setStates = [
      for (final s in _list(cause['setStates']))
        if (s is Map<String, Object?>) s,
    ];
    final rebuilt = [
      for (final r in _list(cause['rebuilt']))
        if (r is Map<String, Object?>) r,
    ];
    final hint = cause['hint'];
    final sharedTags = <String, Set<Object?>>{};
    for (final r in rebuilt) {
      final tag = r['tag'];
      if (tag is String && r['via'] != 'setState') {
        sharedTags.putIfAbsent(tag, () => <Object?>{}).add(r['type']);
      }
    }
    return Column(
      key: StateTab.causeKey(idText),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: tokens.field,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text(
            '$idText  $title',
            style: tokens.caps,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final n in notifies) _notify(tokens, n),
        if (cause['moreNotifies'] is int)
          _note(tokens, '+${cause['moreNotifies']} more notifies'),
        for (final s in setStates) _setState(tokens, s),
        if (cause['moreSetStates'] is int)
          _note(tokens, '+${cause['moreSetStates']} more setStates'),
        _rebuilt(tokens, rebuilt, sharedTags, cause['moreRebuilt']),
        if (hint is String)
          Container(
            key: StateTab.hintKey(idText),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
            decoration: BoxDecoration(
              color: tokens.accentBg,
              border: Border(left: BorderSide(color: tokens.accent, width: 2)),
            ),
            child: Text(
              hint,
              style: tokens.body.copyWith(color: tokens.accentInk),
            ),
          ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _note(PinPointTokens tokens, String text) => Padding(
    padding: const EdgeInsets.only(top: 2, left: 6),
    child: Text(text, style: tokens.micro),
  );

  Widget _notify(PinPointTokens tokens, Map<String, Object?> n) {
    final method = methodLabel(n['method']);
    final where = whereLabel(n['file'], n['line']);
    final nested = n['depth'] is int && (n['depth']! as int) > 1;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${n['owner'] ?? '?'}',
                  style: tokens.value.copyWith(fontWeight: FontWeight.w500),
                ),
                if (n['tag'] is String)
                  TextSpan(
                    text: ' ${n['tag']}',
                    style: tokens.value.copyWith(color: tokens.accentInk),
                  ),
                const TextSpan(text: ' notified'),
                if (method.isNotEmpty) TextSpan(text: '  $method'),
                if (nested) const TextSpan(text: '  (inside another notify)'),
              ],
            ),
            style: tokens.label,
          ),
          if (where.isNotEmpty)
            Text(where, style: tokens.micro, softWrap: true),
          if (n.containsKey('after'))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${n['before']} → ${n['after']}',
                style: tokens.value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _codeBox(tokens, n['file'], n['line']),
        ],
      ),
    );
  }

  Widget _setState(PinPointTokens tokens, Map<String, Object?> s) {
    final method = methodLabel(s['method']);
    final where = whereLabel(s['file'], s['line']);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${s['widget'] ?? '?'}',
                  style: tokens.value.copyWith(fontWeight: FontWeight.w500),
                ),
                const TextSpan(text: ' setState'),
                if (method.isNotEmpty) TextSpan(text: '  $method'),
              ],
            ),
            style: tokens.label,
          ),
          if (where.isNotEmpty) Text(where, style: tokens.micro),
          _codeBox(tokens, s['file'], s['line']),
        ],
      ),
    );
  }

  Widget _codeBox(PinPointTokens tokens, Object? file, Object? line) {
    final lines = _code['$file:$line'];
    if (lines == null || lines.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: tokens.input,
        border: Border.all(color: tokens.rule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final text in lines)
            Text(
              text,
              style: tokens.value.copyWith(fontSize: 11),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _rebuilt(
    PinPointTokens tokens,
    List<Map<String, Object?>> rebuilt,
    Map<String, Set<Object?>> sharedTags,
    Object? more,
  ) {
    if (rebuilt.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('No rebuilt reader seen for it', style: tokens.label),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Rebuilt because they read it', style: tokens.label),
          for (final r in rebuilt)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${r['type']}'),
                    ..._why(tokens, r, sharedTags),
                  ],
                ),
                style: tokens.value,
              ),
            ),
          if (more is int) _note(tokens, '+$more more'),
        ],
      ),
    );
  }

  List<InlineSpan> _why(
    PinPointTokens tokens,
    Map<String, Object?> r,
    Map<String, Set<Object?>> sharedTags,
  ) {
    final tag = r['tag'];
    final muted = tokens.value.copyWith(color: tokens.muted, fontSize: 11);
    final shared = tag is String && (sharedTags[tag]?.length ?? 0) > 1;
    switch (r['via']) {
      case 'dependency' || 'builder':
        return [
          TextSpan(
            text: r['via'] == 'builder' ? '  listens to ' : '  reads ',
            style: muted,
          ),
          TextSpan(
            text: '${r['owner'] ?? ''} ${tag ?? ''}'.trim(),
            style: tokens.value.copyWith(color: tokens.accentInk, fontSize: 11),
          ),
          if (shared) TextSpan(text: '  same object', style: muted),
        ];
      default:
        return [TextSpan(text: '  its own setState', style: muted)];
    }
  }
}

/// The first part of the tab: what the widget reads.
class _Reads extends StatelessWidget {
  const _Reads({super.key, required this.readers, required this.lens});

  final List<ReaderRef> readers;
  final StateLens lens;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final paths = lens.resolver.paths;
    String where(SourceLocation? location) => location == null
        ? ''
        : '${paths.relativePath(location.uri)}:${location.line}';
    return PanelSection(
      heading: sectionHeading(1, 'Reads'),
      first: true,
      children: [
        if (readers.isEmpty)
          Text('No state read here', style: tokens.label)
        else
          for (final reader in readers) ...[
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: reader.type,
                    style: tokens.value.copyWith(fontWeight: FontWeight.w500),
                  ),
                  if (where(reader.location).isNotEmpty)
                    TextSpan(
                      text: '  ${where(reader.location)}',
                      style: tokens.micro,
                    ),
                ],
              ),
            ),
            if (reader.dependencies.isEmpty)
              Text('no state object read', style: tokens.micro)
            else
              for (final d in reader.dependencies)
                PanelRow(
                  name: d.kind,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: d.type),
                        TextSpan(
                          text: ' ${d.tag}',
                          style: tokens.value.copyWith(
                            color: tokens.accentInk,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (where(d.location).isNotEmpty)
                          TextSpan(
                            text: '  ${where(d.location)}',
                            style: tokens.micro,
                          ),
                      ],
                    ),
                    style: tokens.value,
                  ),
                ),
          ],
      ],
    );
  }
}

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

/// `HH:MM:SS` of [time] in the local zone.
String formatClock(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// `Class.method` as `method()`; a top-level function keeps its name.
String methodLabel(Object? method) {
  if (method is! String || method.isEmpty) return '';
  final dot = method.lastIndexOf('.');
  final name = dot < 0 ? method : method.substring(dot + 1);
  return name.isEmpty ? '' : '$name()';
}

/// `lib/x.dart:88` for a frame's file and line; a `package:app/x.dart` file
/// shows as `lib/x.dart`. Empty when there is no file.
String whereLabel(Object? file, Object? line) {
  if (file is! String || file.isEmpty) return '';
  var shown = file;
  if (shown.startsWith('package:')) {
    final slash = shown.indexOf('/');
    shown = slash < 0 ? shown : 'lib/${shown.substring(slash + 1)}';
  }
  return line is int && line > 0 ? '$shown:$line' : shown;
}
