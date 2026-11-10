import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pinpoint_controller.dart';
import '../info/widget_info.dart';
import '../model/annotation.dart';
import '../search/pick_result.dart';
import 'comment_form.dart';
import 'highlight_painter.dart';
import 'note_view.dart';
import 'panel_keys.dart';

/// Space kept between the panel and the viewport's edges.
const double panelMargin = 12;

/// Space between the panel and the widget it describes.
const double panelGap = 8;

/// The panel's width in a viewport [viewportWidth] wide: [InfoPanel.width],
/// or less where that would not fit between the margins.
double panelWidthFor(double viewportWidth) {
  final room = viewportWidth - 2 * panelMargin;
  if (room <= 0) return 0;
  return room < InfoPanel.width ? room : InfoPanel.width;
}

/// The top-left of a [panel] that describes [target], inside [viewport].
///
/// Below the target when it fits, then above, then to the right, then to
/// the left. When no side fits, the side with the most room, pushed back
/// inside: the panel then covers as little of the target as it can, so the
/// outline stays visible and the target can still be clicked. Every result
/// keeps [panelMargin] to each edge of the viewport, unless the panel is
/// larger than the space.
///
/// All three are in one coordinate space (engineering rule 7).
Offset placePanel(Rect target, Size panel, Size viewport) {
  if (!target.isFinite) {
    return clampPanel(Offset(viewport.width, 0), panel, viewport);
  }
  final below = target.bottom + panelGap;
  final above = target.top - panelGap - panel.height;
  final right = target.right + panelGap;
  final left = target.left - panelGap - panel.width;
  // How far each side's panel would reach past the margin, in plan order.
  // Zero or less means it fits.
  final sides = <(double, Offset)>[
    (
      below + panel.height - (viewport.height - panelMargin),
      Offset(target.left, below),
    ),
    (panelMargin - above, Offset(target.left, above)),
    (
      right + panel.width - (viewport.width - panelMargin),
      Offset(right, target.top),
    ),
    (panelMargin - left, Offset(left, target.top)),
  ];
  var best = sides.first;
  for (final side in sides) {
    if (side.$1 <= 0) {
      best = side;
      break;
    }
    if (side.$1 < best.$1) best = side;
  }
  return clampPanel(best.$2, panel, viewport);
}

/// [position] moved the least distance that keeps a [panel] there inside
/// [viewport] with [panelMargin] to each edge. A panel larger than the space
/// sits at the top-left margin.
Offset clampPanel(Offset position, Size panel, Size viewport) {
  double clampAxis(double value, double size, double extent) {
    final max = extent - panelMargin - size;
    if (max <= panelMargin || value.isNaN) return panelMargin;
    return value.clamp(panelMargin, max);
  }

  return Offset(
    clampAxis(position.dx, panel.width, viewport.width),
    clampAxis(position.dy, panel.height, viewport.height),
  );
}

/// Ctrl or Cmd and Enter in the panel.
class _SendIntent extends Intent {
  const _SendIntent();
}

/// Sends the comment. Off unless a comment is typed in commenting mode,
/// and while an input method composes: then Enter commits the composition,
/// so the shortcut must not cut it off.
class _SendAction extends Action<_SendIntent> {
  _SendAction({required this.controller, required this.onSend});

  final PinPointController controller;
  final VoidCallback onSend;

  @override
  bool isEnabled(_SendIntent intent) =>
      controller.mode == PinPointMode.commenting &&
      controller.draft.hasText &&
      !controller.draft.composing;

  @override
  Object? invoke(_SendIntent intent) {
    onSend();
    return null;
  }
}

/// Which tab of the [InfoPanel] shows.
enum PanelTab { info, comment }

/// The crumbs to show for [pick]: the selected entry of its chain with up
/// to [around] local entries above and below it, outermost first, and
/// whether more exist beyond each end.
({List<int> indices, bool moreAbove, bool moreBelow}) crumbsFor(
  PickResult pick, {
  int around = 3,
}) {
  final chain = pick.chain;
  final above = <int>[];
  int? i = chain.nextLocal(pick.chainIndex, up: true);
  for (; i != null && above.length < around; i = chain.nextLocal(i, up: true)) {
    above.add(i);
  }
  final moreAbove = i != null;
  final below = <int>[];
  int? j = chain.nextLocal(pick.chainIndex, up: false);
  for (
    ;
    j != null && below.length < around;
    j = chain.nextLocal(j, up: false)
  ) {
    below.add(j);
  }
  return (
    indices: [...above.reversed, pick.chainIndex, ...below],
    moreAbove: moreAbove,
    moreBelow: j != null,
  );
}

/// Covers the screen and places [InfoPanel] while there is a selection.
///
/// Only the panel takes pointer events; the rest of the area lets them
/// through to the trap.
class InfoPanelLayer extends StatelessWidget {
  const InfoPanelLayer({
    super.key,
    required this.controller,
    required this.tab,
    required this.commentFocus,
    required this.onSend,
    required this.onSaveDraft,
    required this.onCopy,
    required this.noteActions,
  });

  final PinPointController controller;
  final ValueNotifier<PanelTab> tab;
  final FocusNode commentFocus;
  final VoidCallback onSend;
  final VoidCallback onSaveDraft;
  final VoidCallback onCopy;
  final NoteActions noteActions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.selection,
        tab,
        controller.openNote,
        controller.notes,
      ]),
      builder: (context, _) {
        final selection = controller.selection.value;
        if (selection == null) return const SizedBox.shrink();
        final openId = controller.openNote.value;
        final note = openId == null ? null : controller.notes.byId(openId);
        return _PanelPlacement(
          controller: controller,
          selection: selection,
          panel: (onDrag) => InfoPanel(
            selection: selection,
            controller: controller,
            tab: tab.value,
            onTab: (value) => tab.value = value,
            commentFocus: commentFocus,
            onSend: onSend,
            onSaveDraft: onSaveDraft,
            onCopy: onCopy,
            onClose: controller.clearSelection,
            onDrag: onDrag,
            note: note,
            noteNumber: note == null
                ? null
                : controller.notes.numberOf(note.id),
            drafts: controller.notes.drafts.length,
            noteActions: noteActions,
          ),
        );
      },
    );
  }
}

class _PanelPlacement extends StatefulWidget {
  const _PanelPlacement({
    required this.controller,
    required this.selection,
    required this.panel,
  });

  final PinPointController controller;
  final PickResult selection;

  /// Builds the panel, given what a drag on its header does.
  final InfoPanel Function(ValueChanged<Offset> onDrag) panel;

  @override
  State<_PanelPlacement> createState() => _PanelPlacementState();
}

class _PanelPlacementState extends State<_PanelPlacement> {
  /// The panel's box, read when a drag starts from the placed position.
  final GlobalKey _box = GlobalKey(debugLabel: 'pinpoint panel box');

  void _drag(Offset delta) {
    final box = _box.currentContext?.findRenderObject();
    final area = context.findRenderObject();
    if (box is! RenderBox || area is! RenderBox) return;
    if (!box.hasSize || !area.hasSize) return;
    // Several updates can arrive before the next layout, so add to the
    // stored position, not to the one the last layout used.
    final from =
        widget.controller.panelPosition ??
        box.localToGlobal(Offset.zero, ancestor: area);
    setState(() {
      widget.controller.panelPosition = clampPanel(
        from + delta,
        box.size,
        area.size,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => CustomSingleChildLayout(
        delegate: _PanelLayout(
          // The layer covers PinPointWrapper from its top-left, and the
          // wrapper sits at the view's origin in MaterialApp.builder, so a
          // global rect is a rect in this layer too (engineering rule 7).
          target: widget.selection.globalRect,
          dragged: widget.controller.panelPosition,
          width: panelWidthFor(constraints.maxWidth),
        ),
        child: KeyedSubtree(key: _box, child: widget.panel(_drag)),
      ),
    );
  }
}

/// Lays the panel out at its own height, then places it next to the target
/// with [placePanel], or where it was dragged. Clamped on every layout, so a
/// window resize or a taller tab never pushes it off screen.
class _PanelLayout extends SingleChildLayoutDelegate {
  _PanelLayout({
    required this.target,
    required this.dragged,
    required this.width,
  });

  final Rect target;
  final Offset? dragged;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final height = constraints.maxHeight - 2 * panelMargin;
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: height > 0 ? height : 0,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final at = dragged;
    return at == null
        ? placePanel(target, childSize, size)
        : clampPanel(at, childSize, size);
  }

  @override
  bool shouldRelayout(_PanelLayout oldDelegate) =>
      target != oldDelegate.target ||
      dragged != oldDelegate.dragged ||
      width != oldDelegate.width;
}

/// A card for the selected widget: header, breadcrumb, then the Info tab
/// (its [WidgetInfo]) or the Comment tab ([CommentForm]).
///
/// Milestone 11 adds a Tweak tab.
class InfoPanel extends StatelessWidget {
  const InfoPanel({
    super.key = panelKey,
    required this.selection,
    required this.controller,
    required this.tab,
    required this.onTab,
    required this.commentFocus,
    required this.onSend,
    this.onSaveDraft,
    required this.onCopy,
    required this.onClose,
    this.onDrag,
    this.note,
    this.noteNumber,
    this.drafts = 0,
    this.noteActions,
  });

  static const Key panelKey = ValueKey<String>('pinpoint.infoPanel');
  static const Key headerKey = ValueKey<String>('pinpoint.infoPanel.header');
  static const Key crumbsKey = ValueKey<String>('pinpoint.infoPanel.crumbs');
  static const Key infoTabKey = ValueKey<String>('pinpoint.infoPanel.info');
  static const Key commentTabKey = ValueKey<String>(
    'pinpoint.infoPanel.comment',
  );

  /// The widest the panel gets; narrower in a small viewport
  /// ([panelWidthFor]).
  static const double width = 360;
  static const double headerHeight = 48;

  final PickResult selection;
  final PinPointController controller;
  final PanelTab tab;
  final ValueChanged<PanelTab> onTab;
  final FocusNode commentFocus;
  final VoidCallback onSend;
  final VoidCallback? onSaveDraft;
  final VoidCallback onCopy;
  final VoidCallback onClose;
  final ValueChanged<Offset>? onDrag;

  /// The pinned note to show instead of the comment form, after a click
  /// on its pin.
  final Annotation? note;

  /// [note]'s pin number.
  final int? noteNumber;

  /// How many drafts there are.
  final int drafts;

  /// What [note]'s buttons do. Required with [note].
  final NoteActions? noteActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Plus Ctrl or Cmd and Enter to send.
    return PanelKeyScope(
      shortcuts: {
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
        ]) ...{
          SingleActivator(key, control: true): const _SendIntent(),
          SingleActivator(key, meta: true): const _SendIntent(),
        },
      },
      actions: {
        _SendIntent: _SendAction(controller: controller, onSend: onSend),
      },
      child: _card(theme),
    );
  }

  Widget _card(ThemeData theme) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: headerKey,
            // Count the movement from pointer down, so the panel stays
            // under the pointer instead of lagging by the touch slop.
            dragStartBehavior: DragStartBehavior.down,
            onPanUpdate: onDrag == null
                ? null
                : (details) => onDrag!(details.delta),
            child: _Header(selection: selection, onClose: onClose),
          ),
          _Crumbs(selection: selection, onSelect: controller.selectChainIndex),
          _Tabs(
            tab: tab,
            onTab: onTab,
            commentLabel: note == null
                ? 'Comment'
                : noteNumber == null
                ? 'Note'
                : 'Note $noteNumber',
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: switch (tab) {
                PanelTab.info => _info(theme),
                PanelTab.comment when note != null && noteActions != null =>
                  NoteView(
                    note: note!,
                    number: noteNumber,
                    drafts: drafts,
                    focusNode: commentFocus,
                    actions: noteActions!,
                  ),
                PanelTab.comment => CommentForm(
                  controller: controller,
                  focusNode: commentFocus,
                  onSend: onSend,
                  onSaveDraft: onSaveDraft,
                  onCopy: onCopy,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(ThemeData theme) {
    final WidgetInfo info;
    try {
      info = WidgetInfo.fromRenderObject(selection.renderObject);
    } catch (_) {
      // The tracker clears a selection whose element is gone after the next
      // frame; until then there is nothing to read.
      return const SizedBox.shrink();
    }
    return _InfoContent(info: info, theme: theme);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.selection, required this.onClose});

  final PickResult selection;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Container(
        height: InfoPanel.headerHeight,
        color: theme.colorScheme.surfaceContainerHigh,
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selection.entry.name,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    locationLabel(selection) ?? 'source unavailable',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'Click the same spot again for the next widget',
              child: Text(
                '${selection.index + 1} of ${selection.candidates.length}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: 'Close panel',
              iconSize: 18,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

/// The local chain around the selection, outermost first. A click on a
/// crumb selects that widget.
class _Crumbs extends StatelessWidget {
  const _Crumbs({required this.selection, required this.onSelect});

  final PickResult selection;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = crumbsFor(selection);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget separator() => Text(' > ', style: muted);
    return Padding(
      key: InfoPanel.crumbsKey,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (crumbs.moreAbove) ...[Text('…', style: muted), separator()],
          for (final (n, index) in crumbs.indices.indexed) ...[
            if (n > 0) separator(),
            _Crumb(
              name: selection.chain[index].name,
              selected: index == selection.chainIndex,
              onTap: () => onSelect(index),
            ),
          ],
          if (crumbs.moreBelow) ...[separator(), Text('…', style: muted)],
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
    );
    return InkWell(
      onTap: selected ? null : onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(name, style: style),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.tab,
    required this.onTab,
    required this.commentLabel,
  });

  final PanelTab tab;
  final ValueChanged<PanelTab> onTab;
  final String commentLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TabButton(
          key: InfoPanel.infoTabKey,
          label: 'Info',
          selected: tab == PanelTab.info,
          onTap: () => onTab(PanelTab.info),
        ),
        _TabButton(
          key: InfoPanel.commentTabKey,
          label: commentLabel,
          selected: tab == PanelTab.comment,
          onTap: () => onTab(PanelTab.comment),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? color : theme.dividerColor,
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

class _InfoContent extends StatelessWidget {
  const _InfoContent({required this.info, required this.theme});

  final WidgetInfo info;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final title = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(name: 'render', label: info.renderType),
        _Row(name: 'size', label: info.sizeLabel),
        _Row(name: 'position', label: info.positionLabel),
        _Row(name: 'constraints', label: info.constraintsLabel),
        _Row(name: 'depth', label: '${info.depth}'),
        for (final section in info.sections) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(section.title, style: title),
          ),
          for (final property in section.properties)
            _Row(name: property.name, label: property.label),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.name, required this.label});

  final String name;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
