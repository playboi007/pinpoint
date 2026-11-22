import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../core/watch_session.dart';
import '../sink/bridge_client.dart';
import '../state/state_lens.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';
import '../trace/story.dart';
import 'info_panel.dart' show clampPanel, panelMarginX, panelMarginY;
import 'state_chain.dart';
import 'story_view.dart';

/// Places [WatchCard] while the watch session is open (watch mode of the
/// state lens).
///
/// Only the card takes pointer events; the rest of the area lets them go to
/// the app, as in idle. The card is dragged by its header, kept inside the
/// viewport, and its place is kept for the session
/// ([WatchSession.cardPosition]). Until it is dragged, it sits in the
/// bottom-right corner, left of the rail.
class WatchCardLayer extends StatelessWidget {
  const WatchCardLayer({
    super.key,
    required this.controller,
    this.bridge,
    this.onToast,
    this.rightInset = 0,
  });

  final PinPointController controller;

  /// The bridge that reads source lines for the chain rows.
  final BridgeClient? Function()? bridge;

  /// Shows a toast, for example "Copied lib/main.dart:12".
  final ValueChanged<String>? onToast;

  /// Space at the right edge the card never covers: the rail.
  final double rightInset;

  @override
  Widget build(BuildContext context) {
    final watch = controller.watch;
    return ListenableBuilder(
      listenable: watch,
      builder: (context, _) {
        final lens = watch.lens;
        if (!watch.open || lens == null) return const SizedBox.shrink();
        // Padding on the right only keeps the layer's origin at the
        // wrapper's, so global rects stay valid (engineering rule 7).
        return Padding(
          padding: EdgeInsets.only(right: rightInset),
          child: _CardPlacement(
            watch: watch,
            card: (onDrag) => WatchCard(
              watch: watch,
              lens: lens,
              controller: controller,
              bridge: bridge,
              onToast: onToast,
              onDrag: onDrag,
            ),
          ),
        );
      },
    );
  }
}

class _CardPlacement extends StatefulWidget {
  const _CardPlacement({required this.watch, required this.card});

  final WatchSession watch;
  final WatchCard Function(ValueChanged<Offset> onDrag) card;

  @override
  State<_CardPlacement> createState() => _CardPlacementState();
}

class _CardPlacementState extends State<_CardPlacement> {
  final GlobalKey _box = GlobalKey(debugLabel: 'pinpoint watch card box');

  // Copies the Info panel's drag: several updates can arrive before the next
  // layout, so add to the stored position, not to the last laid out one.
  void _drag(Offset delta) {
    final box = _box.currentContext?.findRenderObject();
    final area = context.findRenderObject();
    if (box is! RenderBox || area is! RenderBox) return;
    if (!box.hasSize || !area.hasSize) return;
    final from =
        widget.watch.cardPosition ??
        box.localToGlobal(Offset.zero, ancestor: area);
    setState(() {
      widget.watch.cardPosition = clampPanel(from + delta, box.size, area.size);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => CustomSingleChildLayout(
        delegate: _CardLayout(
          dragged: widget.watch.cardPosition,
          width: WatchCard.widthFor(constraints.maxWidth),
        ),
        child: KeyedSubtree(key: _box, child: widget.card(_drag)),
      ),
    );
  }
}

/// Lays the card out at its own height (at most [WatchCard.maxHeightShare]
/// of the viewport), then puts it where it was dragged, or in the
/// bottom-right corner. Clamped on every layout, so a window resize never
/// pushes it off screen.
class _CardLayout extends SingleChildLayoutDelegate {
  _CardLayout({required this.dragged, required this.width});

  final Offset? dragged;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = constraints.maxHeight - 2 * panelMarginY;
    final height = (constraints.maxHeight * WatchCard.maxHeightShare).clamp(
      0.0,
      room > 0 ? room : 0.0,
    );
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => clampPanel(
    // Past the corner: the clamp brings it to the bottom-right margin.
    dragged ?? Offset(size.width, size.height),
    childSize,
    size,
  );

  @override
  bool shouldRelayout(_CardLayout oldDelegate) =>
      dragged != oldDelegate.dragged || width != oldDelegate.width;
}

/// The live changes card of watch mode: "WATCHING Widget" with the end
/// time of the window and Stop, then the story of changes, oldest at the
/// top, in the same rows as the State tab ([StoryView]). The card follows
/// the bottom of the story; when the user scrolled up it says "3 new ↓"
/// instead of moving.
///
/// The story is read again only when the lens publishes. The end time is
/// fixed when the window opens: no countdown (no frames on a timer). After
/// the window ends the header says "Stopped: reason" and offers "Watch
/// again" (the same target, when it is still mounted) and Close.
class WatchCard extends StatefulWidget {
  const WatchCard({
    super.key = cardKey,
    required this.watch,
    required this.lens,
    required this.controller,
    this.bridge,
    this.onToast,
    this.onDrag,
  });

  static const Key cardKey = ValueKey<String>('pinpoint.watchCard');
  static const Key headerKey = ValueKey<String>('pinpoint.watchCard.header');
  static const Key titleKey = ValueKey<String>('pinpoint.watchCard.title');

  /// "until HH:MM:SS", or "Stopped: reason".
  static const Key statusKey = ValueKey<String>('pinpoint.watchCard.status');
  static const Key stopKey = ValueKey<String>('pinpoint.watchCard.stop');
  static const Key againKey = ValueKey<String>('pinpoint.watchCard.again');
  static const Key closeKey = ValueKey<String>('pinpoint.watchCard.close');
  static const Key bodyKey = ValueKey<String>('pinpoint.watchCard.body');

  /// "3 new ↓": shown when the story grew while the user read older
  /// blocks.
  static const Key newKey = ValueKey<String>('pinpoint.watchCard.new');

  /// The widest the card gets.
  static const double width = 320;

  /// The card is at most this share of the viewport high; the body scrolls.
  static const double maxHeightShare = 0.45;

  /// The card's width in a viewport [viewportWidth] wide.
  static double widthFor(double viewportWidth) {
    final room = viewportWidth - 2 * panelMarginX;
    return room < width ? (room > 0 ? room : 0) : width;
  }

  final WatchSession watch;
  final StateLens lens;
  final PinPointController controller;
  final BridgeClient? Function()? bridge;
  final ValueChanged<String>? onToast;
  final ValueChanged<Offset>? onDrag;

  @override
  State<WatchCard> createState() => _WatchCardState();
}

class _WatchCardState extends State<WatchCard> {
  // The story of the state the lens last published, and of the filter.
  StateLensState? _at;
  StoryFilter _filter = const StoryFilter();
  StoryFilter? _filterAt;
  bool _mineAt = false;
  Story _story = const Story();

  final ScrollController _scroll = ScrollController();

  // Follows the bottom until the user scrolls up.
  bool _atBottom = true;
  int _seen = 0;
  int _newBelow = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final bottom = _scroll.position.extentAfter < 24;
    if (bottom == _atBottom) return;
    _atBottom = bottom;
    if (bottom && _newBelow > 0) {
      setState(() => _newBelow = 0);
    }
  }

  void _toBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
    setState(() {
      _atBottom = true;
      _newBelow = 0;
    });
  }

  Story _storyFor(StateLens lens, {required bool mine}) {
    final value = lens.value;
    if (identical(value, _at) && mine == _mineAt && _filter == _filterAt) {
      return _story;
    }
    _at = value;
    _mineAt = mine;
    _filterAt = _filter;
    if (!mine) return _story = const Story();
    try {
      _story = lens.story(_filter);
    } catch (_) {
      // Diagnostics run code written by widget authors.
      _story = const Story();
    }
    _follow(_story);
    return _story;
  }

  // How much happened: blocks (with their repeats) and end lines. A story
  // that grew while the user is at the bottom scrolls to it after the
  // frame; while the user reads older blocks it counts what is new.
  void _follow(Story story) {
    final activity =
        story.blocks.fold<int>(0, (n, b) => n + b.repeat) + story.ends.length;
    final grew = activity - _seen;
    _seen = activity;
    if (grew <= 0) return;
    if (_atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _atBottom && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    } else {
      _newBelow += grew;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lens = widget.lens;
    final watch = widget.watch;
    final motion = PinPointMotion.of(context);
    // Opens with a short fade and rise, since the user asked for it. Zero
    // under reduced motion.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motion.moderate,
      curve: PinPointMotion.enter,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      // The lens publishes after frames with real rebuilds; the session
      // changes when the user watches again, stops or closes.
      child: ListenableBuilder(
        listenable: Listenable.merge([lens, watch]),
        builder: (context, _) => _card(context, lens, watch),
      ),
    );
  }

  Widget _card(BuildContext context, StateLens lens, WatchSession watch) {
    final tokens = PinPointTokens.of(context);
    final value = lens.value;
    final mine = identical(value.target, watch.target);
    final armedHere = mine && value.armed;
    final story = _storyFor(lens, mine: mine);
    final until = watch.until;
    final status = armedHere
        ? (until == null ? 'watching' : 'until ${formatClock(until)}')
        : 'Stopped: ${mine ? (value.endedBecause ?? 'stopped') : 're-targeted'}';
    // Swallows pointer events over the whole card, also on its blank parts,
    // so a click on it never reaches the app beneath.
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: Material(
        type: MaterialType.transparency,
        child: DraftSurface(
          elevation: 3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                key: WatchCard.headerKey,
                // Count the movement from pointer down, so the card stays
                // under the pointer instead of lagging by the touch slop.
                dragStartBehavior: DragStartBehavior.down,
                onPanUpdate: widget.onDrag == null
                    ? null
                    : (details) => widget.onDrag!(details.delta),
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: _header(
                    tokens,
                    watch,
                    armedHere: armedHere,
                    status: status,
                  ),
                ),
              ),
              Flexible(
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      key: WatchCard.bodyKey,
                      controller: _scroll,
                      padding: const EdgeInsets.all(PinPointSizes.panelPadding),
                      child: StoryView(
                        story: story,
                        filter: _filter,
                        onFilter: (filter) => setState(() => _filter = filter),
                        cache: widget.controller.codeLines,
                        bridge: widget.bridge,
                        onToast: widget.onToast,
                      ),
                    ),
                    if (_newBelow > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 8,
                        child: Center(
                          child: DraftButton.primary(
                            key: WatchCard.newKey,
                            label: '$_newBelow new ↓',
                            onPressed: _toBottom,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    PinPointTokens tokens,
    WatchSession watch, {
    required bool armedHere,
    required String status,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: PinPointSizes.panelHeader),
      padding: const EdgeInsets.only(left: 12, right: 6, top: 4, bottom: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.ink)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'WATCHING ',
                        style: tokens.caps.copyWith(color: tokens.accentInk),
                      ),
                      TextSpan(text: watch.name, style: tokens.title),
                    ],
                  ),
                  key: WatchCard.titleKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  status,
                  key: WatchCard.statusKey,
                  style: tokens.value.copyWith(
                    fontSize: 10,
                    height: 13 / 10,
                    color: tokens.muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (armedHere)
            DraftButton.outline(
              key: WatchCard.stopKey,
              label: 'Stop',
              onPressed: watch.stopLens,
            )
          else
            DraftButton.outline(
              key: WatchCard.againKey,
              label: 'Watch again',
              onPressed: watch.canWatchAgain ? () => watch.watchAgain() : null,
            ),
          const SizedBox(width: 2),
          DraftIconButton(
            key: WatchCard.closeKey,
            icon: PinPointIcons.close,
            tooltip: 'Close',
            onPressed: watch.close,
          ),
        ],
      ),
    );
  }
}
