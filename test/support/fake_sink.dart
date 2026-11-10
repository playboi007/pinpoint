import 'dart:async';

import 'package:pinpoint/pinpoint.dart';

/// A sink that records every note, and fails with [error] when it is set.
///
/// Set [gate] to hold sends until it completes, to look at the sending
/// state.
class FakeSink extends PinPointSink {
  FakeSink({this.name = 'fake', this.error});

  @override
  final String name;

  /// Thrown by [send] when not null, for example a refused connection.
  Object? error;

  /// When not null, [send] waits for it before it finishes.
  Completer<void>? gate;

  /// Every note given to [send], failed ones included.
  final List<Annotation> notes = <Annotation>[];

  @override
  Future<void> send(Annotation note) async {
    notes.add(note);
    await gate?.future;
    final failure = error;
    if (failure != null) throw failure;
  }
}
