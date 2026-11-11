import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../agent/checks.dart';
import '../agent/commands.dart' show AgentCommands;
import '../core/pinpoint_controller.dart';
import '../model/annotation.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';

/// The Comment tab of the info panel: intent, comment, and whether to attach
/// a screenshot. Its buttons are in [CommentFooter], which the info panel
/// keeps under the scrolling body.
///
/// Everything it edits lives in [PinPointController.draft], so the text
/// survives a new selection, Esc and a failed send.
class CommentForm extends StatelessWidget {
  const CommentForm({
    super.key,
    required this.controller,
    required this.focusNode,
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

  static String _label(AnnotationIntent intent) => switch (intent) {
    AnnotationIntent.bug => 'Bug',
    AnnotationIntent.improve => 'Improve',
    AnnotationIntent.question => 'Question',
  };

  static IconData _icon(AnnotationIntent intent) => switch (intent) {
    AnnotationIntent.bug => PinPointIcons.bugReport,
    AnnotationIntent.improve => PinPointIcons.improve,
    AnnotationIntent.question => PinPointIcons.help,
  };

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    return ListenableBuilder(
      listenable: Listenable.merge([draft, draft.text]),
      builder: (context, _) {
        final sending = controller.mode == PinPointMode.sending;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final intent in AnnotationIntent.values)
                  DraftChip(
                    label: _label(intent),
                    icon: _icon(intent),
                    mono: false,
                    look: draft.intent == intent
                        ? ChipLook.selected
                        : ChipLook.rest,
                    onTap: sending ? null : () => draft.intent = intent,
                  ),
              ],
            ),
            const SizedBox(height: 12),
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
                contentPadding: EdgeInsets.all(8),
              ),
            ),
            const SizedBox(height: 12),
            _Checks(
              controller: controller,
              enabled: !sending,
              screenshot: DraftCheckbox(
                key: screenshotKey,
                value: draft.includeScreenshot,
                onChanged: sending
                    ? null
                    : (value) => draft.includeScreenshot = value,
                label: 'Include screenshot',
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The footer of the Comment tab, 40 px: copy as Markdown, the send shortcut
/// as a hint, Cancel, Save draft and Send.
class CommentFooter extends StatelessWidget {
  const CommentFooter({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onCopy,
    this.onSaveDraft,
  });

  final PinPointController controller;
  final VoidCallback onSend;

  /// Keeps the comment as a draft pin, sent to no agent. Null hides the
  /// button.
  final VoidCallback? onSaveDraft;

  final VoidCallback onCopy;

  /// `⌘↵ send` where Cmd+Enter sends, `Ctrl↵ send` elsewhere. Both work.
  static String get _hint {
    final key = switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.iOS => '⌘↵',
      _ => 'Ctrl↵',
    };
    return '$key send';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final draft = controller.draft;
    return ListenableBuilder(
      listenable: Listenable.merge([draft, draft.text]),
      builder: (context, _) {
        final mode = controller.mode;
        final sending = mode == PinPointMode.sending;
        final commenting = mode == PinPointMode.commenting;
        final ready = commenting && draft.hasText;
        return Container(
          height: PinPointSizes.footerTall,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.ink)),
          ),
          // The buttons shrink to fit when the panel is narrow or the text
          // wide, instead of overflowing.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final room = constraints.maxWidth - 24 - 8 - 8;
              return Row(
                children: [
                  DraftIconButton(
                    key: CommentForm.copyKey,
                    icon: PinPointIcons.contentCopy,
                    iconSize: 16,
                    color: tokens.muted,
                    tooltip: 'Copy as Markdown',
                    onPressed: sending ? null : onCopy,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _hint,
                      style: tokens.value.copyWith(
                        fontSize: 11,
                        color: tokens.muted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: room < 0 ? 0 : room),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DraftButton.link(
                            key: CommentForm.cancelKey,
                            label: 'Cancel',
                            onPressed: commenting ? controller.back : null,
                          ),
                          if (onSaveDraft != null) ...[
                            const SizedBox(width: 8),
                            DraftButton.outline(
                              key: CommentForm.draftKey,
                              label: 'Save draft',
                              onPressed: ready ? onSaveDraft : null,
                            ),
                          ],
                          const SizedBox(width: 8),
                          DraftButton.primary(
                            key: CommentForm.sendKey,
                            label: sending ? 'Sending…' : 'Send',
                            onPressed: ready ? onSend : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// The chosen checks as chips, then "Include screenshot" and "Add check":
/// what `verify_note` will measure once the agent says the note is fixed.
class _Checks extends StatelessWidget {
  const _Checks({
    required this.controller,
    required this.enabled,
    required this.screenshot,
  });

  final PinPointController controller;
  final bool enabled;

  /// The screenshot checkbox, shown before "Add check".
  final Widget screenshot;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (chosen.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final check in chosen)
                DraftChip(
                  key: CommentForm.checkChipKey('${check['type']}'),
                  label: CommentForm.checkLabel(check),
                  mono: false,
                  clearLabel: 'Remove',
                  onClear: enabled
                      ? () => draft.removeCheck('${check['type']}')
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 14,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            screenshot,
            MenuAnchor(
              menuChildren: [
                for (final check in open)
                  MenuItemButton(
                    key: CommentForm.checkItemKey('${check['type']}'),
                    onPressed: () => draft.addCheck(check),
                    child: Text(CommentForm.checkLabel(check)),
                  ),
              ],
              builder: (context, menu, _) => DraftButton.link(
                key: CommentForm.addCheckKey,
                label: 'Add check',
                icon: PinPointIcons.add,
                onPressed: enabled && open.isNotEmpty
                    ? () => menu.isOpen ? menu.close() : menu.open()
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
