import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../model/annotation.dart';
import '../theme/controls.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_tokens.dart';
import 'pin_tracker.dart';

/// Covers the screen and draws a [PinMarker] at the top-right of each
/// pinned widget. Only the markers take pointer events.
class PinLayer extends StatelessWidget {
  const PinLayer({
    super.key,
    required this.placements,
    required this.onOpen,
    this.openNote,
  });

  static const Key layerKey = ValueKey<String>('pinpoint.pins');

  final ValueListenable<List<PinPlacement>> placements;

  /// A click on the pin of the note with this id.
  final ValueChanged<String> onOpen;

  /// The id of the note open in the panel. Its pin gets the selected
  /// outline. Null for none, so no pin shows as selected.
  final ValueListenable<String?>? openNote;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PinPlacement>>(
      key: layerKey,
      valueListenable: placements,
      builder: (context, pins, _) => LayoutBuilder(
        builder: (context, constraints) => ValueListenableBuilder<String?>(
          valueListenable: openNote ?? _noNote,
          builder: (context, open, _) => Stack(
            children: [
              for (final pin in pins)
                Positioned(
                  key: ValueKey<String>('pinpoint.pin.${pin.id}'),
                  // The layer sits at the wrapper's origin, so a global rect
                  // is a rect here too (engineering rule 7). Centered on the
                  // widget's top-right corner, kept inside the screen.
                  left: _clamp(
                    pin.rect.right - PinMarker.size / 2,
                    constraints.maxWidth - PinMarker.size,
                  ),
                  top: _clamp(
                    pin.rect.top - PinMarker.size / 2,
                    constraints.maxHeight - PinMarker.size,
                  ),
                  child: PinMarker(
                    number: pin.number,
                    status: pin.status,
                    checksPassed: pin.checksPassed,
                    selected: pin.id == open,
                    onTap: () => onOpen(pin.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const ValueListenable<String?> _noNote = _NoNote();

  static double _clamp(double value, double max) =>
      max <= 0 ? 0 : value.clamp(0, max).toDouble();
}

/// A listenable that never has a value, for a [PinLayer] without an open note.
class _NoNote implements ValueListenable<String?> {
  const _NoNote();

  @override
  String? get value => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// A numbered pin, 22 px square, in the Drafting design. The state shows in
/// the border (dotted, solid or dashed), the fill, the shadow and a badge,
/// never in colour alone. A note the agent is done with fades, but stays
/// until the user accepts it.
class PinMarker extends StatelessWidget {
  const PinMarker({
    super.key,
    required this.number,
    required this.status,
    required this.onTap,
    this.checksPassed,
    this.selected = false,
  });

  static const Key checksKey = ValueKey<String>('pinpoint.pin.checks');

  /// The pin's box: the border, the fill and the number.
  static const Key bodyKey = ValueKey<String>('pinpoint.pin.body');

  /// The status badge: in progress, fixed, resolved or rejected. A draft and
  /// a sent pin have none.
  static const Key badgeKey = ValueKey<String>('pinpoint.pin.badge');

  /// Width and height.
  static const double size = PinPointSizes.pin;

  /// The opacity a resolved or rejected pin fades to.
  static const double fadedOpacity = 0.4;

  /// How long the fade takes. With the 2 second poll, a resolution shows
  /// within 3 seconds.
  static const Duration fadeDuration = Duration(milliseconds: 400);

  /// Corner radius of the pin.
  static const double radius = 2;

  /// Width of the pin's border.
  static const double borderWidth = 1.5;

  /// Dots of a draft pin's border: on, off.
  static const List<double> dotted = [1.5, 1.5];

  /// Dashes of an in-progress pin's border: on, off.
  static const List<double> dashed = [4, 3];

  /// Offset of the hard shadow under a sent pin.
  static const Offset shadowOffset = Offset(2, 2);

  /// Side of the status badge.
  static const double badgeSize = 13;

  /// Side of the verification badge.
  static const double checksSize = 15;

  final int number;
  final NoteStatus status;
  final VoidCallback onTap;

  /// The outcome of the note's last `verify_note`, shown as a small badge
  /// for the user to accept or reopen; null when none ran. A pass is a round
  /// green badge, a fail a square red one with "!".
  final bool? checksPassed;

  /// Whether the note is open in the panel: the pin gets the canvas
  /// selected outline.
  final bool selected;

  /// Whether the pin has a glyph badge besides its number.
  static bool showsMark(NoteStatus status) =>
      status == NoteStatus.fixed ||
      status == NoteStatus.resolved ||
      status == NoteStatus.rejected;

  /// Whether the pin is faded: the agent says it is done. The agent can
  /// mark a note resolved without fixing it, so the pin stays until the
  /// user accepts the result.
  static bool isFaded(NoteStatus status) =>
      status == NoteStatus.resolved || status == NoteStatus.rejected;

  static String label(NoteStatus status) => switch (status) {
    NoteStatus.draft => 'draft',
    NoteStatus.submitted => 'sent',
    NoteStatus.inProgress => 'in progress',
    NoteStatus.fixed => 'fixed',
    NoteStatus.verified => 'accepted',
    NoteStatus.resolved => 'resolved',
    NoteStatus.rejected => 'rejected',
  };

  /// The glyph of the status badge, or null for none.
  static IconData? badgeIcon(NoteStatus status) => switch (status) {
    NoteStatus.draft || NoteStatus.submitted => null,
    NoteStatus.inProgress => PinPointIcons.moreHoriz,
    NoteStatus.fixed => PinPointIcons.check,
    NoteStatus.verified || NoteStatus.resolved => PinPointIcons.doneAll,
    NoteStatus.rejected => PinPointIcons.close,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final checked = checksPassed;
    final inked =
        status == NoteStatus.fixed ||
        status == NoteStatus.verified ||
        status == NoteStatus.resolved;
    final shadowed =
        status != NoteStatus.draft && status != NoteStatus.rejected;
    final fill = inked ? tokens.ink : tokens.paper;
    final numberColor = switch (status) {
      NoteStatus.draft => tokens.muted,
      _ when inked => tokens.paper,
      _ => tokens.ink,
    };
    final borderColor = status == NoteStatus.draft ? tokens.muted : tokens.ink;

    final numberText = Text(
      '$number',
      style: tokens.value.copyWith(
        fontSize: 11,
        height: 1,
        fontWeight: FontWeight.w500,
        color: numberColor,
        decoration: status == NoteStatus.rejected
            ? TextDecoration.lineThrough
            : TextDecoration.none,
        decorationColor: numberColor,
      ),
    );
    final Widget border = switch (status) {
      NoteStatus.draft => DashedBox(
        color: borderColor,
        strokeWidth: borderWidth,
        dash: dotted,
        radius: radius,
        child: Center(child: numberText),
      ),
      NoteStatus.inProgress => DashedBox(
        color: borderColor,
        strokeWidth: borderWidth,
        dash: dashed,
        radius: radius,
        child: Center(child: numberText),
      ),
      _ => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Center(child: numberText),
      ),
    };

    final icon = badgeIcon(status);
    final message =
        'Note $number (${label(status)})'
        '${checked == null
            ? ''
            : checked
            ? ', checks passed'
            : ', checks failed'}';
    return Tooltip(
      message: message,
      child: AnimatedOpacity(
        opacity: isFaded(status) ? fadedOpacity : 1,
        duration: fadeDuration,
        child: Semantics(
          button: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: CustomPaint(
                foregroundPainter: _SelectedPinPainter(
                  selected: selected,
                  tokens: tokens,
                ),
                child: SizedBox.square(
                  dimension: size,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          key: bodyKey,
                          decoration: BoxDecoration(
                            color: fill,
                            borderRadius: BorderRadius.circular(radius),
                            // The paper halo, then the hard shadow.
                            boxShadow: [
                              BoxShadow(spreadRadius: 1, color: tokens.paper),
                              if (shadowed)
                                BoxShadow(
                                  offset: shadowOffset,
                                  color: tokens.shadow,
                                ),
                            ],
                          ),
                          child: border,
                        ),
                      ),
                      if (icon != null) _statusBadge(tokens, icon),
                      if (checked != null) _checksBadge(tokens, checked),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A 13 px square badge on a corner: top-right (accent, white glyph) while
  /// the agent works, bottom-right (paper) for the rest.
  Widget _statusBadge(PinPointTokens tokens, IconData icon) {
    final working = status == NoteStatus.inProgress;
    // CSS puts the badge 8 px past the padding edge: 6.5 px past the box.
    const out = -6.5;
    return Positioned(
      right: out,
      top: working ? out : null,
      bottom: working ? null : out,
      width: badgeSize,
      height: badgeSize,
      child: DecoratedBox(
        key: badgeKey,
        decoration: BoxDecoration(
          color: working ? tokens.accent : tokens.paper,
          border: Border.all(color: tokens.ink),
        ),
        child: Center(
          child: Icon(
            icon,
            size: 11,
            color: working
                ? tokens.onAccent
                : status == NoteStatus.fixed
                ? tokens.ok
                : tokens.ink,
          ),
        ),
      ),
    );
  }

  /// A 15 px badge at the top-right: round and green for a pass, square and
  /// red with "!" for a fail.
  Widget _checksBadge(PinPointTokens tokens, bool passed) {
    const out = -7.5;
    return Positioned(
      right: out,
      top: out,
      width: checksSize,
      height: checksSize,
      child: DecoratedBox(
        key: checksKey,
        decoration: BoxDecoration(
          shape: passed ? BoxShape.circle : BoxShape.rectangle,
          color: passed ? tokens.ok : tokens.err,
          border: Border.all(color: tokens.paper),
        ),
        child: Center(
          child: passed
              ? Icon(PinPointIcons.check, size: 11, color: tokens.onAccent)
              : Text(
                  '!',
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: tokens.onAccent,
                    decoration: TextDecoration.none,
                  ),
                ),
        ),
      ),
    );
  }
}

/// The canvas "selected" outline around a pin: 2 px `accent`, 1 px `paper`
/// and 1 px `ink`, all outside the pin so its own border stays visible.
class _SelectedPinPainter extends CustomPainter {
  const _SelectedPinPainter({required this.selected, required this.tokens});

  final bool selected;
  final PinPointTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    if (!selected) return;
    paintSelected(canvas, (Offset.zero & size).inflate(2), tokens);
  }

  @override
  bool shouldRepaint(_SelectedPinPainter old) =>
      old.selected != selected || old.tokens != tokens;
}
