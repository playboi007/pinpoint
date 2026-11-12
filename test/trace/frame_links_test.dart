import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';

/// PLAN-v2 Milestone 14, build step 6: from frame to frame, the "near"
/// way. A frame is linked to every cause that ran since the frame before
/// it; one of them made it dirty. Plain Dart, real async.
void main() {
  tearDown(CauseZone.debugReset);

  test('a frame is linked to the frame before it and to each cause that '
      'ran in between, oldest first', () async {
    final engine = _Engine();
    engine.frame();
    final f1 = engine.lastFrame!;
    engine.pointer();
    final tap = engine.lastPointer!;
    engine.frame();
    final f2 = engine.lastFrame!;
    expect(f2.after, [f1.id, tap.id]);
    // Nothing ran but the frame itself: the next one links only it.
    engine.frame();
    expect(engine.lastFrame!.after, [f2.id]);
  });

  test('an answer that arrives in the zone of an earlier cause links that '
      'cause to the next frame (the loop: a response sets state)', () async {
    final engine = _Engine();
    final answered = Completer<void>();
    engine.onPointer = () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      answered.complete();
    };
    engine.pointer();
    final tap = engine.lastPointer!;
    engine.frame();
    engine.frame();
    final before = engine.lastFrame!;
    await answered.future;
    engine.frame();
    expect(engine.lastFrame!.after, [before.id, tap.id]);
  });

  test("Pinpoint's own work is never a link, and the links are bounded", () {
    final engine = _Engine();
    engine.zone.zone.run(
      () => CauseZone.internal(() => scheduleMicrotask(() {})),
    );
    for (var i = 0; i < CauseZone.maxLinks + 5; i++) {
      engine.pointer();
    }
    engine.frame();
    final after = engine.lastFrame!.after;
    expect(after, hasLength(CauseZone.maxLinks));
    expect(after, isNot(contains(0)));
    // The newest are kept: closest to the frame.
    expect(after.last, engine.lastPointer!.id);
  });
}

class _Packet {}

class _Engine {
  _Engine()
    : zone = CauseZone(
        kindOf: (arg) => switch (arg) {
          _Packet() => CauseKind.pointer,
          Duration() => CauseKind.frame,
          _ => null,
        },
      ) {
    zone.run(() {
      _binding = Zone.current;
    });
  }

  final CauseZone zone;
  late Zone _binding;
  TraceCause? lastFrame;
  TraceCause? lastPointer;
  void Function()? onPointer;

  void pointer() => _binding.runUnaryGuarded<Object?>((_) {
    lastPointer = CauseZone.currentCause;
    onPointer?.call();
  }, _Packet());

  void frame() => _binding.runUnaryGuarded<Duration>(
    (_) => lastFrame = CauseZone.currentCause,
    Duration.zero,
  );
}
