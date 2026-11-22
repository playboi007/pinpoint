import 'package:flutter/material.dart';

import '../core/note_book.dart';
import '../core/pinpoint_controller.dart';
import '../detect/debug_paint.dart';
import '../detect/detector.dart';
import '../detect/findings_controller.dart';
import '../model/annotation.dart';
import '../search/render_search.dart';
import '../theme/controls.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_tokens.dart';
import 'panel_keys.dart';
import 'rail.dart';

part 'findings_layer.dart';

/// What the list calls each kind of finding.
String findingKindLabel(String kind) => switch (kind) {
  'overflow' => 'Overflow',
  'truncated_text' => 'Truncated text',
  'oversized_image' => 'Oversized images',
  'exception' => 'Errors',
  'unlabeled_action' => 'Unlabeled actions',
  'small_tap_target' => 'Small tap targets',
  'low_contrast' => 'Low contrast',
  'rebuild_heat' => 'Rebuild heat',
  _ => kind,
};

/// The findings list: "Scan this screen", the detector switches, and every
/// finding grouped by kind. Hovering a finding outlines it on the app;
/// "Send note" turns it into a note and sends it, so the agent sees it at
/// once: it is complete (comment, check, environment), never half written.
/// A note that is still a draft (the send failed, or the agent's stress
/// matrix filed it) has "Send draft N". A finding with no widget (an error
/// from the engine or an uncaught error) has "Copy" instead.
///
/// It opens beside the rail, from the rail's Findings item, which has
/// [buttonKey].
class FindingsPanel extends StatelessWidget {
  const FindingsPanel({
    super.key,
    required this.findings,
    required this.notes,
    required this.onScan,
    required this.onAudit,
    required this.onMakeNote,
    required this.onSendDraft,
    required this.onCopy,
    required this.onClose,
  });

  /// The Findings item of the rail.
  static const Key buttonKey = ValueKey<String>('pinpoint.findings.button');
  static const Key panelKey = ValueKey<String>('pinpoint.findings.panel');
  static const Key scanKey = ValueKey<String>('pinpoint.findings.scan');
  static const Key clearKey = ValueKey<String>('pinpoint.findings.clear');
  static const Key closeKey = ValueKey<String>('pinpoint.findings.close');
  static const Key errorsKey = ValueKey<String>('pinpoint.findings.errors');
  static const Key imagesKey = ValueKey<String>('pinpoint.findings.images');
  static const Key auditKey = ValueKey<String>('pinpoint.findings.audit');
  static const Key rebuildsKey = ValueKey<String>('pinpoint.findings.rebuilds');

  /// The chip of the debug paint [flag].
  static Key paintKey(DebugPaintFlag flag) =>
      ValueKey<String>('pinpoint.findings.paint.${flag.name}');

  /// The heading of the group of [kind].
  static Key groupKey(String kind) =>
      ValueKey<String>('pinpoint.findings.group.$kind');

  /// The row of [finding].
  static Key rowKey(Finding finding) =>
      ValueKey<String>('pinpoint.findings.row.${finding.key}');

  /// The "Send note" button of [finding].
  static Key noteKey(Finding finding) =>
      ValueKey<String>('pinpoint.findings.note.${finding.key}');

  /// The "Send draft N" button of [finding], when its note is a draft.
  static Key sendDraftKey(Finding finding) =>
      ValueKey<String>('pinpoint.findings.sendDraft.${finding.key}');

  /// The "Copy" button of [finding], shown when it has no widget.
  static Key copyKey(Finding finding) =>
      ValueKey<String>('pinpoint.findings.copy.${finding.key}');

  /// Why a finding with no widget has no note.
  static const String noWidgetMessage =
      'No widget: this error comes from outside your widgets (the engine, '
      'or code nothing caught), so there is nothing to pin a note on. '
      'Copy it instead.';

  /// [finding] as plain text for the clipboard: the summary, the full
  /// message, the library and context when known, and the stack.
  static String copyText(Finding finding) {
    final data = finding.data;
    final stack = data['stack'];
    return [
      finding.summary,
      if (data['exception'] case final String exception) exception,
      [
        if (data['library'] case final String library) 'Library: $library',
        if (data['context'] case final String context) 'Context: $context',
      ].join('\n'),
      if (stack is List && stack.isNotEmpty) ['Stack:', ...stack].join('\n'),
    ].where((part) => part.isNotEmpty).join('\n\n');
  }

  final FindingsController findings;

  /// The notes, to show which findings already have one.
  final NoteBook notes;

  final VoidCallback onScan;

  /// Runs the accessibility audit.
  final VoidCallback onAudit;

  /// Makes a note from a finding and sends it.
  final void Function(Finding finding) onMakeNote;

  /// Sends the draft note with this id.
  final void Function(String id) onSendDraft;

  /// Puts [copyText] of a finding with no widget on the clipboard.
  final void Function(Finding finding) onCopy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return PanelKeyScope(
      child: DraftSurface(
        key: panelKey,
        elevation: 3,
        child: ListenableBuilder(
          listenable: Listenable.merge([findings, notes]),
          builder: (context, _) {
            final all = findings.findings;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(tokens, all.length),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      _actions(),
                      _switches(tokens),
                      const DraftRule(),
                      if (all.isEmpty)
                        _empty(tokens)
                      else
                        ..._groups(tokens, all),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(PinPointTokens tokens, int count) => Container(
    height: PinPointSizes.panelHeader,
    padding: const EdgeInsets.only(left: PinPointSizes.panelPadding, right: 8),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: tokens.ink)),
    ),
    child: Row(
      children: [
        Text('Findings', style: tokens.title),
        if (count > 0) ...[const SizedBox(width: 8), CountBadge(count)],
        const Spacer(),
        DraftIconButton(
          key: closeKey,
          icon: PinPointIcons.close,
          tooltip: 'Close',
          onPressed: onClose,
        ),
      ],
    ),
  );

  Widget _actions() => Padding(
    padding: const EdgeInsets.all(PinPointSizes.panelPadding),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DraftButton.primary(
          key: scanKey,
          // The scan comes first: the sweep draws its findings. It never
          // delays the scan.
          onPressed: () {
            onScan();
            findings.sweep();
          },
          icon: Icons.search,
          label: 'Scan this screen',
        ),
        DraftButton.outline(
          key: auditKey,
          // Semantics stay on for the audit's frame only.
          onPressed: findings.auditing ? null : onAudit,
          icon: Icons.accessibility_new,
          label: 'Check accessibility',
        ),
        if (findings.auditing) const DraftSpinner(),
        DraftButton.link(
          key: clearKey,
          onPressed: findings.clear,
          label: 'Clear',
        ),
      ],
    ),
  );

  Widget _switches(PinPointTokens tokens) => Padding(
    padding: const EdgeInsets.fromLTRB(
      PinPointSizes.panelPadding,
      0,
      PinPointSizes.panelPadding,
      PinPointSizes.panelPadding,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DraftRule(),
        const SizedBox(height: 10),
        const CapsText('DETECTORS'),
        const SizedBox(height: 4),
        ..._detectors(tokens),
        const SizedBox(height: PinPointSizes.sectionGap),
        const DraftRule(),
        const SizedBox(height: 10),
        const CapsText('DEBUG PAINT'),
        const SizedBox(height: 6),
        _paintChips(),
      ],
    ),
  );

  List<Widget> _detectors(PinPointTokens tokens) => [
    _switch(
      errorsKey,
      'Capture errors',
      value: findings.captureErrors,
      onChanged: (on) => findings.captureErrors = on,
    ),
    _switch(
      imagesKey,
      'Track oversized images',
      value: findings.trackImages,
      onChanged: (on) => findings.trackImages = on,
    ),
    _switch(
      rebuildsKey,
      'Rebuild heat (top ten on scan)',
      value: findings.trackRebuilds,
      onChanged: (on) => findings.trackRebuilds = on,
    ),
    if (findings.rebuildsTakenOver)
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          'Rebuild tracking was taken over by DevTools.',
          style: tokens.body.copyWith(
            fontSize: 11,
            height: 14 / 11,
            color: tokens.err,
          ),
        ),
      ),
  ];

  Widget _paintChips() => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final flag in DebugPaintFlag.values)
        DraftChip(
          key: paintKey(flag),
          label: flag.label,
          look: findings.debugPaint.contains(flag)
              ? ChipLook.selected
              : ChipLook.rest,
          onTap: () => findings.setDebugPaint(
            flag,
            on: !findings.debugPaint.contains(flag),
          ),
        ),
    ],
  );

  static Widget _switch(
    Key key,
    String label, {
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: PinPointSizes.rowHeight),
    child: Align(
      alignment: Alignment.centerLeft,
      child: DraftCheckbox(
        key: key,
        value: value,
        onChanged: onChanged,
        label: label,
      ),
    ),
  );

  Widget _empty(PinPointTokens tokens) => Padding(
    padding: const EdgeInsets.all(PinPointSizes.panelPadding),
    child: Text(
      findings.hasScanned
          ? 'Nothing found on this screen.'
          : 'Scan this screen to look for overflow, cut text, oversized '
                'images and more. Errors are captured as they happen.',
      style: tokens.label,
    ),
  );

  List<Widget> _groups(PinPointTokens tokens, List<Finding> all) {
    final byKind = <String, List<Finding>>{};
    for (final finding in all) {
      (byKind[finding.kind] ??= <Finding>[]).add(finding);
    }
    return [
      for (final MapEntry(key: kind, value: group) in byKind.entries) ...[
        Container(
          key: groupKey(kind),
          height: PinPointSizes.rowHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: PinPointSizes.panelPadding,
          ),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: tokens.rule),
              bottom: BorderSide(color: tokens.rule),
            ),
          ),
          child: CapsText(
            '${findingKindLabel(kind).toUpperCase()} (${group.length})',
          ),
        ),
        for (final finding in group) _row(tokens, finding),
      ],
    ];
  }

  Widget _row(PinPointTokens tokens, Finding finding) => MouseRegion(
    key: rowKey(finding),
    onEnter: (_) => findings.hovered.value = finding,
    onExit: (_) {
      if (identical(findings.hovered.value, finding)) {
        findings.hovered.value = null;
      }
    },
    child: Container(
      constraints: const BoxConstraints(minHeight: PinPointSizes.rowHeight),
      padding: const EdgeInsets.fromLTRB(PinPointSizes.panelPadding, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.rule)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeverityBadge(severityLook(finding.severity)),
          const SizedBox(width: 8),
          Expanded(child: _rowText(tokens, finding)),
          ..._rowActions(tokens, finding),
        ],
      ),
    ),
  );

  Widget _rowText(PinPointTokens tokens, Finding finding) {
    final source = finding.source;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          finding.summary,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: tokens.body,
        ),
        if (source != null)
          StartEllipsisText(
            '${source.uri.split('/').last}:${source.line}',
            style: tokens.value.copyWith(
              fontSize: 10,
              height: 13 / 10,
              color: tokens.muted,
            ),
          ),
      ],
    );
  }

  List<Widget> _rowActions(PinPointTokens tokens, Finding finding) {
    final note = _noteOf(finding);
    if (note != null) return [_noteState(tokens, finding, note)];
    if (finding.element != null) {
      return [
        DraftButton.link(
          key: noteKey(finding),
          onPressed: () => onMakeNote(finding),
          label: 'Send note',
        ),
      ];
    }
    // No widget (an engine assertion, an uncaught error): nothing to pin a
    // note on. Say why, and offer the full error as text.
    return [
      Tooltip(
        message: noWidgetMessage,
        child: DraftButton.link(
          key: noteKey(finding),
          onPressed: null,
          label: 'Send note',
        ),
      ),
      DraftIconButton(
        key: copyKey(finding),
        tooltip: 'Copy error',
        iconSize: 16,
        icon: PinPointIcons.contentCopy,
        onPressed: () => onCopy(finding),
      ),
    ];
  }

  Widget _noteState(PinPointTokens tokens, Finding finding, Annotation note) {
    final number = notes.numberOf(note.id);
    if (note.status == NoteStatus.draft) {
      return DraftButton.link(
        key: sendDraftKey(finding),
        onPressed: () => onSendDraft(note.id),
        label: 'Send draft ${number ?? ''}'.trim(),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Text(
        number == null ? 'Noted' : 'Note $number',
        style: tokens.micro,
      ),
    );
  }

  /// The note made from [finding], or null.
  Annotation? _noteOf(Finding finding) {
    for (final note in notes.notes) {
      if (note.finding?['key'] == finding.key) return note;
    }
    return null;
  }

  /// The badge look of a severity.
  static PinPointSeverityLook severityLook(Severity severity) =>
      switch (severity) {
        Severity.error => PinPointSeverityLook.error,
        Severity.warning => PinPointSeverityLook.warn,
        Severity.info => PinPointSeverityLook.info,
      };
}
