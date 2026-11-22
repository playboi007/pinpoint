import 'dart:convert';

import '../../model/trace_event.dart';
import '../cause_zone.dart';
import '../net_record.dart' show NetHash;
import '../redact.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';
import 'message_source_stub.dart'
    if (dart.library.js_interop) 'message_source_web.dart'
    as platform;

/// Listens to the platform's messages: `window` `message` events on web.
abstract interface class MessageHooks {
  /// Starts calling [onMessage] with each message's origin and its data as
  /// JSON (or as text, when it is not JSON). False when the platform has
  /// none.
  bool listen(void Function(String origin, String data) onMessage);

  /// Stops listening.
  void cancel();
}

/// `input.message` events, level 1: the
/// origin, a hash, and the data clipped to 2 KB. An app that lives in an
/// iframe gets its session this way, so a tape without its messages would
/// not replay.
///
/// Each message is a cause of its own. The app's listener runs in the zone
/// it was added in, not in this cause: a browser event listener is not an
/// engine entry, so the two cannot be linked.
class MessageSource extends TraceSource {
  MessageSource({
    this.redact = const TraceRedact(),
    MessageHooks? platformHooks,
  }) : _platform = platformHooks ?? platform.createPlatformMessageHooks();

  /// Most characters of a message's data kept.
  static const int maxChars = 2048;

  /// Keys of the JSON data whose values are masked: a session
  /// token sent to an iframe is a secret.
  final TraceRedact redact;

  final MessageHooks _platform;
  TraceRecorder? _recorder;

  @override
  String get name => 'message';

  @override
  int get level => 1;

  @override
  bool get isInput => true;

  @override
  void start(TraceRecorder recorder) {
    if (_recorder != null) return;
    _recorder = recorder;
    _platform.listen(record);
  }

  @override
  void stop() {
    if (_recorder == null) return;
    _recorder = null;
    _platform.cancel();
  }

  /// Records one message. [data] is its JSON, or its text.
  void record(String origin, String data) {
    final recorder = _recorder;
    if (recorder == null) return;
    var shown = data;
    try {
      shown = jsonEncode(redact.json(jsonDecode(data)));
    } on FormatException {
      // Text, not JSON: kept as it is.
    }
    recorder.add(
      TraceKind.message,
      data: {
        'origin': origin,
        'size': data.length,
        'hash': NetHash.of(utf8.encode(shown)),
        'data': shown.length <= maxChars ? shown : shown.substring(0, maxChars),
      },
      cause: CauseZone.newCause(CauseKind.message),
    );
  }
}
