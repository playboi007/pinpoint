import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'marks.dart';
import 'pinpoint_tokens.dart';

// The shared controls of the Drafting design. Each one reads the colours from
// `PinPointTokens.of(context)`, so a palette switch restyles them. Radius is 0
// except where noted, nothing splashes, and hover or press is a plain fill.

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

// -- Buttons -----------------------------------------------------------------

/// A square icon button with no label. Hover fills it with `accentBg`.
class DraftIconButton extends StatelessWidget {
  const DraftIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.iconSize = 18,
    this.extent = 24,
    this.color,
  });

  final IconData icon;

  /// Null disables the button: faint icon, no hover.
  final VoidCallback? onPressed;
  final String? tooltip;
  final double iconSize;

  /// Width and height of the hit area.
  final double extent;

  /// Replaces the ink colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    Widget button = _Interactive(
      onTap: onPressed,
      semanticLabel: tooltip,
      builder: (context, hovered, pressed) => Container(
        width: extent,
        height: extent,
        alignment: Alignment.center,
        color: hovered || pressed ? tokens.accentBg : null,
        child: Icon(
          icon,
          size: iconSize,
          color: onPressed == null ? tokens.faint : color ?? tokens.ink,
        ),
      ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip, child: button);
    return button;
  }
}

enum _ButtonLook { primary, outline, link }

/// A 26 px text button in one of three looks.
///
/// * [DraftButton.primary]: accent fill, white medium text, ink border. When
///   disabled it loses the fill and gets faint text and a dashed `field`
///   border, so it never passes for [DraftButton.outline].
/// * [DraftButton.outline]: ink border, no fill.
/// * [DraftButton.link]: underlined text, no border.
///
/// [onPressed] null disables the button.
class DraftButton extends StatelessWidget {
  const DraftButton.primary({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  }) : _look = _ButtonLook.primary;

  const DraftButton.outline({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  }) : _look = _ButtonLook.outline;

  const DraftButton.link({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  }) : _look = _ButtonLook.link;

  final String label;
  final VoidCallback? onPressed;

  /// Shown before the label.
  final IconData? icon;
  final _ButtonLook _look;

  /// Height of every button.
  static const double height = 26;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final enabled = onPressed != null;
    return _Interactive(
      onTap: onPressed,
      builder: (context, hovered, pressed) {
        final active = hovered || pressed;
        final Color textColor;
        switch (_look) {
          case _ButtonLook.primary:
            textColor = enabled ? tokens.onAccent : tokens.faint;
          case _ButtonLook.outline:
            textColor = enabled ? tokens.ink : tokens.faint;
          case _ButtonLook.link:
            textColor = !enabled
                ? tokens.faint
                : active
                ? tokens.accentInk
                : tokens.ink;
        }
        var style = tokens.body.copyWith(color: textColor);
        if (_look == _ButtonLook.primary) {
          style = style.copyWith(fontWeight: FontWeight.w500);
        }
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: textColor),
              const SizedBox(width: 4),
            ],
            Text(label, style: style),
          ],
        );
        switch (_look) {
          case _ButtonLook.primary:
            const padding = EdgeInsets.symmetric(horizontal: 12);
            if (!enabled) {
              return SizedBox(
                height: height,
                child: DashedBox(
                  color: tokens.field,
                  child: Padding(
                    padding: padding,
                    child: Center(widthFactor: 1, child: content),
                  ),
                ),
              );
            }
            return Container(
              height: height,
              padding: padding,
              decoration: BoxDecoration(
                color: active ? tokens.accentInk : tokens.accent,
                border: Border.all(color: tokens.ink),
              ),
              child: Center(widthFactor: 1, child: content),
            );
          case _ButtonLook.outline:
            return Container(
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: active ? tokens.accentBg : null,
                border: Border.all(color: enabled ? tokens.ink : tokens.field),
              ),
              child: Center(widthFactor: 1, child: content),
            );
          case _ButtonLook.link:
            // The underline is a 1 px border under the line box, about 3 px
            // below the baseline: Flutter has no underline offset.
            return Container(
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(
                widthFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: textColor)),
                  ),
                  child: content,
                ),
              ),
            );
        }
      },
    );
  }
}

// -- Fields ------------------------------------------------------------------

/// How a field, stepper or colour field looks.
enum FieldState {
  /// 1 px `field` border, `input` fill.
  rest,

  /// 1 px `ink` border and a 2 px `accentBg` ring outside.
  focus,

  /// A value changed from the app's own: 1.5 px `edit` border, `editBg`
  /// fill, `editInk` text.
  tweaked,

  /// A bad value: 1.5 px `err` border.
  invalid,

  /// 1 px dashed `field` border, faint text, no fill.
  disabled,
}

/// The frame of a field: border, fill and ring for a [FieldState], 24 px high
/// by default and square. The child gets the value text style and a matching
/// icon colour, and is centred vertically, left aligned.
class DraftFieldFrame extends StatelessWidget {
  const DraftFieldFrame({
    super.key,
    required this.state,
    required this.child,
    this.height = PinPointSizes.controlHeight,
    this.padding = const EdgeInsets.symmetric(horizontal: 6),
  });

  final FieldState state;
  final Widget child;
  final double height;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final textColor = switch (state) {
      FieldState.tweaked => tokens.editInk,
      FieldState.disabled => tokens.faint,
      _ => tokens.ink,
    };
    final content = DefaultTextStyle.merge(
      style: tokens.value.copyWith(color: textColor),
      child: IconTheme.merge(
        data: IconThemeData(color: textColor, size: 16),
        child: Padding(
          padding: padding,
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ),
    );
    if (state == FieldState.disabled) {
      return SizedBox(
        height: height,
        child: DashedBox(color: tokens.field, child: content),
      );
    }
    final (Color border, double width, Color fill) = switch (state) {
      FieldState.focus => (tokens.ink, 1.0, tokens.input),
      FieldState.tweaked => (tokens.edit, 1.5, tokens.editBg),
      FieldState.invalid => (tokens.err, 1.5, tokens.input),
      _ => (tokens.field, 1.0, tokens.input),
    };
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: width),
        boxShadow: state == FieldState.focus
            ? [BoxShadow(spreadRadius: 2, color: tokens.accentBg)]
            : null,
      ),
      child: content,
    );
  }
}

/// `[− value +]`: two 22 px buttons around [value]. [value] is a widget so
/// the caller can put an editable field there. A null [onMinus] or [onPlus]
/// dims that button.
class DraftStepper extends StatelessWidget {
  const DraftStepper({
    super.key,
    required this.value,
    this.onMinus,
    this.onPlus,
    this.state = FieldState.rest,
    this.valueWidth = 36,
    this.minusKey,
    this.plusKey,
  });

  final Widget value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final FieldState state;
  final double valueWidth;

  /// Keys of the two buttons, for tests and for finding them.
  final Key? minusKey;
  final Key? plusKey;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final off = state == FieldState.disabled;
    // Rest buttons are muted; in the other states they follow the text.
    final glyph = state == FieldState.rest ? tokens.muted : null;
    return DraftFieldFrame(
      state: state,
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepButton(
            key: minusKey,
            glyph: '−',
            label: 'Decrease',
            color: glyph,
            onTap: off ? null : onMinus,
          ),
          SizedBox(
            width: valueWidth,
            child: Center(child: value),
          ),
          _StepButton(
            key: plusKey,
            glyph: '+',
            label: 'Increase',
            color: glyph,
            onTap: off ? null : onPlus,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.color,
  });

  final String glyph;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return _Interactive(
      onTap: onTap,
      semanticLabel: label,
      focusable: false,
      builder: (context, hovered, pressed) {
        final base = DefaultTextStyle.of(context).style;
        final tint = onTap == null ? tokens.faint : color;
        return Container(
          width: 22,
          alignment: Alignment.center,
          color: hovered || pressed ? tokens.accentBg : null,
          child: Text(
            glyph,
            style: tint == null ? base : base.copyWith(color: tint),
          ),
        );
      },
    );
  }
}

// -- Chips, checkbox, segmented ---------------------------------------------

/// How a [DraftChip] looks.
enum ChipLook {
  /// 1 px `field` border.
  rest,

  /// `ink` fill, paper text and a leading check.
  selected,

  /// An active what-if override: 1.5 px `edit` border, `editBg` fill, and a
  /// trailing close that resets it.
  override,

  /// 1 px dashed `field` border, faint text.
  disabled,
}

/// A 24 px chip with 2 px corners. Mono text by default; pass `mono: false`
/// for the body font (the intent chips).
class DraftChip extends StatelessWidget {
  const DraftChip({
    super.key,
    required this.label,
    this.icon,
    this.look = ChipLook.rest,
    this.onTap,
    this.onClear,
    this.mono = true,
    this.clearLabel = 'Reset',
  });

  final String label;

  /// Shown before the label. A selected chip shows a check instead.
  final IconData? icon;
  final ChipLook look;
  final VoidCallback? onTap;

  /// Called by the close button. An [ChipLook.override] chip always has one;
  /// another look, except [ChipLook.disabled], has one when this is set.
  final VoidCallback? onClear;
  final bool mono;

  /// What the close button is called for a screen reader: `Reset 1.3×` or,
  /// say, `Remove No overflow`.
  final String clearLabel;

  static const double _radius = 2;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final Color textColor = switch (look) {
      ChipLook.selected => tokens.paper,
      ChipLook.override => tokens.editInk,
      ChipLook.disabled => tokens.faint,
      ChipLook.rest => tokens.ink,
    };
    final leading = look == ChipLook.selected ? PinPointIcons.check : icon;
    final clearable =
        look == ChipLook.override ||
        (onClear != null && look != ChipLook.disabled);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[
          Icon(leading, size: 14, color: textColor),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: (mono ? tokens.value : tokens.body).copyWith(color: textColor),
        ),
        if (clearable) ...[
          const SizedBox(width: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClear,
            child: Semantics(
              button: true,
              label: '$clearLabel $label',
              child: Icon(PinPointIcons.close, size: 14, color: textColor),
            ),
          ),
        ],
      ],
    );
    return _Interactive(
      onTap: look == ChipLook.disabled ? null : onTap,
      button: onTap != null,
      builder: (context, hovered, pressed) {
        final padding = EdgeInsets.only(left: 8, right: clearable ? 4 : 8);
        if (look == ChipLook.disabled) {
          return SizedBox(
            height: PinPointSizes.controlHeight,
            child: DashedBox(
              color: tokens.field,
              radius: _radius,
              child: Padding(
                padding: padding,
                child: Center(widthFactor: 1, child: content),
              ),
            ),
          );
        }
        final (Color border, double width, Color? fill) = switch (look) {
          ChipLook.selected => (tokens.ink, 1.0, tokens.ink),
          ChipLook.override => (tokens.edit, 1.5, tokens.editBg),
          _ => (hovered ? tokens.ink : tokens.field, 1.0, null),
        };
        return Container(
          height: PinPointSizes.controlHeight,
          padding: padding,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: border, width: width),
          ),
          // The chip takes its content's width, as the disabled one does.
          child: Center(widthFactor: 1, child: content),
        );
      },
    );
  }
}

/// A 14 px square checkbox with a label. On: ink fill and a paper check.
/// [onChanged] null disables it. An enabled one takes keyboard focus; Enter
/// or Space toggles it, and a ring shows around the box.
class DraftCheckbox extends StatefulWidget {
  const DraftCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  State<DraftCheckbox> createState() => _DraftCheckboxState();
}

class _DraftCheckboxState extends State<DraftCheckbox> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final enabled = widget.onChanged != null;
    final value = widget.value;
    final edge = enabled ? tokens.ink : tokens.field;
    void toggle() => widget.onChanged?.call(!value);
    return Semantics(
      checked: value,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      onTap: enabled ? toggle : null,
      child: FocusableActionDetector(
        enabled: enabled,
        onShowFocusHighlight: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              toggle();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? toggle : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value ? edge : tokens.input,
                    border: Border.all(color: edge, width: 1.5),
                    boxShadow: _focused
                        ? [BoxShadow(spreadRadius: 2, color: tokens.accent)]
                        : null,
                  ),
                  child: value
                      ? Icon(PinPointIcons.check, size: 11, color: tokens.paper)
                      : null,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.label,
                    style: tokens.body.copyWith(
                      color: enabled ? tokens.ink : tokens.faint,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of cells with one active: 1 px ink border and separators, the
/// active cell in ink with paper text. [items] pairs each value with its
/// label.
class DraftSegmented<T> extends StatelessWidget {
  const DraftSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.cellWidth = 28,
    this.cellKey,
  });

  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double cellWidth;

  /// The key of the cell of a value, if any.
  final Key? Function(T value)? cellKey;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Container(
      height: PinPointSizes.controlHeight,
      decoration: BoxDecoration(border: Border.all(color: tokens.ink)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: 1, child: ColoredBox(color: tokens.ink)),
            _SegmentCell(
              key: cellKey?.call(items[i].$1),
              label: items[i].$2,
              width: cellWidth,
              active: items[i].$1 == value,
              onTap: () => onChanged(items[i].$1),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentCell extends StatelessWidget {
  const _SegmentCell({
    super.key,
    required this.label,
    required this.width,
    required this.active,
    required this.onTap,
  });

  final String label;
  final double width;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return _Interactive(
      onTap: onTap,
      builder: (context, hovered, pressed) => Semantics(
        selected: active,
        child: Container(
          width: width,
          alignment: Alignment.center,
          color: active
              ? tokens.ink
              : hovered || pressed
              ? tokens.accentBg
              : null,
          child: Text(
            label,
            style: tokens.value.copyWith(
              color: active ? tokens.paper : tokens.ink,
            ),
          ),
        ),
      ),
    );
  }
}

// -- Badges ------------------------------------------------------------------

/// A 14 px ink pill with a count in paper micro text.
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Container(
      height: 14,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      color: tokens.ink,
      child: Text('$count', style: tokens.micro.copyWith(color: tokens.paper)),
    );
  }
}

/// The severity of a finding, for [SeverityBadge].
enum PinPointSeverityLook { error, warn, info }

/// An 18 px badge: tinted fill, 1 px border, icon and `ERROR`, `WARN` or
/// `INFO`.
class SeverityBadge extends StatelessWidget {
  const SeverityBadge(this.look, {super.key});

  final PinPointSeverityLook look;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final (
      Color color,
      Color fill,
      IconData icon,
      String text,
    ) = switch (look) {
      PinPointSeverityLook.error => (
        tokens.err,
        tokens.errBg,
        PinPointIcons.error,
        'ERROR',
      ),
      PinPointSeverityLook.warn => (
        tokens.warn,
        tokens.warnBg,
        PinPointIcons.warning,
        'WARN',
      ),
      PinPointSeverityLook.info => (
        tokens.info,
        tokens.infoBg,
        PinPointIcons.info,
        'INFO',
      ),
    };
    return Container(
      height: 18,
      padding: const EdgeInsets.only(left: 3, right: 6),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(text, style: tokens.caps.copyWith(color: color)),
        ],
      ),
    );
  }
}

enum _SystemBadgeKind { bridgeOffline, frozen }

/// A 22 px badge for a state of the whole tool.
///
/// [SystemBadge.bridgeOffline]: dashed ink border, link-off icon. The
/// optional detail (why it is offline) shows as a tooltip.
/// [SystemBadge.frozen]: ink fill, snowflake icon.
class SystemBadge extends StatelessWidget {
  const SystemBadge.bridgeOffline({super.key, this.detail})
    : _kind = _SystemBadgeKind.bridgeOffline;

  const SystemBadge.frozen({super.key})
    : detail = null,
      _kind = _SystemBadgeKind.frozen;

  /// More text for a tooltip. Only [SystemBadge.bridgeOffline] has it.
  final String? detail;
  final _SystemBadgeKind _kind;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final offline = _kind == _SystemBadgeKind.bridgeOffline;
    final color = offline ? tokens.ink : tokens.paper;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            offline ? PinPointIcons.linkOff : PinPointIcons.acUnit,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            offline ? 'BRIDGE OFFLINE' : 'FROZEN',
            style: tokens.caps.copyWith(color: color),
          ),
        ],
      ),
    );
    Widget badge = SizedBox(
      height: 22,
      child: offline
          ? DashedBox(
              color: tokens.ink,
              fill: tokens.paper,
              child: Center(widthFactor: 1, child: content),
            )
          : ColoredBox(
              color: tokens.ink,
              child: Center(widthFactor: 1, child: content),
            ),
    );
    if (detail != null) badge = Tooltip(message: detail, child: badge);
    return badge;
  }
}

// -- Text and progress -------------------------------------------------------

/// One line of text that, when it does not fit, drops characters from the
/// start and shows `…` first, so the end stays visible:
/// `…/presentation/dashboard_panels.dart:652`. It prefers to cut at a `/`.
/// The default style is the value style.
class StartEllipsisText extends StatelessWidget {
  const StartEllipsisText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final effective = style ?? PinPointTokens.of(context).value;
    final resolved = DefaultTextStyle.of(context).style.merge(effective);
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shown = _fit(
            text,
            resolved,
            direction,
            scaler,
            constraints.maxWidth,
          );
          return Text(
            shown,
            style: effective,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          );
        },
      ),
    );
  }

  /// [text], or `…` and its tail, whichever fits [maxWidth].
  static String _fit(
    String text,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
    double maxWidth,
  ) {
    if (!maxWidth.isFinite) return text;
    bool fits(String candidate) {
      final painter = TextPainter(
        text: TextSpan(text: candidate, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width <= maxWidth;
    }

    if (fits(text)) return text;
    // The fewest characters to drop. Dropping all of them (just `…`) is the
    // floor: nothing shorter exists.
    var low = 1;
    var high = text.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (fits('…${text.substring(mid)}')) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    final drop = low;
    // Start the tail at the next `/`, when there is one, so no folder name is
    // cut in half.
    final slash = text.indexOf('/', drop);
    if (slash != -1 && slash < text.length - 1) {
      return '…${text.substring(slash)}';
    }
    return '…${text.substring(drop)}';
  }
}

/// A 14 px ring spinner: a `rule` ring with an `ink` arc turning on it. Only
/// a mounted spinner draws frames, so show it only while something loads.
class DraftSpinner extends StatefulWidget {
  const DraftSpinner({super.key});

  @override
  State<DraftSpinner> createState() => _DraftSpinnerState();
}

class _DraftSpinnerState extends State<DraftSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Semantics(
      label: 'Loading',
      child: SizedBox.square(
        dimension: 14,
        child: CustomPaint(
          painter: _SpinnerPainter(
            turn: _turn,
            ring: tokens.rule,
            arc: tokens.ink,
          ),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turn, required this.ring, required this.arc})
    : super(repaint: turn);

  final Animation<double> turn;
  final Color ring;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 2.0;
    final oval = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = ring;
    canvas.drawOval(oval, paint);
    paint.color = arc;
    // A quarter of the ring, centred on the top, then turned.
    const quarter = 3.141592653589793 / 2;
    canvas.drawArc(
      oval,
      -quarter * 1.5 + turn.value * 2 * 3.141592653589793,
      quarter,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.ring != ring || old.arc != arc;
}
