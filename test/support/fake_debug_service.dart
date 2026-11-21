import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pinpoint/src/bridge/bridge_protocol.dart';

/// A debug service as `flutter run -d chrome` has one: DDS with
/// `s2.reloadSources` from Flutter Tools and Pinpoint's reload count.
class FakeDebugService {
  late HttpServer _server;

  /// Whether a reload raises the app's count (false: it did not compile).
  bool applies = true;
  int _reloads = 0;
  final List<String> reloadedIsolates = <String>[];

  int get port => _server.port;
  String get httpUri => 'http://127.0.0.1:$port/abc=/';
  String get wsUri => 'ws://127.0.0.1:$port/abc=/ws';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      if (request.uri.path != '/abc=/ws') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) => _answer(socket, data as String));
    });
  }

  Future<void> stop() => _server.close(force: true);

  void _answer(WebSocket socket, String data) {
    final message = jsonDecode(data) as Map<String, Object?>;
    final params = message['params']! as Map<String, Object?>;
    void reply(Map<String, Object?> result) => socket.add(
      jsonEncode({'jsonrpc': '2.0', 'id': message['id'], 'result': result}),
    );
    switch (message['method']) {
      case 'streamListen':
        reply({'type': 'Success'});
        for (final (service, method) in [
          ('hotRestart', 's1.hotRestart'),
          ('reloadSources', 's2.reloadSources'),
        ]) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'streamNotify',
              'params': {
                'streamId': 'Service',
                'event': {
                  'kind': 'ServiceRegistered',
                  'service': service,
                  'method': method,
                },
              },
            }),
          );
        }
      case 'getVM':
        reply({
          'type': 'VM',
          'isolates': [
            {'id': 'isolates/1', 'name': 'main()', 'isSystemIsolate': false},
          ],
        });
      case reloadsExtension:
        reply({'reloads': _reloads});
      case 's2.reloadSources':
        reloadedIsolates.add(params['isolateId']! as String);
        reply({'type': 'Success'});
        // The app reassembles a moment after the service answers.
        if (applies) {
          Timer(const Duration(milliseconds: 100), () => _reloads++);
        }
      default:
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'error': {'code': -32601, 'message': 'Method not found'},
          }),
        );
    }
  }
}
