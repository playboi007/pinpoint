import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../agent/synthetic_input.dart';

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

  /// Blocks real input and shows [text].
  static void show(String text) {
    banner.value = text;
    blocking.value = true;
  }

  /// Gives input back and hides the banner.
  static void clear() {
    banner.value = null;
    blocking.value = false;
  }
}

/// A layer over the app, under Pinpoint's own UI, that takes every real
/// pointer event while [ReplayGate.blocking] is set. The player's own
/// events ([SyntheticInput.dispatching]) pass through to the app.
///
/// Always in the tree (engineering rule 5): only what it does changes. It
/// sits outside the app's `RepaintBoundary` (rule 6), so it is in no
/// screenshot and no pick.
class ReplayBlocker extends StatelessWidget {
  const ReplayBlocker({super.key});

  static const Key bannerKey = ValueKey<String>('pinpoint.replay.banner');

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: _Blocker(
      child: ValueListenableBuilder<String?>(
        valueListenable: ReplayGate.banner,
        builder: (context, text, _) => text == null
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DecoratedBox(
                    key: bannerKey,
                    decoration: const BoxDecoration(
                      color: Color(0xE6202124),
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        '$text · Esc stops',
                        style: const TextStyle(
                          color: Color(0xFFFFFFFF),
                          fontSize: 13,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    ),
  );
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
