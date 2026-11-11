import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/controls.dart';
import '../theme/palette_store.dart';
import '../theme/pinpoint_tokens.dart';

/// The theme menu, opened from the rail's palette item: one row per palette
/// with its paper and accent swatches, a check on the current one, and a
/// footer that says the pick is saved.
///
/// Picking a row switches Pinpoint's palette (and saves it), then calls
/// [onClose]. Esc calls [onClose] too. It takes the focus while it is open,
/// so Esc reaches it even in idle, when the app has the focus.
class ThemeMenu extends StatefulWidget {
  const ThemeMenu({super.key, required this.palette, required this.onClose});

  static const Key buttonKey = ValueKey<String>('pinpoint.theme.button');
  static const Key menuKey = ValueKey<String>('pinpoint.theme.menu');

  /// The row of [palette].
  static Key rowKey(PinPointPalette palette) =>
      ValueKey<String>('pinpoint.theme.${palette.name}');

  static const double width = 220;

  /// The menu's height: header 26, three rows of 30, footer 28, and the 1 px
  /// border on each side.
  static const double height = 26 + 3 * 30 + 28 + 2;

  final PaletteController palette;
  final VoidCallback onClose;

  @override
  State<ThemeMenu> createState() => _ThemeMenuState();
}

class _ThemeMenuState extends State<ThemeMenu> {
  final FocusNode _focus = FocusNode(debugLabel: 'pinpoint theme menu');

  @override
  void initState() {
    super.initState();
    // Takes the focus once it is in the tree, so Esc reaches it. A plain
    // `autofocus` does nothing when the scope already has a focused node.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final palette = widget.palette;
    final onClose = widget.onClose;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        width: ThemeMenu.width,
        child: DraftSurface(
          key: ThemeMenu.menuKey,
          elevation: 2,
          child: ValueListenableBuilder<PinPointPalette>(
            valueListenable: palette,
            builder: (context, current, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 8, 10, 6),
                  child: CapsText('PINPOINT THEME'),
                ),
                for (final option in PinPointPalette.values)
                  _ThemeRow(
                    key: ThemeMenu.rowKey(option),
                    option: option,
                    current: option == current,
                    onTap: () {
                      palette.select(option);
                      onClose();
                    },
                  ),
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: tokens.ink)),
                  ),
                  child: Text('Saved for this project', style: tokens.micro),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeRow extends StatefulWidget {
  const _ThemeRow({
    super.key,
    required this.option,
    required this.current,
    required this.onTap,
  });

  final PinPointPalette option;
  final bool current;
  final VoidCallback onTap;

  @override
  State<_ThemeRow> createState() => _ThemeRowState();
}

class _ThemeRowState extends State<_ThemeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final swatches = widget.option.tokens;
    Widget swatch(Color color) => Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: tokens.ink),
      ),
    );
    return Semantics(
      button: true,
      selected: widget.current,
      label: widget.option.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: _hovered ? tokens.accentBg : null,
              border: Border(top: BorderSide(color: tokens.rule)),
            ),
            child: Row(
              children: [
                // Paper, then the accent over it, 8 px of it overlapped.
                SizedBox(
                  width: 20,
                  height: 14,
                  child: Stack(
                    children: [
                      Positioned(left: 0, child: swatch(swatches.paper)),
                      Positioned(left: 6, child: swatch(swatches.accent)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.option.label, style: tokens.body)),
                if (widget.current)
                  Icon(PinPointIcons.check, size: 16, color: tokens.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
