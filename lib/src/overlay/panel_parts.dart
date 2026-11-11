import 'package:flutter/material.dart';

import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';

// Pieces the Info and Tweak tabs share: a numbered section and a label row.

/// Width of the label column of a [PanelRow].
const double panelLabelWidth = 72;

/// `02 PADDING`: [number] with a leading zero, then [title] in capitals.
String sectionHeading(int number, String title) =>
    '${number.toString().padLeft(2, '0')} ${title.toUpperCase()}';

/// A numbered section of a panel body: a caps heading, then [children] 6 px
/// apart. Every section but the [first] has a 1 px `rule` above it and 10 px
/// of padding under that rule.
///
/// A [modified] section shows `● MODIFIED` in the `edit` colour. With
/// [onReset] it also shows a `restart_alt` button at the right.
class PanelSection extends StatelessWidget {
  const PanelSection({
    super.key,
    required this.heading,
    required this.children,
    this.detail,
    this.first = false,
    this.modified = false,
    this.onReset,
    this.resetKey,
    this.resetTooltip = 'Reset',
  });

  /// The caps text, for example `02 PADDING` ([sectionHeading]).
  final String heading;

  /// Muted micro text after the heading, cut with an ellipsis.
  final String? detail;

  final List<Widget> children;

  /// No rule above: the section is the first of the body.
  final bool first;

  final bool modified;

  /// Null hides the reset button.
  final VoidCallback? onReset;

  /// The key of the reset button.
  final Key? resetKey;

  final String resetTooltip;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Container(
      padding: first ? EdgeInsets.zero : const EdgeInsets.only(top: 10),
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: tokens.rule)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 18,
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      CapsText(heading),
                      if (detail != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            detail!,
                            style: tokens.micro,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      if (modified) ...[
                        const SizedBox(width: 6),
                        CapsText('● MODIFIED', color: tokens.edit),
                      ],
                    ],
                  ),
                ),
                if (onReset != null)
                  DraftIconButton(
                    key: resetKey,
                    icon: PinPointIcons.restartAlt,
                    iconSize: 14,
                    extent: 18,
                    tooltip: resetTooltip,
                    onPressed: onReset,
                  ),
              ],
            ),
          ),
          for (final child in children) ...[const SizedBox(height: 6), child],
        ],
      ),
    );
  }
}

/// A property name in a 72 px muted column, and its [child] beside it.
class PanelRow extends StatelessWidget {
  const PanelRow({
    super.key,
    required this.name,
    required this.child,
    this.nameColor,
    this.nameWeight,
    this.nameInset = 0,
  });

  final String name;
  final Widget child;

  /// Replaces the muted colour of the name.
  final Color? nameColor;

  final FontWeight? nameWeight;

  /// Space above the name, to line it up with a 24 px control.
  final double nameInset;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    var style = tokens.label;
    if (nameColor != null) style = style.copyWith(color: nameColor);
    if (nameWeight != null) style = style.copyWith(fontWeight: nameWeight);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: panelLabelWidth,
          child: Padding(
            padding: EdgeInsets.only(top: nameInset),
            child: Text(
              name,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
