import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../model/annotation.dart';
import '../theme/controls.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';
import 'motion/pin_motion.dart';
import 'pin_tracker.dart';

part 'pin_marker_badges.dart';

/// Covers the screen and draws a [PinMarker] at the top-right of each
/// pinned widget. Only the markers take pointer events.
///
/// A note the user accepted leaves the placements at once. Its pin folds
/// away for a moment first, as a picture only: it takes no taps and has no
/// semantics, and nothing waits for it.
class PinLayer extends StatefulWidget {
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

  /// The pin of the note [id] while it folds away after Accept.
  static Key foldKey(String id) => ValueKey<String>('pinpoint.pin.fold.$id');

  @override
  State<PinLayer> createState() => _PinLayerState();

  static const ValueListenable<String?> _noNote = _NoNote();

  static double _clamp(double value, double max) =>
      max <= 0 ? 0 : value.clamp(0, max).toDouble();
}

class _PinLayerState extends State<PinLayer> {
  /// The pins folding away, by note id. Kept here, since the placements
  /// drop them in the next frame.
  final Map<String, PinPlacement> _folding = <String, PinPlacement>{};

  /// The accepted placements that already folded, while the placements
  /// still list them: each folds once.
  final Set<String> _played = <String>{};

  Widget _place(
    PinPlacement pin,
    BoxConstraints constraints, {
    required Key key,
    required Widget child,
  }) => Positioned(
    key: key,
    // The layer sits at the wrapper's origin, so a global rect is a rect
    // here too (engineering rule 7). Centered on the widget's top-right
    // corner, kept inside the screen.
    left: PinLayer._clamp(
      pin.rect.right - PinMarker.size / 2,
      constraints.maxWidth - PinMarker.size,
    ),
    top: PinLayer._clamp(
      pin.rect.top - PinMarker.size / 2,
      constraints.maxHeight - PinMarker.size,
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final reduced = PinPointMotion.of(context).reduced;
    return ValueListenableBuilder<List<PinPlacement>>(
      key: PinLayer.layerKey,
      valueListenable: widget.placements,
      builder: (context, pins, _) => LayoutBuilder(
        builder: (context, constraints) => ValueListenableBuilder<String?>(
          valueListenable: widget.openNote ?? PinLayer._noNote,
          builder: (context, open, _) {
            _startFolds(pins, reduced: reduced);
            return Stack(
              children: [
                ..._pinMarkers(pins, constraints, open),
                ..._foldingMarkers(constraints),
              ],
            );
          },
        ),
      ),
    );
  }

  void _startFolds(List<PinPlacement> pins, {required bool reduced}) {
    if (!reduced) {
      for (final pin in pins) {
        if (pin.accepted && _played.add(pin.id)) _folding[pin.id] = pin;
      }
    }
    _played.removeWhere((id) => !pins.any((pin) => pin.id == id));
  }

  List<Widget> _pinMarkers(
    List<PinPlacement> pins,
    BoxConstraints constraints,
    String? open,
  ) => [
    for (final pin in pins)
      if (!pin.accepted)
        _place(
          pin,
          constraints,
          key: ValueKey<String>('pinpoint.pin.${pin.id}'),
          child: PinMarker(
            number: pin.number,
            status: pin.status,
            checksPassed: pin.checksPassed,
            selected: pin.id == open,
            onTap: () => widget.onOpen(pin.id),
          ),
        ),
  ];

  List<Widget> _foldingMarkers(BoxConstraints constraints) => [
    for (final pin in _folding.values)
      _place(
        pin,
        constraints,
        key: PinLayer.foldKey(pin.id),
        child: ExcludeSemantics(
          child: IgnorePointer(
            child: PinFold(
              onDone: () {
                if (_folding.remove(pin.id) != null) setState(() {});
              },
              child: PinMarker(
                number: pin.number,
                status: pin.status,
                checksPassed: pin.checksPassed,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
  ];
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
class PinMarker extends StatefulWidget {
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
  State<PinMarker> createState() => _PinMarkerState();
}

class _PinMarkerState extends State<PinMarker> with TickerProviderStateMixin {
  /// The agent fixed the note: the pin hops and the tick draws itself. At
  /// rest (value 1) nothing moves.
  late final AnimationController _fixed = AnimationController(
    vsync: this,
    value: 1,
  );

  /// A verify result arrived: the badge lands like a rubber stamp. At rest
  /// (value 1) nothing moves.
  late final AnimationController _stamp = AnimationController(
    vsync: this,
    value: 1,
  );

  void _time(PinPointMotion motion) {
    _fixed.duration = motion.expressive;
    _stamp.duration = motion.expressive;
  }

  @override
  void didUpdateWidget(PinMarker old) {
    super.didUpdateWidget(old);
    final motion = PinPointMotion.of(context);
    _time(motion);
    // Only a change while the pin is on screen plays. A pin built with its
    // state already, for example after a page load, stays at rest.
    final fixed =
        widget.status == NoteStatus.fixed && old.status != NoteStatus.fixed;
    if (widget.status != NoteStatus.fixed) _fixed.value = 1;
    if (fixed && !motion.reduced) _fixed.forward(from: 0);
    final result = widget.checksPassed;
    if (result == null) _stamp.value = 1;
    if (result != null && result != old.checksPassed && !motion.reduced) {
      _stamp.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fixed.dispose();
    _stamp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final motion = PinPointMotion.of(context);
    _time(motion);
    final pin = Tooltip(
      message: _message(),
      child: AnimatedOpacity(
        opacity: PinMarker.isFaded(widget.status) ? PinMarker.fadedOpacity : 1,
        duration: motion.scaled(PinMarker.fadeDuration),
        child: Semantics(
          // Its own node: without `container` the tap merges up into the
          // overlay's screen-sized node, and on web every click opens this note.
          container: true,
          button: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: CustomPaint(
                foregroundPainter: _SelectedPinPainter(
                  selected: widget.selected,
                  tokens: tokens,
                ),
                child: SizedBox.square(
                  dimension: PinMarker.size,
                  child: _stack(tokens),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The hop moves what is drawn, not the tap target.
    return AnimatedBuilder(
      animation: _fixed,
      child: pin,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, PinMoments.hop(_fixed.value)),
        transformHitTests: false,
        child: child,
      ),
    );
  }

  String _message() {
    final checks = switch (widget.checksPassed) {
      null => '',
      true => ', checks passed',
      false => ', checks failed',
    };
    return 'Note ${widget.number} (${PinMarker.label(widget.status)})$checks';
  }

  Widget _stack(PinPointTokens tokens) {
    final icon = PinMarker.badgeIcon(widget.status);
    final checked = widget.checksPassed;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: _box(tokens)),
        if (icon != null) _statusBadge(tokens, icon),
        if (checked != null) _checksBadge(tokens, passed: checked),
      ],
    );
  }

  /// The pin's box: the fill, the paper halo and the hard shadow.
  Widget _box(PinPointTokens tokens) {
    final status = widget.status;
    final inked =
        status == NoteStatus.fixed ||
        status == NoteStatus.verified ||
        status == NoteStatus.resolved;
    final shadowed =
        status != NoteStatus.draft && status != NoteStatus.rejected;
    return DecoratedBox(
      key: PinMarker.bodyKey,
      decoration: BoxDecoration(
        color: inked ? tokens.ink : tokens.paper,
        borderRadius: BorderRadius.circular(PinMarker.radius),
        boxShadow: [
          BoxShadow(spreadRadius: 1, color: tokens.paper),
          if (shadowed)
            BoxShadow(offset: PinMarker.shadowOffset, color: tokens.shadow),
        ],
      ),
      child: _border(tokens, inked: inked),
    );
  }

  Widget _border(PinPointTokens tokens, {required bool inked}) {
    final status = widget.status;
    final borderColor = status == NoteStatus.draft ? tokens.muted : tokens.ink;
    final number = Center(child: _numberText(tokens, inked: inked));
    return switch (status) {
      NoteStatus.draft => DashedBox(
        color: borderColor,
        strokeWidth: PinMarker.borderWidth,
        dash: PinMarker.dotted,
        radius: PinMarker.radius,
        child: number,
      ),
      NoteStatus.inProgress => DashedBox(
        color: borderColor,
        strokeWidth: PinMarker.borderWidth,
        dash: PinMarker.dashed,
        radius: PinMarker.radius,
        child: number,
      ),
      _ => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PinMarker.radius),
          border: Border.all(color: borderColor, width: PinMarker.borderWidth),
        ),
        child: number,
      ),
    };
  }

  Widget _numberText(PinPointTokens tokens, {required bool inked}) {
    final status = widget.status;
    final color = switch (status) {
      NoteStatus.draft => tokens.muted,
      _ when inked => tokens.paper,
      _ => tokens.ink,
    };
    return Text(
      '${widget.number}',
      style: tokens.value.copyWith(
        fontSize: 11,
        height: 1,
        fontWeight: FontWeight.w500,
        color: color,
        decoration: status == NoteStatus.rejected
            ? TextDecoration.lineThrough
            : TextDecoration.none,
        decorationColor: color,
      ),
    );
  }
}
