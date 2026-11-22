part of 'controls.dart';

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
    final textColor = _textColor(tokens);
    final content = _content(tokens, textColor);
    return _Interactive(
      onTap: look == ChipLook.disabled ? null : onTap,
      button: onTap != null,
      builder: (context, hovered, pressed) {
        final padding = EdgeInsets.only(left: 8, right: _clearable ? 4 : 8);
        if (look == ChipLook.disabled) {
          return _disabledFrame(tokens, content, padding);
        }
        return _frame(tokens, content, padding, hovered: hovered);
      },
    );
  }

  bool get _clearable =>
      look == ChipLook.override ||
      (onClear != null && look != ChipLook.disabled);

  Color _textColor(PinPointTokens tokens) => switch (look) {
    ChipLook.selected => tokens.paper,
    ChipLook.override => tokens.editInk,
    ChipLook.disabled => tokens.faint,
    ChipLook.rest => tokens.ink,
  };

  Widget _content(PinPointTokens tokens, Color textColor) {
    final leading = look == ChipLook.selected ? PinPointIcons.check : icon;
    return Row(
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
        if (_clearable) ...[
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
  }

  Widget _disabledFrame(
    PinPointTokens tokens,
    Widget content,
    EdgeInsets padding,
  ) {
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

  Widget _frame(
    PinPointTokens tokens,
    Widget content,
    EdgeInsets padding, {
    required bool hovered,
  }) {
    final (:border, :width, :fill) = switch (look) {
      ChipLook.selected => (border: tokens.ink, width: 1.0, fill: tokens.ink),
      ChipLook.override => (
        border: tokens.edit,
        width: 1.5,
        fill: tokens.editBg,
      ),
      _ => (
        border: hovered ? tokens.ink : tokens.field,
        width: 1.0,
        fill: null,
      ),
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
    this.strike = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  /// Draws the label struck through, for a choice that is already taken.
  final bool strike;

  @override
  State<DraftCheckbox> createState() => _DraftCheckboxState();
}

class _DraftCheckboxState extends State<DraftCheckbox> {
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Semantics(
      checked: widget.value,
      enabled: _enabled,
      label: widget.label,
      excludeSemantics: true,
      onTap: _enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        onShowFocusHighlight: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? _toggle : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _box(tokens),
                const SizedBox(width: 6),
                Flexible(child: _label(tokens)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _box(PinPointTokens tokens) {
    final value = widget.value;
    final edge = _enabled ? tokens.ink : tokens.field;
    return Container(
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
    );
  }

  Widget _label(PinPointTokens tokens) {
    return Text(
      widget.label,
      style: tokens.body.copyWith(
        color: _enabled ? tokens.ink : tokens.faint,
        decoration: widget.strike ? TextDecoration.lineThrough : null,
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
