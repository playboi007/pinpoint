import 'dart:async';

import '../model/annotation.dart';

/// Where notes go, for example the clipboard or the local bridge.
///
/// Plain Dart, like the model, so the bridge can share it.
abstract class PinPointSink {
  const PinPointSink();

  /// Shown in the result toast, for example `HTTP`.
  String get name;

  /// Delivers [note]. Throws when it was not delivered.
  Future<void> send(Annotation note);
}

/// What one sink did with a note.
class SinkResult {
  const SinkResult(this.sink, {this.error});

  /// The sink's [PinPointSink.name].
  final String sink;

  /// Why the sink failed, or null when it took the note.
  final Object? error;

  bool get ok => error == null;

  @override
  String toString() => ok ? '$sink: ok' : '$sink: $error';
}

/// Gives [note] to each of [sinks] in order and reports each result.
///
/// A sink that throws, or takes longer than [timeout], fails alone: the
/// rest still get the note.
Future<List<SinkResult>> sendToSinks(
  Annotation note,
  List<PinPointSink> sinks, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final results = <SinkResult>[];
  for (final sink in sinks) {
    String name;
    try {
      name = sink.name;
    } catch (_) {
      name = sink.runtimeType.toString();
    }
    try {
      await Future<void>.sync(() => sink.send(note)).timeout(timeout);
      results.add(SinkResult(name));
    } catch (error) {
      results.add(SinkResult(name, error: error));
    }
  }
  return results;
}
