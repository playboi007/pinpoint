part of 'controls.dart';

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

  bool get _enabled => onPressed != null;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return _Interactive(
      onTap: onPressed,
      builder: (context, hovered, pressed) {
        final active = hovered || pressed;
        final textColor = _textColor(tokens, active: active);
        final content = _content(tokens, textColor);
        return switch (_look) {
          _ButtonLook.primary => _primaryFrame(tokens, content, active: active),
          _ButtonLook.outline => _outlineFrame(tokens, content, active: active),
          _ButtonLook.link => _linkFrame(content, textColor),
        };
      },
    );
  }

  Color _textColor(PinPointTokens tokens, {required bool active}) {
    if (!_enabled) return tokens.faint;
    return switch (_look) {
      _ButtonLook.primary => tokens.onAccent,
      _ButtonLook.outline => tokens.ink,
      _ButtonLook.link => active ? tokens.accentInk : tokens.ink,
    };
  }

  Widget _content(PinPointTokens tokens, Color textColor) {
    var style = tokens.body.copyWith(color: textColor);
    if (_look == _ButtonLook.primary) {
      style = style.copyWith(fontWeight: FontWeight.w500);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: textColor),
          const SizedBox(width: 4),
        ],
        Text(label, style: style),
      ],
    );
  }

  Widget _primaryFrame(
    PinPointTokens tokens,
    Widget content, {
    required bool active,
  }) {
    const padding = EdgeInsets.symmetric(horizontal: 12);
    if (!_enabled) {
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
  }

  Widget _outlineFrame(
    PinPointTokens tokens,
    Widget content, {
    required bool active,
  }) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? tokens.accentBg : null,
        border: Border.all(color: _enabled ? tokens.ink : tokens.field),
      ),
      child: Center(widthFactor: 1, child: content),
    );
  }

  // The underline is a 1 px border under the line box, about 3 px below the
  // baseline: Flutter has no underline offset.
  Widget _linkFrame(Widget content, Color textColor) {
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
}
