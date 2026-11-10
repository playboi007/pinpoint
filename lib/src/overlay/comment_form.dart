import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../model/annotation.dart';

/// The Comment tab of the info panel: intent, comment, whether to attach a
/// screenshot, and the buttons that send it.
///
/// Everything it edits lives in [PinPointController.draft], so the text
/// survives a new selection, Esc and a failed send.
class CommentForm extends StatelessWidget {
  const CommentForm({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.onSaveDraft,
    required this.onCopy,
  });

  static const Key fieldKey = ValueKey<String>('pinpoint.comment.field');
  static const Key screenshotKey = ValueKey<String>(
    'pinpoint.comment.screenshot',
  );
  static const Key sendKey = ValueKey<String>('pinpoint.comment.send');
  static const Key draftKey = ValueKey<String>('pinpoint.comment.draft');
  static const Key copyKey = ValueKey<String>('pinpoint.comment.copy');
  static const Key cancelKey = ValueKey<String>('pinpoint.comment.cancel');

  final PinPointController controller;

  /// The comment field's focus. Owned by the overlay, which moves focus
  /// into the field when commenting starts.
  final FocusNode focusNode;

  final VoidCallback onSend;

  /// Keeps the comment as a draft pin, sent to no agent. Null hides the
  /// button.
  final VoidCallback? onSaveDraft;

  final VoidCallback onCopy;

  static String _label(AnnotationIntent intent) => switch (intent) {
    AnnotationIntent.bug => 'Bug',
    AnnotationIntent.improve => 'Improve',
    AnnotationIntent.question => 'Question',
  };

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    return ListenableBuilder(
      listenable: Listenable.merge([draft, draft.text]),
      builder: (context, _) {
        final mode = controller.mode;
        final sending = mode == PinPointMode.sending;
        final commenting = mode == PinPointMode.commenting;
        const compact = ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final intent in AnnotationIntent.values)
                  ChoiceChip(
                    label: Text(_label(intent)),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selected: draft.intent == intent,
                    onSelected: sending ? null : (_) => draft.intent = intent,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: fieldKey,
              controller: draft.text,
              focusNode: focusNode,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              // Read-only, not disabled, while sending: a disabled field
              // drops focus, and focus must stay in the panel.
              readOnly: sending,
              // After Esc the selection is kept in picking mode; a click on
              // the field goes back to commenting on it.
              onTap: () {
                final selection = controller.selection.value;
                if (controller.mode == PinPointMode.picking &&
                    selection != null) {
                  controller.select(selection);
                }
              },
              // Keep focus on a click elsewhere: a stray click must not end
              // the comment.
              onTapOutside: (_) {},
              decoration: const InputDecoration(
                hintText: 'What should change?',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            CheckboxListTile(
              key: screenshotKey,
              value: draft.includeScreenshot,
              onChanged: sending
                  ? null
                  : (value) => draft.includeScreenshot = value ?? true,
              title: const Text('Include screenshot'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: sendKey,
                  style: compact,
                  onPressed: commenting && draft.hasText ? onSend : null,
                  child: Text(sending ? 'Sending…' : 'Send'),
                ),
                if (onSaveDraft != null)
                  OutlinedButton(
                    key: draftKey,
                    style: compact,
                    onPressed: commenting && draft.hasText ? onSaveDraft : null,
                    child: const Text('Save draft'),
                  ),
                OutlinedButton(
                  key: copyKey,
                  style: compact,
                  onPressed: sending ? null : onCopy,
                  child: const Text('Copy as Markdown'),
                ),
                TextButton(
                  key: cancelKey,
                  style: compact,
                  onPressed: commenting ? controller.back : null,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
