import 'package:flutter/material.dart';

import '../core/code_line_cache.dart';
import '../sink/bridge_client.dart';
import '../theme/pinpoint_tokens.dart';
import 'source_location_button.dart';

/// The keys of the chain rows. The State tab and the watch card show the
/// same rows, so they share these ([StateTab] repeats them for its tests).
class StateChain {
  const StateChain._();

  /// The folder button of one row that has a source location. [id] is
  /// `r<n>` for a reader, `r<n>.d<m>` for one of its objects, and
  /// `<cause>.n<m>` or `<cause>.s<m>` for a notify or setState row of a
  /// cause block.
  static Key locationKey(String id) =>
      ValueKey<String>('pinpoint.stateTab.where.$id');

  /// The tip that the folder button shows after 2 s of hover.
  static const Key locationTipKey = ValueKey<String>(
    'pinpoint.stateTab.where.tip',
  );

  /// The popover of the folder button: short path and line.
  static const Key locationPopoverKey = ValueKey<String>(
    'pinpoint.stateTab.where.popover',
  );

  /// The Copy button of that popover.
  static const Key locationCopyKey = ValueKey<String>(
    'pinpoint.stateTab.where.copy',
  );

  /// One cause block: [id] is `c<cause>`, or `f<frame>` for a change with
  /// no cause.
  static Key causeKey(String id) => ValueKey<String>('pinpoint.stateTab.$id');

  /// The coupling hint of one cause block.
  static Key hintKey(String id) =>
      ValueKey<String>('pinpoint.stateTab.$id.hint');

  /// The causes of [chain] (a `StateLens.chain()` answer), newest first.
  static List<Map<String, Object?>> causesOf(Map<String, Object?> chain) => [
    for (final c in asList(chain['causes']))
      if (c is Map<String, Object?>) c,
  ].reversed.toList();
}

/// The chain per cause, newest first: what notified (owner, tag, method, a
/// folder button for file:line), the code line from the bridge when there is
/// one, the values before and after, the readers that rebuilt, and the
/// coupling hint. All of it comes from [chain], the answer of
/// `StateLens.chain()`; this widget reads nothing else, so what it shows
/// changes only when its owner passes a new map.
///
/// Used by the State tab (inside its "Changes" section) and by the watch
/// card, so both show the same rows.
class StateChainView extends StatelessWidget {
  const StateChainView({
    super.key,
    required this.chain,
    required this.cache,
    this.bridge,
    this.onToast,
  });

  final Map<String, Object?> chain;

  /// The source lines, asked once per `file:line` for the session.
  final CodeLineCache cache;

  /// The bridge that reads source lines; null, or one that answers null,
  /// shows no code line.
  final BridgeClient? Function()? bridge;

  /// Shows a toast for the folder button's Copy.
  final ValueChanged<String>? onToast;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final causes = StateChain.causesOf(chain);
    final dropped = chain['dropped'];
    // The cache tells when lines arrive, and only then.
    return ListenableBuilder(
      listenable: cache,
      builder: (context, _) {
        final children = <Widget>[];
        if (causes.isEmpty) {
          children.add(
            Text('Nothing changed yet — use the app', style: tokens.label),
          );
        }
        for (final cause in causes) {
          for (final key in const ['notifies', 'setStates']) {
            for (final row in asList(cause[key])) {
              if (row is! Map<String, Object?>) continue;
              cache.need(row['file'], row['line'], bridge);
            }
          }
          children.add(_cause(tokens, cause));
        }
        if (dropped is int && dropped > 0) {
          children.add(
            Text('$dropped setState stacks dropped (cap)', style: tokens.micro),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      },
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
      for (final n in asList(cause['notifies']))
        if (n is Map<String, Object?>) n,
    ];
    final setStates = [
      for (final s in asList(cause['setStates']))
        if (s is Map<String, Object?>) s,
    ];
    final rebuilt = [
      for (final r in asList(cause['rebuilt']))
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
      key: StateChain.causeKey(idText),
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
        for (var i = 0; i < notifies.length; i++)
          _notify(tokens, notifies[i], '$idText.n$i'),
        if (cause['moreNotifies'] is int)
          _note(tokens, '+${cause['moreNotifies']} more notifies'),
        for (var i = 0; i < setStates.length; i++)
          _setState(tokens, setStates[i], '$idText.s$i'),
        if (cause['moreSetStates'] is int)
          _note(tokens, '+${cause['moreSetStates']} more setStates'),
        // "No rebuilt reader" is a fact about a notify (it should have
        // rebuilt something). A setState rebuilds its own widget, so the
        // line would say nothing there.
        _rebuilt(
          tokens,
          rebuilt,
          sharedTags,
          cause['moreRebuilt'],
          hasNotify: notifies.isNotEmpty,
        ),
        if (hint is String)
          Container(
            key: StateChain.hintKey(idText),
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

  /// The folder button of a chain row, or null when the frame has no file.
  Widget? _whereButton(String id, Object? file, Object? line) {
    if (file is! String || file.isEmpty) return null;
    return SourceLocationButton(
      key: StateChain.locationKey(id),
      path: shortSourcePath(whereLabel(file, null)),
      line: line is int && line > 0 ? line : null,
      onToast: onToast,
      tipKey: StateChain.locationTipKey,
      popoverKey: StateChain.locationPopoverKey,
      copyKey: StateChain.locationCopyKey,
    );
  }

  Widget _note(PinPointTokens tokens, String text) => Padding(
    padding: const EdgeInsets.only(top: 2, left: 6),
    child: Text(text, style: tokens.micro),
  );

  Widget _notify(PinPointTokens tokens, Map<String, Object?> n, String id) {
    final method = methodLabel(n['method']);
    final where = _whereButton(id, n['file'], n['line']);
    final nested = n['depth'] is int && (n['depth']! as int) > 1;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          locatedRow(
            where,
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
          ),
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

  Widget _setState(PinPointTokens tokens, Map<String, Object?> s, String id) {
    final method = methodLabel(s['method']);
    final where = _whereButton(id, s['file'], s['line']);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          locatedRow(
            where,
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
          ),
          _codeBox(tokens, s['file'], s['line']),
        ],
      ),
    );
  }

  Widget _codeBox(PinPointTokens tokens, Object? file, Object? line) {
    final lines = cache.linesAt(file, line);
    if (lines == null) return const SizedBox.shrink();
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
    Object? more, {
    required bool hasNotify,
  }) {
    if (rebuilt.isEmpty) {
      if (!hasNotify) return const SizedBox.shrink();
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

/// [text] with the folder button [where] at the end of its row, if any.
Widget locatedRow(Widget? where, Widget text) {
  if (where == null) return text;
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(child: text),
      const SizedBox(width: 4),
      where,
    ],
  );
}

/// [value] as a list, or an empty one.
List<Object?> asList(Object? value) =>
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
