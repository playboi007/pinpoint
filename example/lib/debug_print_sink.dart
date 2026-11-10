import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pinpoint/pinpoint.dart';

/// Prints each note's JSON to the console, so Send does something in the
/// example before Milestone 7 adds the HTTP and clipboard sinks.
///
/// The screenshot is printed as a `data:` URL on its own line. Paste it in
/// the browser's address bar to look at the image.
class DebugPrintSink extends PinPointSink {
  const DebugPrintSink();

  @override
  String get name => 'console';

  @override
  Future<void> send(Annotation note) async {
    debugPrint('pinpoint note: ${jsonEncode(note.toJson())}');
    final shot = note.screenshot;
    final png = shot?.png;
    if (shot == null || png == null) return;
    debugPrint(
      'pinpoint screenshot ${shot.width}x${shot.height}, '
      '${(png.length / 1024).toStringAsFixed(0)} KB:',
    );
    // Not debugPrint: it throttles output after 12 KB a second.
    // ignore: avoid_print
    print('data:image/png;base64,${base64Encode(png)}');
  }
}
