import 'package:flutter/material.dart';

import '../model/annotation.dart';
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

  /// Back to submitted, for the agent to look at again.
  final ValueChanged<String> reopen;

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

  @override
  void didUpdateWidget(NoteView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another note opened: show its text. The same note changed (an edit,
    // a status from the agent): keep what is being typed.
    if (oldWidget.note.id != widget.note.id) {
      _text.text = widget.note.comment;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = widget.note;
    final id = note.id;
    final status = note.status;
    final draft = status == NoteStatus.draft;
    const compact = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          key: NoteView.statusKey,
          '${widget.number == null ? 'Note' : 'Note ${widget.number}'}'
          ' · ${PinMarker.label(status)} · ${note.intent.name}',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
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
              border: OutlineInputBorder(),
              isDense: true,
            ),
          )
        else
          SelectableText(note.comment, style: theme.textTheme.bodyMedium),
        if (note.messages.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Replies', style: theme.textTheme.labelMedium),
          for (final message in note.messages)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${message.from}: ', style: muted),
                    TextSpan(text: message.text),
                  ],
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
        if (note.verification case final verification?)
          Padding(
            key: NoteView.verificationKey,
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _verificationText(verification),
              style: theme.textTheme.bodySmall?.copyWith(
                color: note.checksPassed == true
                    ? const Color(0xFF2E7D32)
                    : theme.colorScheme.error,
              ),
            ),
          ),
        if (status == NoteStatus.resolved || status == NoteStatus.fixed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Check the change, then accept it or reopen the note.',
              style: muted,
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            if (draft) ...[
              FilledButton(
                key: NoteView.sendKey,
                style: compact,
                onPressed: _text.text.trim().isEmpty
                    ? null
                    : () => widget.actions.send(id),
                child: const Text('Send'),
              ),
              if (widget.drafts > 1)
                OutlinedButton(
                  key: NoteView.sendAllKey,
                  style: compact,
                  onPressed: widget.actions.sendAll,
                  child: Text('Send all ${widget.drafts} drafts'),
                ),
            ],
            if (PinMarker.showsMark(status)) ...[
              FilledButton(
                key: NoteView.acceptKey,
                style: compact,
                onPressed: () => widget.actions.accept(id),
                child: const Text('Accept'),
              ),
              OutlinedButton(
                key: NoteView.reopenKey,
                style: compact,
                onPressed: () => widget.actions.reopen(id),
                child: const Text('Reopen'),
              ),
            ],
            TextButton(
              key: NoteView.deleteKey,
              style: compact,
              onPressed: () => widget.actions.delete(id),
              child: const Text('Delete'),
            ),
          ],
        ),
      ],
    );
  }
}

/// `Checks failed (0 of 1 passed)` and one line per check.
String _verificationText(Map<String, Object?> verification) {
  final checks = [
    for (final c
        in verification['checks'] is List<Object?>
            ? verification['checks']! as List<Object?>
            : const <Object?>[])
      if (c is Map<String, Object?>) c,
  ];
  final passed = verification['passed'] == true;
  final count = checks.where((c) => c['passed'] == true).length;
  return [
    'Checks ${passed ? 'passed' : 'failed'} ($count of ${checks.length} '
        'passed)',
    for (final check in checks)
      '${check['passed'] == true ? '✓' : '✗'} ${check['type']}'
          '${check['message'] is String ? ': ${check['message']}' : ''}',
  ].join('\n');
}
