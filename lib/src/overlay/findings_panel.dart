import 'package:flutter/material.dart';

import '../core/note_book.dart';
import '../core/pinpoint_controller.dart';
import '../detect/debug_paint.dart';
import '../detect/detector.dart';
import '../detect/findings_controller.dart';
import '../search/render_search.dart';
import 'panel_keys.dart';
import 'toolbar.dart';

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

/// The findings button, bottom-right beside the launcher, while a mode is
/// active: a count badge, and a click opens [FindingsPanel].
class FindingsButton extends StatelessWidget {
  const FindingsButton({
    super.key,
    required this.controller,
    required this.panelOpen,
  });

  final PinPointController controller;
  final ValueNotifier<bool> panelOpen;

  @override
  Widget build(BuildContext context) {
    if (!controller.isActive) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          // Left of the launcher's default corner.
          padding: const EdgeInsets.only(
            right: 16 + PinPointLauncher.size + 8,
            bottom: 16,
          ),
          child: ListenableBuilder(
            listenable: controller.findings,
            builder: (context, _) {
              final count = controller.findings.findings.length;
              return Material(
                key: FindingsPanel.buttonKey,
                elevation: 4,
                color: colors.surface,
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: () => panelOpen.value = !panelOpen.value,
                  child: SizedBox(
                    height: PinPointLauncher.size,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Badge(
                            isLabelVisible: count > 0,
                            label: Text('$count'),
                            child: Icon(
                              Icons.bug_report_outlined,
                              color: colors.primary,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text('Findings'),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The findings list: "Scan this screen", the detector switches, and every
/// finding grouped by kind. Hovering a finding outlines it on the app;
/// "Make note" turns it into a draft note.
class FindingsPanel extends StatelessWidget {
  const FindingsPanel({
    super.key,
    required this.findings,
    required this.notes,
    required this.onScan,
    required this.onAudit,
    required this.onMakeNote,
    required this.onClose,
  });

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

  /// The "Make note" button of [finding].
  static Key noteKey(Finding finding) =>
      ValueKey<String>('pinpoint.findings.note.${finding.key}');

  static const double width = 360;

  final FindingsController findings;

  /// The notes, to show which findings already have one.
  final NoteBook notes;

  final VoidCallback onScan;

  /// Runs the accessibility audit.
  final VoidCallback onAudit;

  final void Function(Finding finding) onMakeNote;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PanelKeyScope(
      child: Material(
        key: panelKey,
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          child: ListenableBuilder(
            listenable: Listenable.merge([findings, notes]),
            builder: (context, _) {
              final all = findings.findings;
              return Column(
                children: [
                  _header(theme, all.length),
                  const Divider(height: 1),
                  _actions(),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        _switches(theme),
                        const Divider(height: 1),
                        if (all.isEmpty)
                          _empty(theme)
                        else
                          ..._groups(theme, all),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            count == 0 ? 'Findings' : 'Findings ($count)',
            style: theme.textTheme.titleMedium,
          ),
        ),
        IconButton(
          key: closeKey,
          tooltip: 'Close',
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );

  Widget _actions() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        FilledButton.icon(
          key: scanKey,
          onPressed: onScan,
          icon: const Icon(Icons.search, size: 18),
          label: const Text('Scan this screen'),
        ),
        OutlinedButton.icon(
          key: auditKey,
          // Semantics stay on for the audit's frame only.
          onPressed: findings.auditing ? null : onAudit,
          icon: findings.auditing
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.accessibility_new, size: 18),
          label: const Text('Check accessibility'),
        ),
        TextButton(
          key: clearKey,
          onPressed: findings.clear,
          child: const Text('Clear'),
        ),
      ],
    ),
  );

  Widget _switches(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
    child: Column(
      children: [
        _switch(
          errorsKey,
          'Capture errors',
          findings.captureErrors,
          (on) => findings.captureErrors = on,
        ),
        _switch(
          imagesKey,
          'Track oversized images',
          findings.trackImages,
          (on) => findings.trackImages = on,
        ),
        _switch(
          rebuildsKey,
          'Rebuild heat (top ten on scan)',
          findings.trackRebuilds,
          (on) => findings.trackRebuilds = on,
        ),
        if (findings.rebuildsTakenOver)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Rebuild tracking was taken over by DevTools.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final flag in DebugPaintFlag.values)
                FilterChip(
                  key: paintKey(flag),
                  label: Text(flag.label),
                  visualDensity: VisualDensity.compact,
                  selected: findings.debugPaint.contains(flag),
                  onSelected: (on) => findings.setDebugPaint(flag, on: on),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  static Widget _switch(
    Key key,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile(
    key: key,
    dense: true,
    visualDensity: VisualDensity.compact,
    title: Text(label),
    value: value,
    onChanged: onChanged,
  );

  Widget _empty(ThemeData theme) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        findings.hasScanned
            ? 'Nothing found on this screen.'
            : 'Scan this screen to look for overflow, cut text, oversized '
                  'images and more. Errors are captured as they happen.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall,
      ),
    ),
  );

  List<Widget> _groups(ThemeData theme, List<Finding> all) {
    final byKind = <String, List<Finding>>{};
    for (final finding in all) {
      (byKind[finding.kind] ??= <Finding>[]).add(finding);
    }
    return [
      for (final MapEntry(key: kind, value: group) in byKind.entries) ...[
        Padding(
          key: groupKey(kind),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${findingKindLabel(kind)} (${group.length})',
            style: theme.textTheme.labelLarge,
          ),
        ),
        for (final finding in group) _row(theme, finding),
      ],
    ];
  }

  Widget _row(ThemeData theme, Finding finding) {
    final number = _noteNumber(finding);
    final source = finding.source;
    return MouseRegion(
      key: rowKey(finding),
      onEnter: (_) => findings.hovered.value = finding,
      onExit: (_) {
        if (identical(findings.hovered.value, finding)) {
          findings.hovered.value = null;
        }
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: _severityIcon(theme, finding.severity),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    finding.summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (source != null)
                    Text(
                      '${source.uri.split('/').last}:${source.line}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (number != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: Text(number, style: theme.textTheme.labelMedium),
              )
            else
              TextButton(
                key: noteKey(finding),
                // A finding with no widget (an uncaught error) has nothing
                // to pin a note on.
                onPressed: finding.element == null
                    ? null
                    : () => onMakeNote(finding),
                child: const Text('Make note'),
              ),
          ],
        ),
      ),
    );
  }

  /// `Note 3` when a note was made from [finding], else null.
  String? _noteNumber(Finding finding) {
    for (final note in notes.notes) {
      if (note.finding?['key'] != finding.key) continue;
      final number = notes.numberOf(note.id);
      return number == null ? 'Noted' : 'Note $number';
    }
    return null;
  }

  static Widget _severityIcon(ThemeData theme, Severity severity) =>
      switch (severity) {
        Severity.error => Icon(
          Icons.error_outline,
          size: 18,
          color: theme.colorScheme.error,
        ),
        Severity.warning => const Icon(
          Icons.warning_amber,
          size: 18,
          color: Color(0xFFE65100),
        ),
        Severity.info => Icon(
          Icons.info_outline,
          size: 18,
          color: theme.colorScheme.primary,
        ),
      };
}

/// Places [FindingsPanel] on the left while it is open and a mode is
/// active, where the what-if panel goes: the two take turns.
class FindingsPanelLayer extends StatelessWidget {
  const FindingsPanelLayer({
    super.key,
    required this.controller,
    required this.panelOpen,
    required this.onScan,
    required this.onAudit,
    required this.onMakeNote,
  });

  final PinPointController controller;
  final ValueNotifier<bool> panelOpen;
  final VoidCallback onScan;
  final VoidCallback onAudit;
  final void Function(Finding finding) onMakeNote;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: panelOpen,
      builder: (context, open, _) {
        if (!open || !controller.isActive) return const SizedBox.shrink();
        return SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              // Above the what-if bar, which sits bottom-left.
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              child: FindingsPanel(
                findings: controller.findings,
                notes: controller.notes,
                onScan: onScan,
                onAudit: onAudit,
                onMakeNote: onMakeNote,
                onClose: () => panelOpen.value = false,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Outlines the finding under the pointer in the list, and while rebuild
/// heat is on, tints the rects of the hot spots. A rect is read again from
/// its render object when the widget is still there, so it follows a
/// scroll since the scan.
class FindingPainter extends CustomPainter {
  FindingPainter({required this.findings, required this.origin})
    : super(repaint: Listenable.merge([findings, findings.hovered]));

  final FindingsController findings;

  /// The painter's own top-left in global logical pixels.
  final Offset Function() origin;

  static const Color color = Color(0xFFE65100);

  /// The tint of a rebuild hot spot.
  static const Color heat = Color(0xFFD50000);

  @override
  void paint(Canvas canvas, Size size) {
    final shift = -origin();
    if (findings.trackRebuilds) {
      final tint = Paint()..color = heat.withValues(alpha: 0.18);
      for (final finding in findings.findings) {
        if (finding.kind != 'rebuild_heat') continue;
        final rect = _liveRect(finding) ?? finding.rect;
        if (rect != null) canvas.drawRect(rect.shift(shift), tint);
      }
    }
    final finding = findings.hovered.value;
    if (finding == null) return;
    final rect = _liveRect(finding) ?? finding.rect;
    if (rect == null) return;
    final local = rect.shift(shift);
    canvas
      ..drawRect(local, Paint()..color = color.withValues(alpha: 0.15))
      ..drawRect(
        local,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
  }

  static Rect? _liveRect(Finding finding) {
    final element = finding.element;
    if (element == null || !element.mounted) return null;
    final renderObject = element.renderObject;
    return renderObject == null
        ? null
        : RenderSearch.globalRectOf(renderObject);
  }

  @override
  bool shouldRepaint(FindingPainter oldDelegate) =>
      !identical(oldDelegate.findings, findings);
}
