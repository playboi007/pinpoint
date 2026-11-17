import '../../core/hook_registry.dart';
import '../../tape/net_matcher.dart';
import '../net_record.dart';
import '../redact.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';
import 'network_source_stub.dart'
    if (dart.library.js_interop) 'network_source_web.dart'
    as platform;

/// Puts the platform's request hooks in place and takes them out. On web:
/// `window.fetch` and `XMLHttpRequest.prototype` (`open`, `send`,
/// `setRequestHeader`); elsewhere none yet (`HttpOverrides` later).
abstract interface class NetworkHooks {
  /// Installs the hooks through [hooks] (rule 17: JS globals are global
  /// slots) and reports each request to [net]. False when the platform has
  /// none.
  bool install(NetRecorder net, HookRegistry hooks);

  /// Gives every slot back, unless someone wrote it after us.
  void uninstall();
}

/// The hooks for this platform.
NetworkHooks createNetworkHooks() => platform.createPlatformNetworkHooks();

/// `net.request`, `net.response` and `net.error` events (PLAN-v2 Milestone
/// 14, steps 11 to 13). Level 1 for the metadata; the bodies are level 2
/// (`TraceConfig.bodies`).
///
/// The source only observes (rule 11): the app gets the very objects it
/// would get without it, with the same timing.
class NetworkSource extends TraceSource {
  NetworkSource({
    required HookRegistry hooks,
    this.bodies = true,
    this.redact = const TraceRedact(),
    this.ignoreOrigins = const <String>{},
    this.tap,
    NetworkHooks? platformHooks,
  }) : _hooks = hooks,
       _platform = platformHooks ?? createNetworkHooks();

  final HookRegistry _hooks;
  final NetworkHooks _platform;

  /// Whether answers are read for their hash and kept for a tape.
  final bool bodies;

  /// Masked header and parameter names.
  final TraceRedact redact;

  /// Origins never recorded: the bridge's (rule 14).
  final Set<String> ignoreOrigins;

  /// Sees each request with its raw URL and body: the tape recorder.
  NetTap? tap;

  NetRecorder? _net;
  bool _installed = false;
  NetReplay? _replay;

  /// The replay that answers requests now, or null (PLAN-v2 Milestone 15,
  /// step 8). Setting null puts the network back: every request reaches
  /// the server again.
  NetReplay? get replay => _replay;
  set replay(NetReplay? value) {
    _replay = value;
    _net?.replay = value;
  }

  /// The recorder of the running source, or null while stopped.
  NetRecorder? get net => _net;

  /// Whether this platform's hooks are in place.
  bool get installed => _installed;

  @override
  String get name => 'network';

  @override
  int get level => 1;

  /// The answers are input for a tape: a replay serves them (Milestone 15).
  @override
  bool get isInput => true;

  @override
  void start(TraceRecorder recorder) {
    if (_net != null) return;
    final net = _net = NetRecorder(
      recorder,
      bodies: bodies,
      redact: redact,
      ignoreOrigins: ignoreOrigins,
      tap: tap,
    )..replay = _replay;
    _installed = _platform.install(net, _hooks);
  }

  @override
  void stop() {
    _net = null;
    if (_installed) _platform.uninstall();
    _installed = false;
  }
}
