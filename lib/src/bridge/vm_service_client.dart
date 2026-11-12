// Plain Dart with `dart:io`: the bridge's small client for the Dart VM
// service (JSON-RPC 2.0 over a WebSocket). It does only what `hot_reload`
// needs, so the bridge adds no `vm_service` dependency.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A VM service call failed, for a reason the agent should read.
class VmServiceException implements Exception {
  const VmServiceException(this.message, {this.code});

  final String message;

  /// The JSON-RPC error code, when the service sent one.
  final int? code;

  @override
  String toString() => message;
}

/// [text] as the WebSocket address of a VM service, or null when it is not
/// one on this machine.
///
/// `flutter run` prints `http://127.0.0.1:53182/abc=/`; its
/// `--vmservice-out-file` holds `ws://127.0.0.1:53182/abc=/ws`. Both give
/// `ws://127.0.0.1:53182/abc=/ws`. Only loopback hosts: the bridge must
/// not be a way to reach another machine.
Uri? vmServiceWebSocketUri(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.hasAuthority || !uri.hasPort) return null;
  final scheme = switch (uri.scheme) {
    'http' || 'ws' => 'ws',
    'https' || 'wss' => 'wss',
    _ => null,
  };
  if (scheme == null) return null;
  final host = uri.host.toLowerCase();
  if (host != 'localhost' && host != '::1' && !host.startsWith('127.')) {
    return null;
  }
  var path = uri.path.isEmpty ? '/' : uri.path;
  if (!path.endsWith('/ws')) {
    path = path.endsWith('/') ? '${path}ws' : '$path/ws';
  }
  return Uri(scheme: scheme, host: uri.host, port: uri.port, path: path);
}

/// One connection to a VM service.
class VmServiceClient {
  VmServiceClient._(this._socket) {
    _subscription = _socket.listen(
      _onMessage,
      onDone: _onDone,
      onError: (Object _) => _onDone(),
    );
  }

  /// Connects to [uri], a WebSocket address ([vmServiceWebSocketUri]).
  static Future<VmServiceClient> connect(
    Uri uri, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      return VmServiceClient._(
        await WebSocket.connect(uri.toString()).timeout(timeout),
      );
    } on Object {
      throw VmServiceException('cannot reach the debug service at $uri');
    }
  }

  final WebSocket _socket;
  late final StreamSubscription<Object?> _subscription;
  int _next = 0;
  bool _closed = false;
  bool _listening = false;
  final Map<String, Completer<Map<String, Object?>>> _pending =
      <String, Completer<Map<String, Object?>>>{};

  /// Registered services (`reloadSources`) and the methods that run them
  /// (`s2.reloadSources`), from the `Service` stream.
  final Map<String, String> _services = <String, String>{};
  final StreamController<void> _servicesChanged =
      StreamController<void>.broadcast();

  /// Calls [method] and returns its result. Throws a [VmServiceException]
  /// for an error answer, a closed connection, or no answer in [timeout].
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    if (_closed) {
      throw const VmServiceException('the debug service closed the connection');
    }
    final id = '${++_next}';
    final done = _pending[id] = Completer<Map<String, Object?>>();
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      throw VmServiceException(
        '$method: no answer within ${timeout.inSeconds} s',
      );
    } finally {
      _pending.remove(id);
    }
  }

  /// The method that runs [service] (for example `s2.reloadSources` for
  /// `reloadSources`), or null when none is registered within [wait].
  ///
  /// A new listener of the `Service` stream gets one `ServiceRegistered`
  /// event for each service registered before it.
  Future<String?> serviceMethod(
    String service, {
    Duration wait = const Duration(seconds: 1),
  }) async {
    if (!_listening) {
      _listening = true;
      await call('streamListen', {'streamId': 'Service'});
    }
    final known = _services[service];
    if (known != null) return known;
    try {
      await _servicesChanged.stream
          .firstWhere((_) => _services.containsKey(service))
          .timeout(wait);
    } on TimeoutException {
      return null;
    }
    return _services[service];
  }

  /// The id of the app's main isolate: the first that is not a system
  /// isolate.
  Future<String> mainIsolateId() async {
    final vm = await call('getVM');
    final isolates = vm['isolates'];
    for (final isolate in isolates is List<Object?> ? isolates : const []) {
      if (isolate is Map<String, Object?> &&
          isolate['isSystemIsolate'] != true &&
          isolate['id'] is String) {
        return isolate['id']! as String;
      }
    }
    throw const VmServiceException('the app has no isolate yet');
  }

  /// Ends the connection.
  Future<void> close() async {
    _onDone();
    await _subscription.cancel();
    await _socket.close();
    await _servicesChanged.close();
  }

  void _onMessage(Object? data) {
    if (data is! String) return;
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (json is! Map<String, Object?>) return;
    final id = json['id'];
    if (id != null) {
      final done = _pending['$id'];
      if (done == null || done.isCompleted) return;
      final error = json['error'];
      if (error is Map<String, Object?>) {
        done.completeError(_error(error));
      } else {
        final result = json['result'];
        done.complete(
          result is Map<String, Object?> ? result : const <String, Object?>{},
        );
      }
      return;
    }
    if (json['method'] != 'streamNotify') return;
    final params = json['params'];
    final event = params is Map<String, Object?> ? params['event'] : null;
    if (event is! Map<String, Object?>) return;
    final service = event['service'];
    if (service is! String) return;
    switch (event['kind']) {
      case 'ServiceRegistered':
        if (event['method'] case final String method) {
          _services[service] = method;
          if (!_servicesChanged.isClosed) _servicesChanged.add(null);
        }
      case 'ServiceUnregistered':
        _services.remove(service);
    }
  }

  static VmServiceException _error(Map<String, Object?> error) {
    final data = error['data'];
    final details = data is Map<String, Object?> ? data['details'] : null;
    final message = '${error['message'] ?? 'error'}';
    return VmServiceException(
      details is String && details.isNotEmpty
          ? '$message: ${details.length > 400 ? '${details.substring(0, 400)}…' : details}'
          : message,
      code: error['code'] is int ? error['code']! as int : null,
    );
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    for (final done in _pending.values) {
      if (!done.isCompleted) {
        done.completeError(
          const VmServiceException('the debug service closed the connection'),
        );
      }
    }
  }
}
