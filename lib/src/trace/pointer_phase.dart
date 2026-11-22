// Plain Dart: no `dart:ui` and no `package:flutter`.

import '../model/trace_event.dart';

/// The `phase` of an `input.pointer` event.
enum PointerPhase {
  hover('hover'),
  down('down'),
  move('move'),
  up('up'),
  cancel('cancel'),
  scroll('scroll'),
  drag('drag');

  const PointerPhase(this.wire);

  final String wire;

  /// An unknown or missing phase reads as [drag], as it always did.
  static PointerPhase fromWire(Object? wire) =>
      values.firstWhere((phase) => phase.wire == wire, orElse: () => drag);
}

extension PointerPhaseOf on TraceEvent {
  PointerPhase get pointerPhase => PointerPhase.fromWire(data['phase']);
}
