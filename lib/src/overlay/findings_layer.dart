part of 'findings_panel.dart';

/// Places [FindingsPanel] beside the rail while it is open and a mode is
/// active, where the what-if panel goes: the two take turns.
class FindingsPanelLayer extends StatelessWidget {
  const FindingsPanelLayer({
    super.key,
    required this.controller,
    required this.panelOpen,
    required this.placement,
    required this.onScan,
    required this.onAudit,
    required this.onMakeNote,
    required this.onSendDraft,
    required this.onCopy,
  });

  final PinPointController controller;
  final ValueNotifier<bool> panelOpen;
  final RailPlacement placement;
  final VoidCallback onScan;
  final VoidCallback onAudit;
  final void Function(Finding finding) onMakeNote;
  final void Function(String id) onSendDraft;
  final void Function(Finding finding) onCopy;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: panelOpen,
      builder: (context, open, _) {
        if (!open || !controller.isActive) return const SizedBox.shrink();
        return BesideRail(
          placement: placement,
          child: FindingsPanel(
            findings: controller.findings,
            notes: controller.notes,
            onScan: onScan,
            onAudit: onAudit,
            onMakeNote: onMakeNote,
            onSendDraft: onSendDraft,
            onCopy: onCopy,
            onClose: () => panelOpen.value = false,
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
///
/// The outline is 2 px, in the colour of the severity (`err`, `warn`,
/// `info`) over a `paper` halo, and each severity has its own stroke, so the
/// colour is not the only signal: errors are solid, warnings dashed, hints
/// dotted.
class FindingPainter extends CustomPainter {
  FindingPainter({
    required this.findings,
    required this.origin,
    required this.tokens,
  }) : super(repaint: Listenable.merge([findings, findings.hovered]));

  final FindingsController findings;

  /// The painter's own top-left in global logical pixels.
  final Offset Function() origin;

  final PinPointTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final shift = -origin();
    if (findings.trackRebuilds) {
      // The tint of a rebuild hot spot.
      final tint = Paint()..color = tokens.err.withValues(alpha: 0.18);
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
    final (Color color, List<double>? dash) = switch (finding.severity) {
      Severity.error => (tokens.err, null),
      Severity.warning => (tokens.warn, const <double>[6, 3]),
      Severity.info => (tokens.info, const <double>[1.5, 2.5]),
    };
    canvas.drawRect(local, Paint()..color = color.withValues(alpha: 0.12));
    strokeHalo(
      canvas,
      Path()..addRect(local.deflate(1)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
      tokens,
      dash: dash,
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
      !identical(oldDelegate.findings, findings) ||
      oldDelegate.tokens != tokens;
}
