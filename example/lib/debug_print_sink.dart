import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pinpoint/pinpoint.dart';

/// Prints each note's JSON to the console, so Send does something in the
/// example before Milestone 7 adds the HTTP and clipboard sinks.
class DebugPrintSink extends PinPointSink {
  const DebugPrintSink();

  @override
  String get name => 'console';

  @override
  Future<void> send(Annotation note) async {
    debugPrint('pinpoint note: ${jsonEncode(note.toJson())}');
  }
}
