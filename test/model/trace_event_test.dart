import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

TraceEvent _event(Map<String, Object?> data) =>
    TraceEvent(seq: 1, t: 0, frame: 0, kind: TraceKind.pointer, data: data);

void main() {
  test('byAgent is true only for input tagged agent', () {
    expect(_event({'by': 'agent'}).byAgent, isTrue);
    expect(_event({'by': 'user'}).byAgent, isFalse);
    expect(_event({}).byAgent, isFalse);
  });
}
