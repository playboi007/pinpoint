import 'package:flutter/material.dart';

import '../core/code_line_cache.dart';
import '../model/source_location.dart';
import '../search/pick_result.dart';
import '../sink/bridge_client.dart';
import '../state/dependencies.dart';
import '../state/state_lens.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import '../trace/trace_session.dart';
import 'panel_parts.dart';
import 'source_location_button.dart';
import 'state_chain.dart';

export 'state_chain.dart' show formatClock, methodLabel, whereLabel;

/// The State tab of the Info panel (PLAN-v3 Milestone 21, step 7).
///
/// Three parts:
/// 1. What the picked widget reads: its state owners and the objects they
///    depend on, with identity tags. Cheap, so it shows with no arming.
/// 2. "Watch state" arms the [StateLens] on the picked element for one
///    window. While it runs the tab shows one static line with the end
///    time, never a countdown: the lens publishes only after frames with
///    real rebuilds, and Pinpoint must not draw frames on a timer (an agent
///    waits until the app stops drawing).
/// 3. The chain per cause, newest first: what notified (owner, tag, method,
///    file:line), the code line from the bridge when there is one, the
///    values before and after, the readers that rebuilt, and the coupling
///    hint. All of it comes from [StateLens.chain] (`state_flow.dart`).
class StateTab extends StatefulWidget {
  const StateTab({
    super.key,
    required this.selection,
    required this.session,
    this.bridge,
    this.onToast,
    this.codeLines,
    this.onWatch,
  });

  /// The "Watch state" button.
  static const Key watchKey = ValueKey<String>('pinpoint.stateTab.watch');

  /// The "Stop" button, shown while a window is open.
  static const Key stopKey = ValueKey<String>('pinpoint.stateTab.stop');

  /// "Watching until HH:MM:SS".
  static const Key watchingKey = ValueKey<String>('pinpoint.stateTab.watching');

  /// "Stopped:" and the reason.
  static const Key stoppedKey = ValueKey<String>('pinpoint.stateTab.stopped');

  /// The section that lists what the widget reads.
  static const Key readsKey = ValueKey<String>('pinpoint.stateTab.reads');

  /// The section that lists the causes.
  static const Key chainKey = ValueKey<String>('pinpoint.stateTab.chain');

  /// The folder button of one row that has a source location. See
  /// [StateChain.locationKey].
  static Key locationKey(String id) => StateChain.locationKey(id);

  /// The tip that the folder button shows after 2 s of hover.
  static const Key locationTipKey = StateChain.locationTipKey;

  /// The popover of the folder button: short path and line.
  static const Key locationPopoverKey = StateChain.locationPopoverKey;

  /// The Copy button of that popover.
  static const Key locationCopyKey = StateChain.locationCopyKey;

  /// One cause block: [id] is `c<cause>`, or `f<frame>` for a change with
  /// no cause.
  static Key causeKey(String id) => StateChain.causeKey(id);

  /// The coupling hint of one cause block.
  static Key hintKey(String id) => StateChain.hintKey(id);

  final PickResult selection;

  /// The flight recorder's session; null while the recorder is off.
  final TraceSession? session;

  /// The bridge that reads source lines for the chain; null, or one that
  /// returns null, shows no code line.
  final BridgeClient? Function()? bridge;

  /// Shows a toast, for example "Copied lib/main.dart:12" after the popover's
  /// Copy. When it is null the popover stays open and its button says
  /// "Copied".
  final ValueChanged<String>? onToast;

  /// The source lines of the chain, shared for the session (the controller's
  /// `codeLines`). Null: this tab keeps its own.
  final CodeLineCache? codeLines;

  /// Called after "Watch state" armed the lens: Pinpoint then leaves
  /// picking and opens the watch card. Null: the tab only arms the lens and
  /// stays as it is.
  final VoidCallback? onWatch;

  @override
  State<StateTab> createState() => _StateTabState();
}

class _StateTabState extends State<StateTab> {
  StateLens? _lens;

  CodeLineCache? _ownCache;

  CodeLineCache get _cache =>
      widget.codeLines ?? (_ownCache ??= CodeLineCache());

  /// When the open window ends, fixed when the tab first sees it armed.
  DateTime? _until;

  // The readers are read again only when the element or the lens changes.
  Element? _readersOf;
  StateLensState? _readersAt;
  List<ReaderRef> _readers = const <ReaderRef>[];

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(StateTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) _follow();
  }

  @override
  void dispose() {
    _lens?.removeListener(_onLens);
    _ownCache?.dispose();
    super.dispose();
  }

  void _follow() {
    _lens?.removeListener(_onLens);
    _lens = widget.session?.stateLens;
    _lens?.addListener(_onLens);
  }

  // After a frame with real rebuilds, and when a window opens or ends.
  void _onLens() {
    if (mounted) setState(() {});
  }

  void _arm(StateLens lens) {
    final element = widget.selection.element;
    if (!element.mounted) return;
    lens.arm(element);
    _until = DateTime.now().add(lens.value.window);
    widget.onWatch?.call();
  }

  List<ReaderRef> _readersFor(StateLens lens, Element element) {
    final at = lens.value;
    if (identical(_readersOf, element) && identical(_readersAt, at)) {
      return _readers;
    }
    _readersOf = element;
    _readersAt = at;
    try {
      _readers = nearestReaders(
        element,
        lens.resolver,
        boundary: lens.content(),
        tags: lens.tags,
      );
    } catch (_) {
      // Diagnostics run code written by widget authors.
      _readers = const <ReaderRef>[];
    }
    return _readers;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final lens = _lens;
    if (lens == null) {
      return Text(
        'The state lens needs the flight recorder, and it is off.',
        style: tokens.label,
      );
    }
    final element = widget.selection.element;
    final value = lens.value;
    final mine = identical(value.target, element);
    final armedHere = mine && value.armed;
    if (armedHere) {
      _until ??= DateTime.now().add(Duration(seconds: lens.secondsLeft));
    } else {
      _until = null;
    }
    final readers = _readersFor(lens, element);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Reads(
          key: StateTab.readsKey,
          readers: readers,
          lens: lens,
          onToast: widget.onToast,
        ),
        const SizedBox(height: PinPointSizes.sectionGap),
        _watch(tokens, lens, value, mine: mine, armedHere: armedHere),
        if (mine) ...[
          const SizedBox(height: PinPointSizes.sectionGap),
          _chain(tokens, lens),
        ],
      ],
    );
  }

  Widget _watch(
    PinPointTokens tokens,
    StateLens lens,
    StateLensState value, {
    required bool mine,
    required bool armedHere,
  }) {
    final until = _until;
    final String? status;
    Key? statusKey;
    if (armedHere && until != null) {
      status = 'Watching until ${formatClock(until)}';
      statusKey = StateTab.watchingKey;
    } else if (mine && value.endedBecause != null) {
      status = 'Stopped: ${value.endedBecause}';
      statusKey = StateTab.stoppedKey;
    } else if (value.armed) {
      status =
          'Watching ${value.targetType ?? 'another widget'} now. '
          'Watch state here moves it.';
    } else {
      status = null;
    }
    return PanelSection(
      heading: sectionHeading(2, 'Watch'),
      children: [
        Row(
          children: [
            if (armedHere)
              DraftButton.outline(
                key: StateTab.stopKey,
                label: 'Stop',
                onPressed: lens.stop,
              )
            else
              DraftButton.primary(
                key: StateTab.watchKey,
                label: 'Watch state',
                onPressed: () => _arm(lens),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status ?? 'Records what changes it for 30 s.',
                key: statusKey,
                style: tokens.label,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chain(PinPointTokens tokens, StateLens lens) {
    final Map<String, Object?> chain;
    try {
      chain = lens.chain();
    } catch (_) {
      return const SizedBox.shrink();
    }
    final causes = asList(chain['causes']);
    return PanelSection(
      key: StateTab.chainKey,
      heading: sectionHeading(3, 'Changes'),
      detail: causes.isEmpty ? null : '${chain['events']} events',
      children: [
        StateChainView(
          chain: chain,
          cache: _cache,
          bridge: widget.bridge,
          onToast: widget.onToast,
        ),
      ],
    );
  }
}

/// The first part of the tab: what the widget reads.
class _Reads extends StatelessWidget {
  const _Reads({
    super.key,
    required this.readers,
    required this.lens,
    this.onToast,
  });

  final List<ReaderRef> readers;
  final StateLens lens;
  final ValueChanged<String>? onToast;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final paths = lens.resolver.paths;
    Widget? where(String id, SourceLocation? location) => location == null
        ? null
        : SourceLocationButton(
            key: StateTab.locationKey(id),
            path: shortSourcePath(paths.relativePath(location.uri)),
            line: location.line,
            onToast: onToast,
            tipKey: StateTab.locationTipKey,
            popoverKey: StateTab.locationPopoverKey,
            copyKey: StateTab.locationCopyKey,
          );
    return PanelSection(
      heading: sectionHeading(1, 'Reads'),
      first: true,
      children: [
        if (readers.isEmpty)
          Text('No state read here', style: tokens.label)
        else
          for (var i = 0; i < readers.length; i++) ...[
            locatedRow(
              where('r$i', readers[i].location),
              Text(
                readers[i].type,
                style: tokens.value.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            if (readers[i].dependencies.isEmpty)
              Text('no state object read', style: tokens.micro)
            else
              for (var j = 0; j < readers[i].dependencies.length; j++)
                PanelRow(
                  name: readers[i].dependencies[j].kind,
                  child: locatedRow(
                    where('r$i.d$j', readers[i].dependencies[j].location),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: readers[i].dependencies[j].type),
                          TextSpan(
                            text: ' ${readers[i].dependencies[j].tag}',
                            style: tokens.value.copyWith(
                              color: tokens.accentInk,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      style: tokens.value,
                    ),
                  ),
                ),
          ],
      ],
    );
  }
}
