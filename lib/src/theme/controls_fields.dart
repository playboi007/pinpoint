part of 'controls.dart';

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
