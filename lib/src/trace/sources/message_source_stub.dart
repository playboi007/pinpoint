import 'message_source.dart';

/// No platform messages outside web.
MessageHooks createPlatformMessageHooks() => _NoMessageHooks();

class _NoMessageHooks implements MessageHooks {
  @override
  bool listen(void Function(String origin, String data) onMessage) => false;

  @override
  void cancel() {}
}
