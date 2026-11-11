import 'package:flutter/material.dart';

import '../agent/checks.dart';
import '../agent/commands.dart' show AgentCommands;
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
  static const Key addCheckKey = ValueKey<String>('pinpoint.comment.addCheck');

  /// The menu item that adds the check of [type].
  static Key checkItemKey(String type) =>
      ValueKey<String>('pinpoint.comment.check.$type');

  /// The chip of the chosen check of [type].
  static Key checkChipKey(String type) =>
      ValueKey<String>('pinpoint.comment.checkChip.$type');

  /// What a chosen check reads as, for example `No overflow`.
  static String checkLabel(Map<String, Object?> check) {
    final type = check['type'];
    if (type == 'text_contains') return 'Text contains "${check['text']}"';
    for (final option in commentChecks) {
      if (option.type == type) return option.label;
    }
    return '$type';
  }

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
            _Checks(controller: controller, enabled: !sending),
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

/// The chosen checks as chips, and "Add check": what `verify_note` will
/// measure once the agent says the note is fixed.
class _Checks extends StatelessWidget {
  const _Checks({required this.controller, required this.enabled});

  final PinPointController controller;
  final bool enabled;

  /// The checks the menu offers for the selection: the fixed list, and
  /// "Text contains" with the selected widget's text when it shows one.
  List<Map<String, Object?>> _offered() {
    final element = controller.selection.value?.element;
    String? text;
    try {
      text = element == null ? null : AgentCommands.textOf(element);
    } catch (_) {
      text = null;
    }
    return [
      for (final option in commentChecks) option.check,
      if (text != null && text.trim().isNotEmpty && text != '[masked]')
        {'type': 'text_contains', 'text': clipText(text.trim(), 60)},
    ];
  }

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    final chosen = draft.checks;
    final open = [
      for (final check in _offered())
        if (!chosen.any((c) => c['type'] == check['type'])) check,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final check in chosen)
            InputChip(
              key: CommentForm.checkChipKey('${check['type']}'),
              label: Text(CommentForm.checkLabel(check)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              deleteIcon: const Icon(Icons.clear, size: 16),
              onDeleted: enabled
                  ? () => draft.removeCheck('${check['type']}')
                  : null,
            ),
          MenuAnchor(
            menuChildren: [
              for (final check in open)
                MenuItemButton(
                  key: CommentForm.checkItemKey('${check['type']}'),
                  onPressed: () => draft.addCheck(check),
                  child: Text(CommentForm.checkLabel(check)),
                ),
            ],
            builder: (context, menu, _) => TextButton.icon(
              key: CommentForm.addCheckKey,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: enabled && open.isNotEmpty
                  ? () => menu.isOpen ? menu.close() : menu.open()
                  : null,
              icon: const Icon(Icons.rule, size: 16),
              label: const Text('Add check'),
            ),
          ),
        ],
      ),
    );
  }
}
