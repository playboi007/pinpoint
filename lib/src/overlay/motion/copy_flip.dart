import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/controls.dart';
import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_tokens.dart';
import 'flights.dart';

/// The "Copy as Markdown" button of the comment footer, with the icon that
/// flips to a check when the copy worked.
///
/// The icon turns about its vertical axis (a quick half turn, 3D-ish), shows
/// a check for [rest], and turns back. The copy itself is not held back: the
/// flip follows [PinPointFlights.copies], which the overlay bumps once the
/// text is on the clipboard, so a failed copy never shows a check. Without a
/// [flights] (a footer built alone) the flip follows the press.
///
/// With reduced motion the icon changes at once and back at once. While the
/// check rests nothing animates: the rest is a timer.
class CopyFlipButton extends StatefulWidget {
  const CopyFlipButton({
    super.key,
    this.buttonKey,
    required this.onPressed,
    required this.color,
    this.flights,
    this.rest = const Duration(milliseconds: 1200),
  });

  /// The key of the [DraftIconButton] inside.
  final Key? buttonKey;

  /// Null disables the button.
  final VoidCallback? onPressed;

  final Color color;
  final PinPointFlights? flights;

  /// How long the check stays.
  final Duration rest;

  static const String tooltip = 'Copy as Markdown';
  static const String doneTooltip = 'Copied as Markdown';

  @override
  State<CopyFlipButton> createState() => _CopyFlipButtonState();
}

class _CopyFlipButtonState extends State<CopyFlipButton>
    with SingleTickerProviderStateMixin {
  /// 0 shows the copy icon, 1 the check; the turn happens in between.
  late final AnimationController _flip = AnimationController(vsync: this);
  Timer? _rest;
  int _copies = 0;

  @override
  void initState() {
    super.initState();
    _copies = widget.flights?.copies.value ?? 0;
    widget.flights?.copies.addListener(_onCopied);
  }

  @override
  void didUpdateWidget(CopyFlipButton old) {
    super.didUpdateWidget(old);
    if (old.flights == widget.flights) return;
    old.flights?.copies.removeListener(_onCopied);
    widget.flights?.copies.addListener(_onCopied);
    _copies = widget.flights?.copies.value ?? 0;
  }

  void _onCopied() {
    final count = widget.flights!.copies.value;
    if (count == _copies) return;
    _copies = count;
    _show();
  }

  /// Turns to the check, and back after [CopyFlipButton.rest].
  void _show() {
    _rest?.cancel();
    _flip.forward();
    _rest = Timer(widget.rest, () {
      if (mounted) _flip.reverse();
    });
  }

  @override
  void dispose() {
    _rest?.cancel();
    widget.flights?.copies.removeListener(_onCopied);
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // In build as well: the slow motion can change while it turns.
    final motion = PinPointMotion.of(context);
    _flip
      ..duration = motion.quick
      ..reverseDuration = motion.quick;
    final tokens = PinPointTokens.of(context);
    final onPressed = widget.onPressed;
    return AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
        final v = _flip.value;
        final checked = v >= 0.5;
        // A half turn in all: the first quarter hides one face, the second
        // brings up the other.
        final angle = checked ? (v - 1) * math.pi : v * math.pi;
        final button = DraftIconButton(
          key: widget.buttonKey,
          icon: checked ? PinPointIcons.check : PinPointIcons.contentCopy,
          iconSize: 16,
          color: checked ? tokens.ok : widget.color,
          tooltip: checked
              ? CopyFlipButton.doneTooltip
              : CopyFlipButton.tooltip,
          onPressed: onPressed == null
              ? null
              : () {
                  onPressed();
                  if (widget.flights == null) _show();
                },
        );
        if (v == 0 || v == 1) return button;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.01)
            ..rotateY(angle),
          child: button,
        );
      },
    );
  }
}
