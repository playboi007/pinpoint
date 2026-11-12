import 'package:flutter/material.dart';

import '../model/annotation.dart';
import '../theme/controls.dart';
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
  });

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

  /// "What is still wrong?": sent with Reopen.
  static const Key reasonKey = ValueKey<String>('pinpoint.note.reason');

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

  /// Why the user reopens the note.
  final TextEditingController _reason = TextEditingController();

  @override
  void didUpdateWidget(NoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another note opened: show its text. The same note changed (an edit,
    // a status from the agent): keep what is being typed.
    if (oldWidget.note.id != widget.note.id) {
      _text.text = widget.note.comment;
      _reason.clear();
    }
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
    final number = widget.number;
    // The body scrolls; the reason field and the buttons stay in a footer
    // under it, as the Comment tab's do. A note with many replies would
    // otherwise push Accept and Reopen out of the panel.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(PinPointSizes.panelPadding),
            child: _body(tokens, note, number),
          ),
        ),
        _footer(tokens, note),
      ],
    );
  }

  Widget _body(PinPointTokens tokens, Annotation note, int? number) {
    final id = note.id;
    final status = note.status;
    final draft = status == NoteStatus.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
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
          ],
        ),
        const SizedBox(height: 12),
        if (draft)
          TextField(
            key: NoteView.fieldKey,
            controller: _text,
            focusNode: widget.focusNode,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            onChanged: (value) => widget.actions.edit(id, value),
            onTapOutside: (_) {},
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(8),
            ),
          )
        else
          SelectableText(note.comment, style: tokens.body),
        if (note.messages.isNotEmpty) ...[
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
        ],
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

  Widget _footer(PinPointTokens tokens, Annotation note) {
    final id = note.id;
    final status = note.status;
    final draft = status == NoteStatus.draft;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.ink)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (PinMarker.showsMark(status)) ...[
            // The reason reaches the agent as the user's message: without it
            // a reopened note says nothing about what is still wrong.
            TextField(
              key: NoteView.reasonKey,
              controller: _reason,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _reopen(),
              onTapOutside: (_) {},
              style: tokens.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'What is still wrong? Sent with Reopen',
                hintStyle: tokens.body.copyWith(color: tokens.muted),
                contentPadding: const EdgeInsets.all(8),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
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
    final checks = [
      for (final c
          in verification['checks'] is List<Object?>
              ? verification['checks']! as List<Object?>
              : const <Object?>[])
        if (c is Map<String, Object?>) c,
    ];
    final passed = verification['passed'] == true;
    final count = checks.where((c) => c['passed'] == true).length;
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
          Row(
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
          ),
          for (final check in checks)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    check['passed'] == true
                        ? PinPointIcons.check
                        : PinPointIcons.close,
                    size: 12,
                    color: check['passed'] == true ? tokens.ok : tokens.err,
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
            ),
        ],
      ),
    );
  }
}
