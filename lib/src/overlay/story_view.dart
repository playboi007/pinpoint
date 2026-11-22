import 'package:flutter/material.dart';

import '../core/code_line_cache.dart';
import '../sink/bridge_client.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import '../trace/story.dart';
import '../trace/story_names.dart';
import 'source_location_button.dart';
import 'state_chain.dart';

/// The keys of the story's own parts. Block, folder button and hint keys
/// are [StateChain]'s.
class StoryKeys {
  const StoryKeys._();

  /// The "Only my state" check box.
  static const Key onlyMine = ValueKey<String>('pinpoint.story.onlyMine');

  /// The line "4 hover changes hidden" and its "show" link.
  static const Key fold = ValueKey<String>('pinpoint.story.fold');
  static const Key foldShow = ValueKey<String>('pinpoint.story.fold.show');

  /// "hide hover and controller changes" after they were shown.
  static const Key foldHide = ValueKey<String>('pinpoint.story.fold.hide');

  /// The one hint at the top when changes have no cause.
  static const Key noCause = ValueKey<String>('pinpoint.story.noCause');

  /// The line for blocks the story dropped.
  static const Key dropped = ValueKey<String>('pinpoint.story.dropped');

  /// The time of block [id].
  static Key time(String id) => ValueKey<String>('pinpoint.story.$id.time');

  /// The row [index] of block [id].
  static Key row(String id, int index) =>
      ValueKey<String>('pinpoint.story.$id.row$index');

  /// The "N instances" toggle of a row, and its list.
  static Key instances(String id, int index) =>
      ValueKey<String>('pinpoint.story.$id.row$index.instances');
  static Key instanceList(String id, int index) =>
      ValueKey<String>('pinpoint.story.$id.row$index.instanceList');

  /// The rebuilt line of block [id].
  static Key rebuilt(String id) =>
      ValueKey<String>('pinpoint.story.$id.rebuilt');

  /// The end line number [index] (target left, hot reload, window ended).
  static Key end(int index) => ValueKey<String>('pinpoint.story.end$index');
}

/// The story of a watch: blocks in time order,
/// oldest first. Each block is one cause (its label and time), the rows it
/// changed (the name, the change in a few words, the method and its folder
/// button, the code line), the widgets that rebuilt, and one hint.
///
/// The State tab and the watch card both show this. It reads only [story]
/// (made by `StateLens.story`) and the caches, so it changes only when its
/// owner passes a new story. The name of a row comes from the ladder in
/// `story_names.dart`; the short type shows first and the name read from
/// the code swaps in when [cache] has it.
class StoryView extends StatefulWidget {
  const StoryView({
    super.key,
    required this.story,
    required this.filter,
    required this.onFilter,
    required this.cache,
    this.bridge,
    this.onToast,
  });

  final Story story;
  final StoryFilter filter;
  final ValueChanged<StoryFilter> onFilter;

  /// The source lines and names, asked once each for the session.
  final CodeLineCache cache;

  /// The bridge that reads source; null shows no code line and no name from
  /// the code.
  final BridgeClient? Function()? bridge;

  final ValueChanged<String>? onToast;

  @override
  State<StoryView> createState() => _StoryViewState();
}

class _StoryViewState extends State<StoryView> {
  // Rows with their instances open: `<block>.<row>`.
  final Set<String> _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    // The cache tells when lines and names arrive, and only then.
    return ListenableBuilder(
      listenable: widget.cache,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ..._header(tokens),
          ..._timeline(tokens),
          ..._footer(tokens),
        ],
      ),
    );
  }

  /// The check box, the hints, the fold line and "nothing changed".
  List<Widget> _header(PinPointTokens tokens) {
    final story = widget.story;
    final filter = widget.filter;
    final hint = story.noCauseHint;
    final hidden = hiddenLine(story);
    return [
      DraftCheckbox(
        key: StoryKeys.onlyMine,
        value: filter.onlyMine,
        label: 'Only my state',
        onChanged: (value) => widget.onFilter(filter.copyWith(onlyMine: value)),
      ),
      const SizedBox(height: 6),
      if (hint != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(hint, key: StoryKeys.noCause, style: tokens.micro),
        ),
      if (hidden != null)
        _fold(tokens, hidden, story, filter)
      else if (filter.showHover || filter.showControllers)
        _foldHide(filter),
      if (story.droppedBlocks > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '${story.droppedBlocks} earlier blocks not shown',
            key: StoryKeys.dropped,
            style: tokens.micro,
          ),
        ),
      if (!story.hasChanges)
        Text('Nothing changed yet — use the app', style: tokens.label),
    ];
  }

  Widget _foldHide(StoryFilter filter) => Align(
    alignment: Alignment.centerLeft,
    child: DraftButton.link(
      key: StoryKeys.foldHide,
      label: 'hide hover and controller changes',
      onPressed: () => widget.onFilter(
        filter.copyWith(showHover: false, showControllers: false),
      ),
    ),
  );

  List<Widget> _timeline(PinPointTokens tokens) {
    final story = widget.story;
    var endIndex = 0;
    return [
      for (final item in story.timeline)
        if (item is StoryEnd)
          _end(tokens, item, endIndex++)
        else if (item is StoryBlock)
          _block(tokens, story, item),
    ];
  }

  List<Widget> _footer(PinPointTokens tokens) => [
    if (widget.story.droppedStacks > 0)
      Text(
        '${widget.story.droppedStacks} setState stacks dropped (cap)',
        style: tokens.micro,
      ),
  ];

  Widget _fold(
    PinPointTokens tokens,
    String hidden,
    Story story,
    StoryFilter filter,
  ) => Padding(
    key: StoryKeys.fold,
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Flexible(child: Text('$hidden ·', style: tokens.label)),
        DraftButton.link(
          key: StoryKeys.foldShow,
          label: 'show',
          onPressed: () => widget.onFilter(
            filter.copyWith(
              showHover: story.hiddenHover > 0 ? true : null,
              showControllers: story.hiddenControllers > 0 ? true : null,
              onlyMine: story.hiddenForeign > 0 ? false : null,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _end(PinPointTokens tokens, StoryEnd end, int index) => Padding(
    key: StoryKeys.end(index),
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      '${formatStoryAt(end.at)}  ${end.text}',
      style: tokens.micro.copyWith(color: tokens.accentInk),
    ),
  );

  Widget _block(PinPointTokens tokens, Story story, StoryBlock block) {
    var notifyIndex = 0;
    var stateIndex = 0;
    final rows = <Widget>[];
    for (var i = 0; i < block.rows.length; i++) {
      final row = block.rows[i];
      final id =
          '${block.id}.${row.kind == 'notify' ? 'n' : 's'}'
          '${row.kind == 'notify' ? notifyIndex++ : stateIndex++}';
      rows.add(_row(tokens, block, row, i, id));
    }
    return Column(
      key: StateChain.causeKey(block.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _blockHeader(tokens, block),
        ...rows,
        if (block.droppedRows > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 6),
            child: Text(
              '+${block.droppedRows} more changes in this block',
              style: tokens.micro,
            ),
          ),
        _rebuilt(tokens, story, block),
        if (block.hint case final hint?) _blockHint(tokens, block, hint),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _blockHeader(PinPointTokens tokens, StoryBlock block) {
    final wall = block.wall;
    Widget time = Text(
      blockTime(block),
      key: StoryKeys.time(block.id),
      style: tokens.micro.copyWith(color: tokens.ink),
    );
    // The clock shows on hover.
    if (wall != null) time = Tooltip(message: formatClockMs(wall), child: time);
    return Container(
      color: tokens.field,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          time,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              causeLine(block),
              style: tokens.caps,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _blockHint(PinPointTokens tokens, StoryBlock block, String hint) =>
      Container(
        key: StateChain.hintKey(block.id),
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
        decoration: BoxDecoration(
          color: tokens.accentBg,
          border: Border(left: BorderSide(color: tokens.accent, width: 2)),
        ),
        child: Text(hint, style: tokens.body.copyWith(color: tokens.accentInk)),
      );

  Widget _row(
    PinPointTokens tokens,
    StoryBlock block,
    StoryRow row,
    int index,
    String locationId,
  ) {
    final cache = widget.cache;
    if (isFrameworkType(row.base)) {
      cache.needName(row.src, row.srcArg, widget.bridge);
    }
    cache.need(row.file, row.line, widget.bridge);
    final change = changesText(row);
    return Padding(
      key: StoryKeys.row(block.id, index),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          locatedRow(_where(row, locationId), _rowTitle(tokens, row)),
          if (change.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                change,
                style: tokens.value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (row.instances.isNotEmpty)
            _instances(tokens, block, row, index, '${block.id}.$index'),
          _codeBox(tokens, row.file, row.line),
        ],
      ),
    );
  }

  Widget? _where(StoryRow row, String locationId) {
    final file = row.file;
    if (file == null || file.isEmpty) return null;
    return SourceLocationButton(
      key: StateChain.locationKey(locationId),
      path: shortSourcePath(whereLabel(file, null)),
      line: row.line != null && row.line! > 0 ? row.line : null,
      onToast: widget.onToast,
      tipKey: StateChain.locationTipKey,
      popoverKey: StateChain.locationPopoverKey,
      copyKey: StateChain.locationCopyKey,
    );
  }

  Widget _rowTitle(PinPointTokens tokens, StoryRow row) {
    final name = storyName(
      row,
      expression: widget.cache.nameAt(row.src, row.srcArg),
    );
    final method = storyMethod(row.method);
    final muted = tokens.value.copyWith(color: tokens.muted, fontSize: 11);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: row.kind == 'setState' ? row.owner : name.text,
            style: tokens.value.copyWith(fontWeight: FontWeight.w500),
          ),
          if (row.kind == 'setState')
            const TextSpan(text: ' setState')
          else if (name.rung == 2)
            TextSpan(text: ' (${shortType(row.owner)})', style: muted),
          if (row.verb != null) TextSpan(text: ' ${verbText(row)}'),
          if (row.count > 1) TextSpan(text: ' ×${row.count}', style: muted),
          if (row.afterMs != null)
            TextSpan(text: ' ${formatAfterMs(row.afterMs!)}', style: muted),
          if (method.isNotEmpty) TextSpan(text: '  $method', style: muted),
        ],
      ),
      style: tokens.label,
    );
  }

  Widget _instances(
    PinPointTokens tokens,
    StoryBlock block,
    StoryRow row,
    int index,
    String openId,
  ) {
    final isOpen = _open.contains(openId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: DraftButton.link(
            key: StoryKeys.instances(block.id, index),
            label: '${row.instanceCount} instances ${isOpen ? '▾' : '▸'}',
            onPressed: () => setState(() {
              if (!_open.remove(openId)) _open.add(openId);
            }),
          ),
        ),
        if (isOpen)
          Padding(
            key: StoryKeys.instanceList(block.id, index),
            padding: const EdgeInsets.only(left: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final instance in row.instances)
                  Text(
                    instance.change == null
                        ? instance.label
                        : '${instance.label}  ${instance.change}',
                    style: tokens.value.copyWith(fontSize: 11),
                  ),
                if (row.instanceCount > row.instances.length)
                  Text(
                    '+${row.instanceCount - row.instances.length} more',
                    style: tokens.micro,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rebuilt(PinPointTokens tokens, Story story, StoryBlock block) {
    if (block.rebuilt.isEmpty) {
      // "Nothing rebuilt" is a fact about a notify. A setState rebuilds its
      // own widget, so the line would say nothing there.
      if (!story.rebuildsRecorded ||
          !block.rows.any((r) => r.kind == 'notify')) {
        return const SizedBox.shrink();
      }
      return Padding(
        key: StoryKeys.rebuilt(block.id),
        padding: const EdgeInsets.only(top: 6),
        child: Text('No rebuilt widget seen for it', style: tokens.label),
      );
    }
    final more = block.rebuiltCount - block.rebuilt.length;
    return Padding(
      key: StoryKeys.rebuilt(block.id),
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'Rebuilt ${block.rebuiltCount}: ',
              style: tokens.label,
            ),
            TextSpan(
              text: block.rebuilt.join(', '),
              style: tokens.value.copyWith(fontSize: 11),
            ),
            if (more > 0) TextSpan(text: ' +$more more', style: tokens.micro),
          ],
        ),
      ),
    );
  }

  Widget _codeBox(PinPointTokens tokens, Object? file, Object? line) {
    final lines = widget.cache.linesAt(file, line);
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
}
