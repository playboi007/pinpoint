import '../../core/hook_registry.dart';
import '../net_record.dart';
import 'network_source.dart';

/// No request hooks outside web yet: `HttpOverrides` is a later step
/// (PLAN-v2, "What works where").
NetworkHooks createPlatformNetworkHooks() => _NoNetworkHooks();

class _NoNetworkHooks implements NetworkHooks {
  @override
  bool install(NetRecorder net, HookRegistry hooks) => false;

  @override
  void uninstall() {}
}
