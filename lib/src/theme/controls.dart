import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'marks.dart';
import 'pinpoint_motion.dart';
import 'pinpoint_tokens.dart';

part 'controls_badges.dart';
part 'controls_buttons.dart';
part 'controls_choices.dart';
part 'controls_fields.dart';
part 'controls_text.dart';

// The shared controls of the Drafting design. Each one reads the colours from
// `PinPointTokens.of(context)`, so a palette switch restyles them. Radius is 0
// except where noted, nothing splashes, and hover or press is a plain fill.
// Buttons, fields, choices (chip, checkbox, segmented), badges and text live in
// the `controls_*.dart` parts.

// -- Building blocks ---------------------------------------------------------

/// Draws a dashed rectangle border, and optionally a fill under it.
///
/// The stroke runs inside the bounds, as a CSS border does. [radius] rounds
/// the corners. A dash is `[on, off]` in logical pixels.
class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter({
    required this.color,
    this.strokeWidth = 1,
    this.dash = const <double>[3, 3],
    this.radius = 0,
    this.fill,
  });

  /// The colour of the dashes.
  final Color color;

  /// The width of the stroke.
  final double strokeWidth;

  /// The dash pattern: on, off, on, off, and so on.
  final List<double> dash;

  /// The corner radius of the outer edge.
  final double radius;

  /// A fill drawn under the border. Null for none.
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final outer = RRect.fromRectAndRadius(bounds, Radius.circular(radius));
    if (fill != null) canvas.drawRRect(outer, Paint()..color = fill!);
    final inner = RRect.fromRectAndRadius(
      bounds.deflate(strokeWidth / 2),
      Radius.circular((radius - strokeWidth / 2).clamp(0.0, radius)),
    );
    canvas.drawPath(
      dashPath(Path()..addRRect(inner), dash),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.radius != radius ||
      old.fill != fill ||
      !listEquals(old.dash, dash);
}

/// A box with a dashed border. Its child sits inside the border, as in a
/// solid-bordered `Container`.
class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.color,
    this.strokeWidth = 1,
    this.dash = const <double>[3, 3],
    this.radius = 0,
    this.fill,
    this.child,
  });

  final Color color;
  final double strokeWidth;
  final List<double> dash;
  final double radius;
  final Color? fill;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: DashedBorderPainter(
      color: color,
      strokeWidth: strokeWidth,
      dash: dash,
      radius: radius,
      fill: fill,
    ),
    child: Padding(padding: EdgeInsets.all(strokeWidth), child: child),
  );
}

/// Tracks hover, press and keyboard focus for a control and reports taps. No
/// splash: the caller decides what a hover or a press looks like.
///
/// An enabled control takes keyboard focus (Tab) and Enter or Space taps it,
/// through `ActivateIntent`. A focus ring shows only when focus came from the
/// keyboard.
class _Interactive extends StatefulWidget {
  const _Interactive({
    required this.onTap,
    required this.builder,
    this.semanticLabel,
    this.button = true,
    this.focusable = true,
  });

  /// Null disables the control: no cursor, no tap, `hovered` stays false.
  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool hovered, bool pressed)
  builder;
  final String? semanticLabel;
  final bool button;

  /// False keeps the control out of the Tab order, for a control whose job
  /// the keyboard already has (the arrow keys in a number field).
  final bool focusable;

  @override
  State<_Interactive> createState() => _InteractiveState();
}

class _InteractiveState extends State<_Interactive> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onTap != null;

  @override
  void didUpdateWidget(_Interactive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && (_hovered || _pressed || _focused)) {
      _hovered = false;
      _pressed = false;
      _focused = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    Widget content = widget.builder(context, _hovered && _enabled, _pressed);
    if (_focused) {
      content = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: tokens.accent, width: 1.5),
        ),
        child: content,
      );
    }
    return Semantics(
      button: widget.button,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled && widget.focusable,
        onShowFocusHighlight: (value) {
          if (_focused != value) setState(() => _focused = value);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) {
            if (_enabled) setState(() => _hovered = true);
          },
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onTap,
            child: content,
          ),
        ),
      ),
    );
  }
}

// -- Surface, text, rule -----------------------------------------------------

/// A [PinPointTokens.surface] box: paper, 1 px ink border, hard shadow of
/// [elevation] (1 label or chip on the canvas, 2 rail, toast or menu, 3
/// panel).
class DraftSurface extends StatelessWidget {
  const DraftSurface({
    super.key,
    required this.elevation,
    required this.child,
    this.padding,
  });

  final int elevation;
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: PinPointTokens.of(context).surface(elevation),
    child: padding == null ? child : Padding(padding: padding!, child: child),
  );
}

/// A section header or tab label in the caps style: Roboto Mono 10/12,
/// letter spacing 0.8, muted. The text is shown as given; pass it in capitals.
class CapsText extends StatelessWidget {
  const CapsText(this.text, {super.key, this.color});

  final String text;

  /// Replaces the muted colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = PinPointTokens.of(context).caps;
    return Text(
      text,
      style: color == null ? style : style.copyWith(color: color),
    );
  }
}

/// A horizontal 1 px divider in the `rule` colour. Pass [color] for the
/// heavier `ink` rule under a header or above a footer.
class DraftRule extends StatelessWidget {
  const DraftRule({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    width: double.infinity,
    child: ColoredBox(color: color ?? PinPointTokens.of(context).rule),
  );
}
