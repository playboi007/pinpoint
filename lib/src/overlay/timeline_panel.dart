import 'dart:async';

import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../model/trace_event.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import '../trace/cause_zone.dart';
import '../trace/trace_format.dart';
import '../trace/trace_session.dart';
import 'panel_keys.dart';
import 'rail.dart';

/// The Timeline (PLAN-v2 Milestone 13, step 11): the flight recorder's
/// events, newest first, grouped by cause (Milestone 14) or, without
/// `PinPoint.run`, by frame, with a filter chip per kind. A
/// click on an event flashes its widget. Marks are rows the user can name.
///
/// While open it holds level 3 ([TraceDemand.timeline]), so rebuilds and
/// watched state show. Each frame's header shows the recorder's own time
/// in that frame, so a frame time read in debug is not taken for the
/// app's alone (watch out for).
class TimelinePanel extends StatefulWidget {
  const TimelinePanel({
    super.key,
    required this.session,
    required this.onFlash,
    required this.onClose,
  });

  static const Key buttonKey = ValueKey<String>('pinpoint.timeline.button');
  static const Key panelKey = ValueKey<String>('pinpoint.timeline.panel');

  /// The "Clear recording" button.
  static const Key clearKey = ValueKey<String>('pinpoint.timeline.clear');

  static const Key markKey = ValueKey<String>('pinpoint.timeline.mark');
  static const Key closeKey = ValueKey<String>('pinpoint.timeline.close');

  /// The eye button that shows or hides [countKey].
  static const Key countToggleKey = ValueKey<String>(
    'pinpoint.timeline.countToggle',
  );

  /// How many events the record holds.
  static const Key countKey = ValueKey<String>('pinpoint.timeline.count');

  static Key chipKey(String kind) =>
      ValueKey<String>('pinpoint.timeline.chip.$kind');
  static Key rowKey(int seq) => ValueKey<String>('pinpoint.timeline.row.$seq');
  static Key causeKey(int id) =>
      ValueKey<String>('pinpoint.timeline.cause.$id');
  static Key nameKey(int seq) =>
      ValueKey<String>('pinpoint.timeline.name.$seq');

  /// Whether the Timeline is open. A static, not a field of the overlay's
  /// `State`: a new instance field is undefined after a web hot reload
  /// (api-notes item 29, watch out for).
  static final ValueNotifier<bool> open = ValueNotifier<bool>(false);

  /// Whether the header shows how many events the record holds. Hidden by
  /// default: the number climbs to the limit (20,000) and says little.
  /// A static for the same reason as [open].
  static final ValueNotifier<bool> showCount = ValueNotifier<bool>(false);

  /// The kinds a chip filters, by prefix.
  static const List<String> filterKinds = [
    'input',
    TraceKind.build,
    TraceKind.state,
    TraceKind.probe,
    TraceKind.route,
    TraceKind.error,
    TraceKind.finding,
    TraceKind.mark,
    'net',
    'detail',
  ];

  /// Most event rows shown.
  static const int maxRows = 300;

  final TraceSession session;

  /// Outlines the widget of an event in the app.
  final void Function(TraceEvent event) onFlash;
  final VoidCallback onClose;

  @override
  State<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<TimelinePanel> {
  final Set<String> _hidden = <String>{};
  final TextEditingController _name = TextEditingController();
  Timer? _poll;
  int _seen = -1;
  int? _editing;

  TraceSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.demand(TraceDemand.timeline);
    // A timer, not a rebuild per event: the panel must not draw a frame
    // for every event it shows (engineering rule 2).
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _session.recorder.nextSeq != _seen) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _session.release(TraceDemand.timeline);
    _name.dispose();
    super.dispose();
  }

  bool _shown(TraceEvent event) {
    if (event.kind == TraceKind.frame) return false;
    for (final kind in _hidden) {
      if (TraceKind.matches(event.kind, kind)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final recorder = _session.recorder;
    _seen = recorder.nextSeq;
    // Newest first. Events sit under their cause (PLAN-v2 Milestone 14,
    // step 17); without causes (no PinPoint.run), under their frame. The
    // frame event carries the recorder's own time and the rebuild count for
    // its header.
    final groups = <(int?, int), List<TraceEvent>>{};
    final frames = <int, TraceEvent>{};
    var rows = 0;
    for (final event in recorder.newestFirst) {
      if (event.kind == TraceKind.frame) {
        frames[event.frame] ??= event;
        continue;
      }
      if (!_shown(event)) continue;
      final cause = event.cause;
      final key = cause == null ? (null, event.frame) : (cause, 0);
      (groups[key] ??= <TraceEvent>[]).add(event);
      if (++rows >= TimelinePanel.maxRows) break;
    }
    return PanelKeyScope(
      child: DraftSurface(
        key: TimelinePanel.panelKey,
        elevation: 3,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(tokens),
            _chips(),
            const DraftRule(),
            Flexible(
              child: groups.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(PinPointSizes.panelPadding),
                      child: Text('Nothing recorded yet.', style: tokens.body),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        for (final MapEntry(key: (cause, frame), :value)
                            in groups.entries) ...[
                          if (cause == null)
                            _frameHeader(tokens, frame, value, frames[frame])
                          else
                            _causeHeader(tokens, cause, value, frames),
                          for (final event in value) _row(tokens, event),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(PinPointTokens tokens) {
    final recorder = _session.recorder;
    return Container(
      height: PinPointSizes.panelHeader,
      padding: const EdgeInsets.only(
        left: PinPointSizes.panelPadding,
        right: 8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.ink)),
      ),
      child: Row(
        children: [
          Text('Timeline', style: tokens.title),
          const SizedBox(width: 4),
          DraftIconButton(
            key: TimelinePanel.countToggleKey,
            icon: TimelinePanel.showCount.value
                ? PinPointIcons.visibilityOff
                : PinPointIcons.visibility,
            iconSize: 16,
            tooltip: TimelinePanel.showCount.value
                ? 'Hide event count'
                : 'Show event count',
            onPressed: () => setState(
              () => TimelinePanel.showCount.value =
                  !TimelinePanel.showCount.value,
            ),
          ),
          if (TimelinePanel.showCount.value) ...[
            const SizedBox(width: 4),
            CountBadge(key: TimelinePanel.countKey, recorder.length),
          ],
          if (recorder.partial)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: recorder.partialReason ?? '',
                child: Text('partial', style: tokens.caps),
              ),
            ),
          const Spacer(),
          // For the moment the user typed something they do not want kept:
          // the record and the tape stores go at once (PLAN-v2 Milestone
          // 15, step 6).
          DraftButton.link(
            key: TimelinePanel.clearKey,
            onPressed: () => setState(_session.clearRecording),
            label: 'Clear',
          ),
          DraftButton.link(
            key: TimelinePanel.markKey,
            onPressed: () => setState(() => _session.mark()),
            label: 'Mark',
          ),
          DraftIconButton(
            key: TimelinePanel.closeKey,
            icon: PinPointIcons.close,
            tooltip: 'Close',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _chips() => Padding(
    padding: const EdgeInsets.all(PinPointSizes.panelPadding),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final kind in TimelinePanel.filterKinds)
          DraftChip(
            key: TimelinePanel.chipKey(kind),
            label: kind,
            look: _hidden.contains(kind) ? ChipLook.rest : ChipLook.selected,
            onTap: () => setState(() {
              if (!_hidden.remove(kind)) _hidden.add(kind);
            }),
          ),
      ],
    ),
  );

  Widget _frameHeader(
    PinPointTokens tokens,
    int frame,
    List<TraceEvent> events,
    TraceEvent? frameEvent,
  ) {
    // A folded frame event (TraceRecorder.addFrame) holds totals for many
    // frames, not this one's: leave them out.
    final single = frameEvent?.data['n'] == null;
    final us = single ? frameEvent?.data['us'] : null;
    final builds = single ? frameEvent?.data['builds'] : null;
    final parts = [
      'f$frame',
      formatTraceTime(events.first.t),
      if (builds is int) 'builds $builds',
      // The recorder's own time in this frame, not the app's.
      if (us is int) 'rec ${(us / 1000).toStringAsFixed(2)} ms',
    ];
    return Container(
      color: tokens.field,
      padding: const EdgeInsets.symmetric(
        horizontal: PinPointSizes.panelPadding,
        vertical: 2,
      ),
      child: Text(parts.join('  '), style: tokens.caps),
    );
  }

  /// `c37  pointer  f233-f236  +3.21s`; for a frame cause, the
  /// recorder's own time in that frame too.
  Widget _causeHeader(
    PinPointTokens tokens,
    int id,
    List<TraceEvent> events,
    Map<int, TraceEvent> frames,
  ) {
    final cause = _session.recorder.causeOf(id);
    final first = events.last.frame;
    final last = events.first.frame;
    final frameEvent = cause?.kind == CauseKind.frame ? frames[first] : null;
    // A folded frame event holds totals for many frames: left out.
    final folded = frameEvent?.data['n'] != null;
    final us = frameEvent?.data['us'];
    final parts = [
      'c$id',
      cause?.kind ?? '?',
      first == last ? 'f$first' : 'f$first-f$last',
      formatTraceTime(events.last.t),
      if (us is int && !folded) 'rec ${(us / 1000).toStringAsFixed(2)} ms',
    ];
    return Container(
      key: TimelinePanel.causeKey(id),
      color: tokens.field,
      padding: const EdgeInsets.symmetric(
        horizontal: PinPointSizes.panelPadding,
        vertical: 2,
      ),
      child: Text(parts.join('  '), style: tokens.caps),
    );
  }

  Widget _row(PinPointTokens tokens, TraceEvent event) {
    if (event.kind == TraceKind.mark) return _markRow(tokens, event);
    final flashable = event.widget != null || event.source != null;
    return InkWell(
      key: TimelinePanel.rowKey(event.seq),
      onTap: flashable ? () => widget.onFlash(event) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PinPointSizes.panelPadding,
          vertical: 3,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(
                event.kind,
                style: tokens.caps,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: Text(
                traceSummary(event),
                style: tokens.body.copyWith(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _markRow(PinPointTokens tokens, TraceEvent event) {
    final text = event.data['text'];
    final editing = _editing == event.seq;
    return Container(
      key: TimelinePanel.rowKey(event.seq),
      padding: const EdgeInsets.symmetric(
        horizontal: PinPointSizes.panelPadding,
        vertical: 3,
      ),
      child: Row(
        children: [
          SizedBox(width: 92, child: Text('mark', style: tokens.caps)),
          Expanded(
            child: editing
                ? TextField(
                    key: TimelinePanel.nameKey(event.seq),
                    controller: _name,
                    autofocus: true,
                    style: tokens.body.copyWith(fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'What is wrong here?',
                    ),
                    onSubmitted: (value) => setState(() {
                      _session.renameMark(event.seq, value.trim());
                      _editing = null;
                    }),
                  )
                : Text(
                    text is String && text.isNotEmpty ? text : '(no name)',
                    style: tokens.body.copyWith(fontSize: 12),
                  ),
          ),
          if (!editing)
            DraftIconButton(
              icon: Icons.edit,
              tooltip: 'Name this mark',
              onPressed: () => setState(() {
                _editing = event.seq;
                _name.text = text is String ? text : '';
              }),
            ),
        ],
      ),
    );
  }
}

/// Places [TimelinePanel] beside the rail while it is open and a mode is
/// active, where the what-if and findings panels go: the three take turns.
class TimelinePanelLayer extends StatefulWidget {
  const TimelinePanelLayer({
    super.key,
    required this.controller,
    required this.placement,
    required this.others,
    required this.onFlash,
  });

  final PinPointController controller;
  final RailPlacement placement;

  /// The panels that share the place: opening one closes the Timeline,
  /// and opening the Timeline closes them.
  final List<ValueNotifier<bool>> others;
  final void Function(TraceEvent event) onFlash;

  @override
  State<TimelinePanelLayer> createState() => _TimelinePanelLayerState();
}

class _TimelinePanelLayerState extends State<TimelinePanelLayer> {
  @override
  void initState() {
    super.initState();
    TimelinePanel.open.addListener(_onOpen);
    for (final other in widget.others) {
      other.addListener(_onOther);
    }
    widget.controller.addListener(_onMode);
  }

  @override
  void dispose() {
    TimelinePanel.open.removeListener(_onOpen);
    for (final other in widget.others) {
      other.removeListener(_onOther);
    }
    widget.controller.removeListener(_onMode);
    super.dispose();
  }

  void _onOpen() {
    if (!TimelinePanel.open.value) return;
    for (final other in widget.others) {
      other.value = false;
    }
  }

  void _onOther() {
    if (widget.others.any((o) => o.value)) TimelinePanel.open.value = false;
  }

  // Closes with the other rail panels when the mode goes idle.
  void _onMode() {
    if (!widget.controller.isActive) TimelinePanel.open.value = false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: TimelinePanel.open,
      builder: (context, open, _) {
        final session = TraceSession.current;
        if (!open || !widget.controller.isActive || session == null) {
          return const SizedBox.shrink();
        }
        return BesideRail(
          placement: widget.placement,
          child: TimelinePanel(
            session: session,
            onFlash: widget.onFlash,
            onClose: () => TimelinePanel.open.value = false,
          ),
        );
      },
    );
  }
}
