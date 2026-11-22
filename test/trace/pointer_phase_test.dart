import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/trace/pointer_phase.dart';

void main() {
  test('each phase is read by its wire name', () {
    for (final phase in PointerPhase.values) {
      expect(PointerPhase.fromWire(phase.wire), phase);
    }
  });

  test('an unknown or missing phase reads as drag', () {
    expect(PointerPhase.fromWire('tilt'), PointerPhase.drag);
    expect(PointerPhase.fromWire(null), PointerPhase.drag);
    expect(PointerPhase.fromWire(3), PointerPhase.drag);
  });

  test('an event gives its phase', () {
    final event = TraceEvent(
      seq: 1,
      t: 0,
      frame: 0,
      kind: TraceKind.pointer,
      data: const {'phase': 'up'},
    );
    expect(event.pointerPhase, PointerPhase.up);
  });
}
