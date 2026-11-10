import 'package:flutter/services.dart';

import '../model/annotation.dart';
import 'pinpoint_sink.dart';

/// Copies each note to the clipboard as Markdown, to paste into an agent.
///
/// It needs no bridge, so a note still goes somewhere when the bridge is
/// stopped. The Markdown never holds the screenshot.
class ClipboardSink extends PinPointSink {
  const ClipboardSink();

  @override
  String get name => 'clipboard';

  /// Throws when the platform refuses, for example a browser that allows
  /// clipboard writes only soon after a click.
  @override
  Future<void> send(Annotation note) =>
      Clipboard.setData(ClipboardData(text: note.toMarkdown()));
}
