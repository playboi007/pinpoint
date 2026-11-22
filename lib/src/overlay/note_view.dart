import 'package:flutter/material.dart';

import '../model/annotation.dart';
import '../model/note_round.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';
import 'pin_marker.dart';

/// What the buttons of a [NoteView] do, each given the note's id.
class NoteActions {
  const NoteActions({
    required this.send,
    required this.sendAll,
    required this.delete,
    required this.accept,
    required this.reopen,
    required this.edit,
    required this.undo,
    this.replay,
  });

  /// Plays the note's tape. Null: no Replay button.
  final ValueChanged<String>? replay;

  /// Submits a draft to every sink.
  final ValueChanged<String> send;

  /// Submits every draft.
  final VoidCallback sendAll;

  final ValueChanged<String> delete;

  /// The user accepts the agent's result: the note becomes verified and
  /// its pin goes away.
  final ValueChanged<String> accept;

  /// Back to submitted, for the agent to look at again, with the user's
  /// reason (null when none was typed).
  final void Function(String id, String? reason) reopen;

  /// The draft's comment was edited.
  final void Function(String id, String comment) edit;

  /// Undoes [changes] (ids like `c1`, or `['*']` for all) of round [round]
  /// of the note, with the user's reason (null when none was typed).
  final void Function(
    String id,
    int round,
    List<String> changes,
    String? reason,
  )
  undo;
}

/// A pinned note in the info panel: its status, comment and the agent's
/// replies, with the actions its status allows.
class NoteView extends StatefulWidget {
  const NoteView({
    super.key,
    required this.note,
    required this.number,
    required this.drafts,
    required this.focusNode,
    required this.actions,
  });

  static const Key statusKey = ValueKey<String>('pinpoint.note.status');
  static const Key fieldKey = ValueKey<String>('pinpoint.note.field');
  static const Key sendKey = ValueKey<String>('pinpoint.note.send');
  static const Key sendAllKey = ValueKey<String>('pinpoint.note.sendAll');
  static const Key deleteKey = ValueKey<String>('pinpoint.note.delete');
  static const Key acceptKey = ValueKey<String>('pinpoint.note.accept');
  static const Key reopenKey = ValueKey<String>('pinpoint.note.reopen');
  static const Key replayKey = ValueKey<String>('pinpoint.note.replay');

  /// "What is still wrong?": sent with Reopen and with Undo.
  static const Key reasonKey = ValueKey<String>('pinpoint.note.reason');

  /// The `Changes · N` button at the top right of the header.
  static const Key changesKey = ValueKey<String>('pinpoint.note.changes');

  /// The section the button opens.
  static const Key changesSectionKey = ValueKey<String>(
    'pinpoint.note.changesSection',
  );
  static const Key undoSelectedKey = ValueKey<String>(
    'pinpoint.note.undoSelected',
  );
  static const Key undoAllKey = ValueKey<String>('pinpoint.note.undoAll');

  /// The checkbox of change [id].
  static Key changeKey(String id) =>
      ValueKey<String>('pinpoint.note.change.$id');

  /// The cell of round [n] in the round picker.
  static Key roundKey(int n) => ValueKey<String>('pinpoint.note.round.$n');

  /// The latest round the agent closed, or null. Only a closed round can
  /// be undone (the bridge refuses an open one).
  static NoteRound? latestClosedRound(Annotation note) =>
      closedRounds(note).lastOrNull;

  /// The closed rounds of [note], oldest first.
  static List<NoteRound> closedRounds(Annotation note) => [
    for (final r in note.roundViews)
      if (!r.isOpen) r,
  ];

  /// Whether the `Changes` button shows: the agent is not working, the
  /// note is not a draft, and the latest closed round has changes.
  static bool canUndo(Annotation note) {
    final status = note.status;
    if (status == NoteStatus.draft ||
        status == NoteStatus.submitted ||
        status == NoteStatus.inProgress) {
      return false;
    }
    return latestClosedRound(note)?.changes.isNotEmpty ?? false;
  }

  /// Whether the user can accept [note]: the agent says it is done, or it
  /// worked the note at least once. The user decides what is done: after a
  /// reopen an agent may fix the code from the chat and never set the note
  /// fixed, and the note must not be stuck.
  static bool canAccept(Annotation note) =>
      PinMarker.showsMark(note.status) || acceptsAnyway(note);

  /// Whether [note] can be accepted although the agent has not marked it
  /// done: sent or in progress, with a reply from the agent.
  static bool acceptsAnyway(Annotation note) =>
      (note.status == NoteStatus.submitted ||
          note.status == NoteStatus.inProgress) &&
      note.messages.any((m) => m.from == 'agent');

  static const Key verificationKey = ValueKey<String>(
    'pinpoint.note.verification',
  );

  final Annotation note;

  /// The pin's number, or null when it shows no pin.
  final int? number;

  /// How many drafts there are, this one included.
  final int drafts;

  /// The draft field's focus: the same node as the comment field, so keys
  /// and focus work the same way.
  final FocusNode focusNode;

  final NoteActions actions;

  @override
  State<NoteView> createState() => _NoteViewState();
}

class _NoteViewState extends State<NoteView> {
  late final TextEditingController _text = TextEditingController(
    text: widget.note.comment,
  );

  /// Why the user reopens the note, or undoes some of the agent's work.
  final TextEditingController _reason = TextEditingController();

  /// Whether the changes section is open.
  bool _changesOpen = false;

  /// The round the section shows; null: the latest closed one.
  int? _round;

  /// The ticked changes of the shown round.
  final Set<String> _ticked = <String>{};

  @override
  void didUpdateWidget(NoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another note opened: show its text. The same note changed (an edit,
    // a status from the agent): keep what is being typed.
    if (oldWidget.note.id != widget.note.id) {
      _text.text = widget.note.comment;
      _reason.clear();
      _closeChanges();
    } else if (!NoteView.canUndo(widget.note)) {
      // The agent works again (or the note is gone from the fixed state):
      // the section would be about old work.
      _closeChanges();
    }
  }

  void _closeChanges() {
    _changesOpen = false;
    _round = null;
    _ticked.clear();
  }

  /// The round the section shows.
  NoteRound? get _shownRound {
    final rounds = NoteView.closedRounds(widget.note);
    for (final r in rounds) {
      if (r.n == _round) return r;
    }
    return rounds.lastOrNull;
  }

  /// Undoes the ticked changes (or all, with [all]) of the shown round.
  void _undo({required bool all}) {
    final round = _shownRound;
    if (round == null) return;
    final ids = all
        ? const ['*']
        : [
            for (final c in round.changes)
              if (_ticked.contains(c.id) && !round.isUndone(c.id)) c.id,
          ];
    if (ids.isEmpty) return;
    final reason = _reason.text.trim();
    _reason.clear();
    setState(_closeChanges);
    widget.actions.undo(
      widget.note.id,
      round.n,
      ids,
      reason.isEmpty ? null : reason,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _reopen() {
    final reason = _reason.text.trim();
    _reason.clear();
    widget.actions.reopen(widget.note.id, reason.isEmpty ? null : reason);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final note = widget.note;
    // The body scrolls; the reason field and the buttons stay in a footer
    // under it, so many replies cannot push Accept and Reopen out of view.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(PinPointSizes.panelPadding),
            child: _body(tokens, note, widget.number),
          ),
        ),
        _footer(tokens, note),
      ],
    );
  }

  Widget _body(PinPointTokens tokens, Annotation note, int? number) {
    final status = note.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(tokens, note, number),
        _changesSection(tokens, note),
        const SizedBox(height: 12),
        _comment(tokens, note),
        ..._replies(tokens, note),
        if (note.verification case final verification?)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _Verification(
              key: NoteView.verificationKey,
              verification: verification,
            ),
          ),
        if (status == NoteStatus.resolved || status == NoteStatus.fixed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Check the change, then accept it or reopen the note.',
              style: tokens.label,
            ),
          ),
      ],
    );
  }

  Widget _header(PinPointTokens tokens, Annotation note, int? number) {
    final status = note.status;
    return Row(
      children: [
        _StatusGlyph(status),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            key: NoteView.statusKey,
            '${number == null ? 'NOTE' : 'NOTE $number'}'
            ' · ${PinMarker.label(status).toUpperCase()}'
            ' · ${note.intent.name.toUpperCase()}',
            style: tokens.caps.copyWith(color: tokens.ink),
          ),
        ),
        if (NoteView.canUndo(note)) ...[
          const SizedBox(width: 8),
          DraftButton.link(
            key: NoteView.changesKey,
            label:
                'Changes · ${NoteView.latestClosedRound(note)!.changes.length}',
            onPressed: () => setState(() {
              _changesOpen = !_changesOpen;
              if (!_changesOpen) _ticked.clear();
            }),
          ),
        ],
      ],
    );
  }

  Widget _comment(PinPointTokens tokens, Annotation note) {
    if (note.status != NoteStatus.draft) {
      return SelectableText(note.comment, style: tokens.body);
    }
    return TextField(
      key: NoteView.fieldKey,
      controller: _text,
      focusNode: widget.focusNode,
      minLines: 3,
      maxLines: 8,
      keyboardType: TextInputType.multiline,
      onChanged: (value) => widget.actions.edit(note.id, value),
      onTapOutside: (_) {},
      decoration: const InputDecoration(contentPadding: EdgeInsets.all(8)),
    );
  }

  List<Widget> _replies(PinPointTokens tokens, Annotation note) {
    if (note.messages.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      const CapsText('REPLIES'),
      const SizedBox(height: 6),
      for (final message in note.messages)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.rule)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message.from, style: tokens.micro),
              const SizedBox(height: 2),
              Text(message.text, style: tokens.body),
            ],
          ),
        ),
    ];
  }

  /// The section under the header: the shown round, a checkbox for each
  /// change, and the undo buttons. It grows in and out; with reduced motion
  /// it does not, because `AnimatedSize` with a zero duration asserts.
  Widget _changesSection(PinPointTokens tokens, Annotation note) {
    final round = _shownRound;
    final open = _changesOpen && round != null && NoteView.canUndo(note);
    final content = open
        ? Padding(
            key: NoteView.changesSectionKey,
            padding: const EdgeInsets.only(top: 12),
            child: _changes(tokens, note, round),
          )
        : const SizedBox(key: ValueKey<String>('none'), width: double.infinity);
    final motion = PinPointMotion.of(context);
    if (motion.reduced) {
      return Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: content,
      );
    }
    return AnimatedSize(
      duration: motion.moderate,
      curve: PinPointMotion.enter,
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  Widget _changes(PinPointTokens tokens, Annotation note, NoteRound round) =>
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: tokens.rule)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _changesHeader(tokens, NoteView.closedRounds(note), round),
            for (final change in round.changes) _changeRow(change, round),
            const SizedBox(height: 8),
            _undoButtons(round),
          ],
        ),
      );

  Widget _changesHeader(
    PinPointTokens tokens,
    List<NoteRound> rounds,
    NoteRound round,
  ) => Row(
    children: [
      const CapsText('CHANGES'),
      const SizedBox(width: 8),
      if (rounds.length > 1)
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DraftSegmented<int>(
                items: [for (final r in rounds) (r.n, 'R${r.n}')],
                value: round.n,
                cellWidth: 32,
                cellKey: NoteView.roundKey,
                onChanged: (n) => setState(() {
                  _round = n;
                  _ticked.clear();
                }),
              ),
            ),
          ),
        )
      else
        Text('Round ${round.n}', style: tokens.micro),
    ],
  );

  Widget _changeRow(RoundChange change, NoteRound round) => _ChangeRow(
    change: change,
    undone: round.isUndone(change.id),
    ticked: _ticked.contains(change.id),
    onChanged: (on) => setState(() {
      if (on) {
        _ticked.add(change.id);
      } else {
        _ticked.remove(change.id);
      }
    }),
  );

  Widget _undoButtons(NoteRound round) {
    final git = round.hasCheckpoints;
    final undoable = [
      for (final c in round.changes)
        if (!round.isUndone(c.id)) c,
    ];
    final selected = undoable.where((c) => _ticked.contains(c.id)).length;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 4,
      children: [
        DraftButton.link(
          key: NoteView.undoSelectedKey,
          label: git ? 'Undo selected' : 'Ask agent to undo selected',
          onPressed: selected == 0 ? null : () => _undo(all: false),
        ),
        DraftButton.link(
          key: NoteView.undoAllKey,
          label: git ? 'Undo all' : 'Ask agent to undo all',
          onPressed: undoable.isEmpty ? null : () => _undo(all: true),
        ),
      ],
    );
  }

  Widget _footer(PinPointTokens tokens, Annotation note) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: tokens.ink)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (PinMarker.showsMark(note.status)) ...[
          _reasonField(tokens),
          const SizedBox(height: 8),
        ],
        _footerButtons(note),
      ],
    ),
  );

  /// The reason reaches the agent as the user's message: without it a
  /// reopened note says nothing about what is still wrong.
  Widget _reasonField(PinPointTokens tokens) => TextField(
    key: NoteView.reasonKey,
    controller: _reason,
    // One line that grows to four. Enter adds a line; Reopen and Undo send
    // the text.
    minLines: 1,
    maxLines: 4,
    keyboardType: TextInputType.multiline,
    onTapOutside: (_) {},
    style: tokens.body,
    decoration: InputDecoration(
      isDense: true,
      hintText: 'What is still wrong? Sent with Reopen or Undo',
      hintStyle: tokens.body.copyWith(color: tokens.muted),
      contentPadding: const EdgeInsets.all(8),
    ),
  );

  Widget _footerButtons(Annotation note) {
    final id = note.id;
    final status = note.status;
    final draft = status == NoteStatus.draft;
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        DraftButton.link(
          key: NoteView.deleteKey,
          label: 'Delete',
          onPressed: () => widget.actions.delete(id),
        ),
        if (note.tape != null && widget.actions.replay != null)
          DraftButton.outline(
            key: NoteView.replayKey,
            label: 'Replay',
            onPressed: () => widget.actions.replay!(id),
          ),
        if (draft && widget.drafts > 1)
          DraftButton.outline(
            key: NoteView.sendAllKey,
            label: 'Send all ${widget.drafts} drafts',
            onPressed: widget.actions.sendAll,
          ),
        if (PinMarker.showsMark(status))
          DraftButton.outline(
            key: NoteView.reopenKey,
            label: 'Reopen',
            onPressed: _reopen,
          ),
        if (NoteView.acceptsAnyway(note))
          DraftButton.outline(
            key: NoteView.acceptKey,
            label: 'Accept anyway',
            onPressed: () => widget.actions.accept(id),
          )
        else if (NoteView.canAccept(note))
          DraftButton.primary(
            key: NoteView.acceptKey,
            label: 'Accept',
            onPressed: () => widget.actions.accept(id),
          ),
        if (draft)
          DraftButton.primary(
            key: NoteView.sendKey,
            label: 'Send',
            onPressed: _text.text.trim().isEmpty
                ? null
                : () => widget.actions.send(id),
          ),
      ],
    );
  }
}

/// One change of a round: a checkbox with the agent's summary, then a line
/// for each file with its counts. A change that is already undone is struck
/// through and cannot be ticked.
class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.change,
    required this.undone,
    required this.ticked,
    required this.onChanged,
  });

  final RoundChange change;
  final bool undone;
  final bool ticked;
  final ValueChanged<bool> onChanged;

  /// The last two parts of [path], with `…/` before them when it is longer.
  static String shortPath(String path) {
    final parts = path.split('/');
    if (parts.length <= 2) return path;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final muted = undone ? tokens.faint : tokens.muted;
    final style = tokens.value.copyWith(
      fontSize: 11,
      height: 14 / 11,
      color: muted,
      decoration: undone ? TextDecoration.lineThrough : null,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DraftCheckbox(
                    key: NoteView.changeKey(change.id),
                    value: ticked && !undone,
                    onChanged: undone ? null : onChanged,
                    label: change.summary.isEmpty ? change.id : change.summary,
                    strike: undone,
                  ),
                ),
              ),
              if (change.shared) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: tokens.rule),
                  ),
                  child: Text('shared', style: tokens.micro),
                ),
              ],
            ],
          ),
          for (final file in change.files)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                '${shortPath(file.path)}'
                '${file.added == null ? '' : ' +${file.added}'}'
                '${file.removed == null ? '' : ' −${file.removed}'}',
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

/// A 16 px square for a note's status, drawn the way its pin is: a dotted
/// edge for a draft, a solid one once sent, a dashed one while the agent
/// works, and a glyph for the states after that.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph(this.status);

  final NoteStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final (IconData? icon, Color color) = switch (status) {
      NoteStatus.draft => (null, tokens.muted),
      NoteStatus.submitted => (Icons.north_east, tokens.ink),
      NoteStatus.inProgress => (PinPointIcons.moreHoriz, tokens.ink),
      NoteStatus.fixed => (PinPointIcons.check, tokens.ok),
      NoteStatus.verified => (PinPointIcons.doneAll, tokens.ok),
      NoteStatus.resolved => (PinPointIcons.doneAll, tokens.ink),
      NoteStatus.rejected => (PinPointIcons.close, tokens.ink),
    };
    final glyph = icon == null ? null : Icon(icon, size: 12, color: color);
    const side = 16.0;
    return SizedBox.square(
      dimension: side,
      child: switch (status) {
        NoteStatus.draft => DashedBox(
          color: color,
          strokeWidth: 1.5,
          dash: const [1.5, 1.5],
          radius: 2,
        ),
        NoteStatus.inProgress => DashedBox(
          color: color,
          strokeWidth: 1.5,
          dash: const [3, 2],
          radius: 2,
          child: Center(child: glyph),
        ),
        _ => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: tokens.ink, width: 1.5),
          ),
          child: Center(child: glyph),
        ),
      },
    );
  }
}

/// The result of a note's checks: a heading, then a line for each check, in
/// the `ok` or the `err` colour with a tick or a cross as well.
class _Verification extends StatelessWidget {
  const _Verification({super.key, required this.verification});

  final Map<String, Object?> verification;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final raw = verification['checks'];
    final checks = [
      if (raw is List<Object?>)
        for (final c in raw)
          if (c is Map<String, Object?>) c,
    ];
    final passed = verification['passed'] == true;
    final color = passed ? tokens.ok : tokens.err;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: passed ? null : tokens.errBg,
        border: Border.all(color: color),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(tokens, checks, passed: passed, color: color),
          for (final check in checks) _checkRow(tokens, check),
        ],
      ),
    );
  }

  Widget _heading(
    PinPointTokens tokens,
    List<Map<String, Object?>> checks, {
    required bool passed,
    required Color color,
  }) {
    final count = checks.where((c) => c['passed'] == true).length;
    return Row(
      children: [
        Icon(
          passed ? PinPointIcons.checkCircle : PinPointIcons.error,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Checks ${passed ? 'passed' : 'failed'} ($count of '
            '${checks.length} passed)',
            style: tokens.body.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _checkRow(PinPointTokens tokens, Map<String, Object?> check) {
    final ok = check['passed'] == true;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? PinPointIcons.check : PinPointIcons.close,
            size: 12,
            color: ok ? tokens.ok : tokens.err,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${check['type']}'
              '${check['message'] is String ? ': ${check['message']}' : ''}',
              style: tokens.value.copyWith(
                fontSize: 11,
                height: 14 / 11,
                color: tokens.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
