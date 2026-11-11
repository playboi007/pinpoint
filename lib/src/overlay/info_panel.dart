import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pinpoint_controller.dart';
import '../info/widget_info.dart';
import '../model/annotation.dart';
import '../search/pick_result.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import 'comment_form.dart';
import 'highlight_painter.dart';
import 'note_view.dart';
import 'panel_keys.dart';
import 'panel_parts.dart';
import 'tweak_panel.dart';

/// Space kept between the panel and the left and right edges of the viewport.
const double panelMarginX = 8;

/// Space kept between the panel and the top and bottom edges of the viewport.
const double panelMarginY = 12;

/// Space between the panel and the widget it describes.
const double panelGap = 8;

/// The panel's width in a viewport [viewportWidth] wide: [InfoPanel.width],
/// or less where that would not fit between the margins
/// (`min(360, viewport - 16)`).
double panelWidthFor(double viewportWidth) {
  final room = viewportWidth - 2 * panelMarginX;
  if (room <= 0) return 0;
  return room < InfoPanel.width ? room : InfoPanel.width;
}

/// The top-left of a [panel] that describes [target], inside [viewport].
///
/// Below the target when it fits, then above, then to the right, then to
/// the left. When no side fits, the side with the most room, pushed back
/// inside: the panel then covers as little of the target as it can, so the
/// outline stays visible and the target can still be clicked. Every result
/// keeps [panelMarginX] to the left and right edges of the viewport and
/// [panelMarginY] to the top and bottom ones, unless the panel is larger than
/// the space.
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
      below + panel.height - (viewport.height - panelMarginY),
      Offset(target.left, below),
    ),
    (panelMarginY - above, Offset(target.left, above)),
    (
      right + panel.width - (viewport.width - panelMarginX),
      Offset(right, target.top),
    ),
    (panelMarginX - left, Offset(left, target.top)),
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
/// [viewport] with [panelMarginX] and [panelMarginY] to the edges. A panel
/// larger than the space sits at the top-left margin.
Offset clampPanel(Offset position, Size panel, Size viewport) {
  double clampAxis(double value, double size, double extent, double margin) {
    final max = extent - margin - size;
    if (max <= margin || value.isNaN) return margin;
    return value.clamp(margin, max);
  }

  return Offset(
    clampAxis(position.dx, panel.width, viewport.width, panelMarginX),
    clampAxis(position.dy, panel.height, viewport.height, panelMarginY),
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
enum PanelTab { info, tweak, comment }

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
    required this.onTweak,
    this.rightInset = 0,
  });

  final PinPointController controller;
  final ValueNotifier<PanelTab> tab;
  final FocusNode commentFocus;
  final VoidCallback onSend;
  final VoidCallback onSaveDraft;
  final VoidCallback onCopy;
  final NoteActions noteActions;
  final TweakApply onTweak;

  /// Space at the right edge the panel never covers: the rail sits there,
  /// drawn above the panel. The panel is placed and dragged in the rest.
  final double rightInset;

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
        // Padding on the right only keeps the layer's origin at the
        // wrapper's, so global rects stay valid (engineering rule 7).
        return Padding(
          padding: EdgeInsets.only(right: rightInset),
          child: _PanelPlacement(
            controller: controller,
            selection: selection,
            panel: (onDrag, keepPlace) => InfoPanel(
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
              // A tweak can move the widget; the panel stays where it is.
              onTweak: (target, property, value) {
                keepPlace();
                return onTweak(target, property, value);
              },
            ),
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

  /// Builds the panel, given what a drag on its header does and what keeps
  /// it where it is now.
  final InfoPanel Function(ValueChanged<Offset> onDrag, VoidCallback keepPlace)
  panel;

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

  /// Pins the panel where it is now, as a drag of zero would: a tweak that
  /// changes layout can move the selected widget, and the panel placed next
  /// to it would jump. The highlight follows the widget; the panel stays
  /// where the user had it.
  void _keepPlace() {
    if (widget.controller.panelPosition != null) return;
    final box = _box.currentContext?.findRenderObject();
    final area = context.findRenderObject();
    if (box is! RenderBox || area is! RenderBox) return;
    if (!box.hasSize || !area.hasSize) return;
    widget.controller.panelPosition = box.localToGlobal(
      Offset.zero,
      ancestor: area,
    );
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
        child: KeyedSubtree(key: _box, child: widget.panel(_drag, _keepPlace)),
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
    final height = constraints.maxHeight - 2 * panelMarginY;
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

/// A card for the selected widget: header, breadcrumb, tabs, then the Info
/// tab (its [WidgetInfo]), the Tweak tab ([TweakTab]) or the Comment tab
/// ([CommentForm]). The Tweak and Comment tabs keep their footer under the
/// scrolling body.
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
    this.onTweak,
  });

  static const Key panelKey = ValueKey<String>('pinpoint.infoPanel');
  static const Key headerKey = ValueKey<String>('pinpoint.infoPanel.header');
  static const Key crumbsKey = ValueKey<String>('pinpoint.infoPanel.crumbs');
  static const Key infoTabKey = ValueKey<String>('pinpoint.infoPanel.info');
  static const Key commentTabKey = ValueKey<String>(
    'pinpoint.infoPanel.comment',
  );
  static const Key tweakTabKey = ValueKey<String>('pinpoint.infoPanel.tweak');

  /// The `unfold_more` button in the header: the next widget under the spot.
  static const Key nextCandidateKey = ValueKey<String>(
    'pinpoint.infoPanel.nextCandidate',
  );

  /// The widest the panel gets; narrower in a small viewport
  /// ([panelWidthFor]).
  static const double width = PinPointSizes.panelWidth;
  static const double headerHeight = PinPointSizes.panelHeader;

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

  /// Applies a tweak. Without it the Tweak tab edits through the
  /// controller's session directly.
  final TweakApply? onTweak;

  @override
  Widget build(BuildContext context) {
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
      child: _card(),
    );
  }

  Widget _card() {
    final showsNote = tab == PanelTab.comment && note != null;
    final Widget? footer = switch (tab) {
      PanelTab.tweak => TweakFooter(session: controller.tweaks),
      PanelTab.comment when !showsNote || noteActions == null => CommentFooter(
        controller: controller,
        onSend: onSend,
        onSaveDraft: onSaveDraft,
        onCopy: onCopy,
      ),
      _ => null,
    };
    // A Material for the text fields and menus inside, and the default text
    // style: it adds no fill, elevation or splash.
    return Material(
      type: MaterialType.transparency,
      child: DraftSurface(
        elevation: 3,
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
              child: _Header(
                selection: selection,
                onClose: onClose,
                onNextCandidate: controller.selectNextCandidate,
              ),
            ),
            _Crumbs(
              selection: selection,
              onSelect: controller.selectChainIndex,
            ),
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
                padding: const EdgeInsets.all(PinPointSizes.panelPadding),
                child: switch (tab) {
                  PanelTab.info => _info(),
                  PanelTab.tweak => TweakTab(
                    selection: selection,
                    session: controller.tweaks,
                    onApply: onTweak ?? controller.tweaks.apply,
                  ),
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
                  ),
                },
              ),
            ),
            ?footer,
          ],
        ),
      ),
    );
  }

  Widget _info() {
    final WidgetInfo info;
    try {
      info = WidgetInfo.fromRenderObject(selection.renderObject);
    } catch (_) {
      // The tracker clears a selection whose element is gone after the next
      // frame; until then there is nothing to read.
      return const SizedBox.shrink();
    }
    return _InfoContent(info: info);
  }
}

/// 40 px: the widget's name over its source path, then the hit-candidate
/// count, the button for the next candidate, and close.
class _Header extends StatelessWidget {
  const _Header({
    required this.selection,
    required this.onClose,
    required this.onNextCandidate,
  });

  final PickResult selection;
  final VoidCallback onClose;
  final bool Function() onNextCandidate;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final candidates = selection.candidates.length;
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Container(
        height: InfoPanel.headerHeight,
        padding: const EdgeInsets.only(left: 12, right: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.ink)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    selection.entry.name,
                    style: tokens.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  StartEllipsisText(
                    locationLabel(selection) ?? 'source unavailable',
                    style: tokens.value.copyWith(
                      fontSize: 10,
                      height: 13 / 10,
                      color: tokens.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Click the same spot again for the next widget',
              child: Text(
                '${selection.index + 1}/$candidates',
                style: tokens.micro.copyWith(fontSize: 11),
              ),
            ),
            const SizedBox(width: 4),
            DraftIconButton(
              key: InfoPanel.nextCandidateKey,
              icon: PinPointIcons.unfoldMore,
              tooltip: 'Next widget under the pointer',
              onPressed: candidates > 1 ? onNextCandidate : null,
            ),
            DraftIconButton(
              icon: PinPointIcons.close,
              tooltip: 'Close panel',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The local chain around the selection, outermost first, on one line that
/// scrolls sideways and never wraps. A click on a crumb selects that widget.
/// The selected crumb is scrolled into view.
class _Crumbs extends StatefulWidget {
  const _Crumbs({required this.selection, required this.onSelect});

  final PickResult selection;
  final ValueChanged<int> onSelect;

  @override
  State<_Crumbs> createState() => _CrumbsState();
}

class _CrumbsState extends State<_Crumbs> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _current = GlobalKey(debugLabel: 'pinpoint current crumb');

  @override
  void initState() {
    super.initState();
    _showCurrent();
  }

  @override
  void didUpdateWidget(_Crumbs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection.chainIndex != widget.selection.chainIndex ||
        !identical(oldWidget.selection.chain, widget.selection.chain)) {
      _showCurrent();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _showCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _current.currentContext;
      if (!mounted || context == null || !_scroll.hasClients) return;
      Scrollable.ensureVisible(context);
    });
  }

  // A mouse wheel has only a vertical axis: it moves the line sideways.
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final position = _scroll.position;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      position.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final selection = widget.selection;
    final crumbs = crumbsFor(selection);
    final muted = tokens.value.copyWith(fontSize: 11, color: tokens.muted);
    Widget separator() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text('/', style: muted),
    );
    return Container(
      key: InfoPanel.crumbsKey,
      height: PinPointSizes.breadcrumb,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.rule)),
      ),
      child: Listener(
        onPointerSignal: _onWheel,
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (crumbs.moreAbove) ...[Text('…', style: muted), separator()],
                for (final (n, index) in crumbs.indices.indexed) ...[
                  if (n > 0) separator(),
                  _Crumb(
                    key: index == selection.chainIndex ? _current : null,
                    name: selection.chain[index].name,
                    selected: index == selection.chainIndex,
                    onTap: () => widget.onSelect(index),
                  ),
                ],
                if (crumbs.moreBelow) ...[separator(), Text('…', style: muted)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Crumb extends StatefulWidget {
  const _Crumb({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Crumb> createState() => _CrumbState();
}

class _CrumbState extends State<_Crumb> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final selected = widget.selected;
    final style = tokens.value.copyWith(
      fontSize: 11,
      color: selected
          ? tokens.ink
          : _hovered
          ? tokens.accentInk
          : tokens.muted,
      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
    );
    final text = Text(widget.name, style: style, maxLines: 1, softWrap: false);
    if (selected) return text;
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: text,
        ),
      ),
    );
  }
}

/// 30 px: three equal cells, caps labels, the active one in ink.
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
    final tokens = PinPointTokens.of(context);
    return Container(
      height: PinPointSizes.tabBar,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.ink)),
      ),
      child: Row(
        children: [
          _TabCell(
            key: InfoPanel.infoTabKey,
            label: 'INFO',
            selected: tab == PanelTab.info,
            onTap: () => onTab(PanelTab.info),
          ),
          _TabCell(
            key: InfoPanel.tweakTabKey,
            label: 'TWEAK',
            selected: tab == PanelTab.tweak,
            onTap: () => onTab(PanelTab.tweak),
          ),
          _TabCell(
            key: InfoPanel.commentTabKey,
            label: commentLabel.toUpperCase(),
            selected: tab == PanelTab.comment,
            last: true,
            onTap: () => onTab(PanelTab.comment),
          ),
        ],
      ),
    );
  }
}

class _TabCell extends StatefulWidget {
  const _TabCell({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.last = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool last;

  @override
  State<_TabCell> createState() => _TabCellState();
}

class _TabCellState extends State<_TabCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final selected = widget.selected;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? tokens.ink
                    : _hovered
                    ? tokens.accentBg
                    : null,
                border: widget.last
                    ? null
                    : Border(
                        right: BorderSide(
                          color: selected ? tokens.ink : tokens.rule,
                        ),
                      ),
              ),
              child: Text(
                widget.label,
                style: tokens.caps.copyWith(
                  color: selected ? tokens.paper : tokens.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Info tab: the render object's basics, then one numbered section for
/// each extractor that matched.
class _InfoContent extends StatelessWidget {
  const _InfoContent({required this.info});

  final WidgetInfo info;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    Widget row(String name, String label) => PanelRow(
      name: name,
      child: Text(label, style: tokens.value),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelSection(
          heading: sectionHeading(1, 'Render'),
          first: true,
          children: [
            row('render', info.renderType),
            row('size', info.sizeLabel),
            row('position', info.positionLabel),
            row('constraints', info.constraintsLabel),
            row('depth', '${info.depth}'),
          ],
        ),
        for (final (n, section) in info.sections.indexed) ...[
          const SizedBox(height: PinPointSizes.sectionGap),
          PanelSection(
            heading: sectionHeading(n + 2, section.title),
            children: [
              for (final property in section.properties)
                row(property.name, property.label),
            ],
          ),
        ],
      ],
    );
  }
}
