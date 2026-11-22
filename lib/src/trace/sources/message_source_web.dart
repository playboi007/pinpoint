import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'message_source.dart';

/// `message` events on `window`. A listener, not a replaced global: it
/// takes no slot (rule 17 does not apply), and the app's own listeners run
/// as before.
MessageHooks createPlatformMessageHooks() => _WindowMessages();

class _WindowMessages implements MessageHooks {
  JSFunction? _listener;

  @override
  bool listen(void Function(String origin, String data) onMessage) {
    if (_listener != null) return true;
    final listener = _listener = ((JSObject event) {
      try {
        final origin = event['origin'];
        onMessage(
          origin != null && origin.typeofEquals('string')
              ? (origin as JSString).toDart
              : '',
          _text(event['data']),
        );
      } catch (_) {
        // The recorder only observes.
      }
    }).toJS;
    globalContext.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'message'.toJS,
      listener,
    );
    return true;
  }

  @override
  void cancel() {
    final listener = _listener;
    if (listener == null) return;
    _listener = null;
    globalContext.callMethod<JSAny?>(
      'removeEventListener'.toJS,
      'message'.toJS,
      listener,
    );
  }
}

/// The data as JSON, or as text when it has none (a cycle, a transferred
/// port).
String _text(JSAny? data) {
  if (data == null) return 'null';
  try {
    final json = (globalContext['JSON']! as JSObject).callMethod<JSAny?>(
      'stringify'.toJS,
      data,
    );
    if (json != null && json.typeofEquals('string')) {
      return (json as JSString).toDart;
    }
  } catch (_) {}
  try {
    return '${data.dartify()}';
  } catch (_) {
    return '?';
  }
}
