import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../agent/synthetic_input.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';

/// How a replay ended, for the banner.
enum ReplayOutcome {
  /// It played to the end.
  done,

  /// It ran into something it cannot go past.
  diverged,
}

/// What a replay shows and blocks (PLAN-v2 Milestone 15, step 17).
///
/// Statics, not fields of a widget's `State`: a new instance field is
/// undefined after a web hot reload (api-notes item 29), and the player
/// sets them from anywhere.
abstract final class ReplayGate {
  /// Whether real pointer input is blocked: while a replay runs or holds.
  static final ValueNotifier<bool> blocking = ValueNotifier<bool>(false);

  /// The banner text, for example "Replaying tape, step 12 of 42", or
  /// null for none.
  static final ValueNotifier<String?> banner = ValueNotifier<String?>(null);

  /// The step number inside [banner]'s text, which the banner rolls when it
  /// changes, or null when the text has none.
  static final ValueNotifier<int?> step = ValueNotifier<int?>(null);

  /// How the replay ended while the banner still shows its last words
  /// ("Done", or why it diverged), or null while it runs.
  static final ValueNotifier<ReplayOutcome?> outcome =
      ValueNotifier<ReplayOutcome?>(null);

  /// Blocks real input and shows [text]. [step] is the number in [text]
  /// that rolls when it changes.
  static void show(String text, {int? step}) {
    ReplayGate.step.value = step;
    outcome.value = null;
    banner.value = text;
    blocking.value = true;
  }

  /// Gives input back at once. The banner stays with [text] for a moment,
  /// as the replay's last words: it hides itself (see [ReplayBlocker]).
  static void finish(ReplayOutcome how, String text) {
    blocking.value = false;
    step.value = null;
    outcome.value = how;
    banner.value = text;
  }

  /// Gives input back and hides the banner.
  static void clear() {
    banner.value = null;
    step.value = null;
    outcome.value = null;
    blocking.value = false;
  }
}

/// A layer over the app, under Pinpoint's own UI, that takes every real
/// pointer event while [ReplayGate.blocking] is set. The player's own
/// events ([SyntheticInput.dispatching]) pass through to the app.
///
/// Its banner slides in from the top (250 ms) while a replay runs, and the
/// step number rolls: the old digit slides up, the new one comes in from
/// below. At the end it says "Done" for 1.2 s and slides out. When the
/// replay diverged it shakes once, has a red bar on its left and an error
/// glyph, says why, and stays 3.5 s. Input is back the moment the replay
/// ends: the banner never holds it.
///
/// Always in the tree (engineering rule 5): only what it does changes. It
/// sits outside the app's `RepaintBoundary` (rule 6), so it is in no
/// screenshot and no pick. With reduced motion the banner shows and hides
/// at once and nothing rolls or shakes.
class ReplayBlocker extends StatelessWidget {
  const ReplayBlocker({super.key});

  static const Key bannerKey = ValueKey<String>('pinpoint.replay.banner');

  /// The rolling step number inside the banner.
  static const Key stepKey = ValueKey<String>('pinpoint.replay.step');

  /// The red left bar of a diverged replay.
  static const Key errorBarKey = ValueKey<String>('pinpoint.replay.errorBar');

  /// How long "Done" shows before the banner slides out.
  static const Duration doneHold = Duration(milliseconds: 1200);

  /// How long a diverged banner stays: there is something to read.
  static const Duration divergedHold = Duration(milliseconds: 3500);

  @override
  Widget build(BuildContext context) => const Directionality(
    textDirection: TextDirection.ltr,
    child: _Blocker(child: _ReplayBanner()),
  );
}

/// What the banner draws now. Kept while it slides out, so the words do not
/// vanish before the banner does.
class _Shown {
  const _Shown(this.text, this.outcome, this.step);

  final String text;
  final ReplayOutcome? outcome;
  final int? step;
}

class _ReplayBanner extends StatefulWidget {
  const _ReplayBanner();

  @override
  State<_ReplayBanner> createState() => _ReplayBannerState();
}

class _ReplayBannerState extends State<_ReplayBanner>
    with TickerProviderStateMixin {
  /// 0 off screen, 1 in place.
  late final AnimationController _slide;

  /// One shake: 0 to 1 once, when a replay diverges.
  late final AnimationController _shake;

  late final Listenable _gate = Listenable.merge([
    ReplayGate.banner,
    ReplayGate.step,
    ReplayGate.outcome,
  ]);

  Timer? _hold;
  _Shown? _shown;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(vsync: this);
    _shake = AnimationController(vsync: this);
    _gate.addListener(_changed);
    // A replay that began before the banner was built: it is simply there.
    final text = ReplayGate.banner.value;
    if (text != null) {
      final outcome = ReplayGate.outcome.value;
      _shown = _Shown(text, outcome, ReplayGate.step.value);
      _slide.value = 1;
      if (outcome != null) _holdFor(outcome);
    }
  }

  @override
  void dispose() {
    _gate.removeListener(_changed);
    _hold?.cancel();
    _slide.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _time() {
    final motion = PinPointMotion.of(context);
    _slide.duration = motion.moderate;
    _shake.duration = motion.scaled(const Duration(milliseconds: 320));
  }

  void _changed() {
    // The player may set the gate while a frame builds (the wrapper starts a
    // replay in its own initState): wait for the frame to end.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _apply());
    } else {
      _apply();
    }
  }

  void _apply() {
    if (!mounted) return;
    _time();
    final text = ReplayGate.banner.value;
    if (text == null) {
      _hold?.cancel();
      if (_shown != null) {
        // Out. At zero duration this ends in the same call.
        _slide.reverse().whenComplete(() {
          if (mounted && ReplayGate.banner.value == null) {
            setState(() => _shown = null);
          }
        });
      }
      return;
    }
    final before = _shown;
    final outcome = ReplayGate.outcome.value;
    setState(() => _shown = _Shown(text, outcome, ReplayGate.step.value));
    _slide.forward();
    if (before?.outcome != outcome) {
      _hold?.cancel();
      if (outcome != null) {
        if (outcome == ReplayOutcome.diverged) _shake.forward(from: 0);
        _holdFor(outcome);
      }
    }
  }

  /// Hides the banner after the last words have been there a while.
  void _holdFor(ReplayOutcome outcome) {
    _hold = Timer(
      outcome == ReplayOutcome.done
          ? ReplayBlocker.doneHold
          : ReplayBlocker.divergedHold,
      () {
        // Only the words it holds now: a new replay may have begun.
        if (ReplayGate.outcome.value == outcome) ReplayGate.clear();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    _time();
    final tokens = PinPointTokens.of(context);
    return DefaultTextStyle(
      style: tokens.body.copyWith(decoration: TextDecoration.none),
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, left: 8, right: 8),
          child: SlideTransition(
            position:
                Tween<Offset>(
                  // Far enough up to be off screen, whatever its height.
                  begin: const Offset(0, -2),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: _slide,
                    curve: PinPointMotion.enter,
                    reverseCurve: PinPointMotion.exit,
                  ),
                ),
            child: AnimatedBuilder(
              animation: _shake,
              builder: (context, child) {
                // One short shake: two and a half swings, dying out.
                final t = _shake.value;
                final dx = _shake.isAnimating
                    ? math.sin(t * math.pi * 5) * 6 * (1 - t)
                    : 0.0;
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: _BannerCard(shown: shown, tokens: tokens),
            ),
          ),
        ),
      ),
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.shown, required this.tokens});

  final _Shown shown;
  final PinPointTokens tokens;

  @override
  Widget build(BuildContext context) {
    final diverged = shown.outcome == ReplayOutcome.diverged;
    final done = shown.outcome == ReplayOutcome.done;
    final barColor = diverged
        ? tokens.err
        : done
        ? tokens.ok
        : tokens.accent;
    final glyph = diverged
        ? PinPointIcons.error
        : done
        ? PinPointIcons.check
        : Icons.replay;
    final glyphColor = diverged ? tokens.err : tokens.ink;
    final style = tokens.value;
    return Semantics(
      liveRegion: shown.outcome != null,
      label: shown.outcome == null ? '${shown.text} · Esc stops' : shown.text,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DecoratedBox(
          key: ReplayBlocker.bannerKey,
          decoration: tokens.surface(2),
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The bar and the glyph both say how it went: colour is
                // not the only signal.
                SizedBox(
                  key: diverged ? ReplayBlocker.errorBarKey : null,
                  width: 4,
                  child: ColoredBox(color: barColor),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(glyph, size: 16, color: glyphColor),
                        const SizedBox(width: 8),
                        Flexible(child: _words(style)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The words: with a step number, the number rolls; the rest is text.
  Widget _words(TextStyle style) {
    final step = shown.step;
    final at = step == null ? -1 : shown.text.lastIndexOf('step $step');
    if (shown.outcome != null || at < 0) {
      return Text(
        shown.outcome == null ? '${shown.text} · Esc stops' : shown.text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final numberAt = at + 'step '.length;
    final number = '$step';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(shown.text.substring(0, numberAt), style: style),
        _RollingNumber(key: ReplayBlocker.stepKey, text: number, style: style),
        Flexible(
          child: Text(
            '${shown.text.substring(numberAt + number.length)} · Esc stops',
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// A number whose digits roll on change: the old digit slides up and out,
/// the new one comes in from below. One roller per digit, so only the
/// digits that change move.
class _RollingNumber extends StatelessWidget {
  const _RollingNumber({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final motion = PinPointMotion.of(context);
    return ClipRect(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, char) in text.split('').indexed)
            AnimatedSwitcher(
              key: ValueKey<String>('${text.length}-$i'),
              duration: motion.quick,
              switchInCurve: PinPointMotion.enter,
              switchOutCurve: PinPointMotion.exit,
              transitionBuilder: (child, animation) {
                final coming = child.key == ValueKey<String>('$i$char');
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(0, coming ? 0.9 : -0.9),
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: Text(char, key: ValueKey<String>('$i$char'), style: style),
            ),
        ],
      ),
    );
  }
}

class _Blocker extends SingleChildRenderObjectWidget {
  const _Blocker({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBlocker();
}

class _RenderBlocker extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!ReplayGate.blocking.value || SyntheticInput.dispatching) {
      return false;
    }
    if (!size.contains(position)) return false;
    // Real input during a replay ends here: the app never sees it.
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
