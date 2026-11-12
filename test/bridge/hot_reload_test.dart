import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/bridge/hot_reload.dart';

/// The bridge's `hot_reload`: through the app's debug service, confirmed by
/// the app's reload count.
void main() {
  late Directory dir;
  late _FakeDebugService service;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pinpoint_reload_');
    service = _FakeDebugService();
    await service.start();
  });
  tearDown(() async {
    await service.stop();
    dir.deleteSync(recursive: true);
  });

  HotReloader reloader() =>
      HotReloader(dir, confirmWait: const Duration(milliseconds: 600));

  test('acceptance: reloads through the address flutter run wrote, and the '
      'count going up confirms it', () async {
    File('${dir.path}/$vmServiceFileName').writeAsStringSync(service.wsUri);
    final answer = await reloader().reload();
    expect(answer['ok'], isTrue, reason: '$answer');
    final result = answer['result']! as Map<String, Object?>;
    expect(result['confirmed'], isTrue);
    expect(service.reloadedIsolates, ['isolates/1']);
  });

  test(
    'a reload that does not apply says so: the code did not compile',
    () async {
      // What the web runner does: success, and the old code still runs.
      service.applies = false;
      final answer = await reloader().reload(address: service.httpUri);
      expect(answer['ok'], isFalse);
      expect(answer['error'], contains('did not apply'));
      expect(answer['error'], contains('flutter analyze'));
    },
  );

  test('with no address it says how to give one; another machine is '
      'refused; a given address is kept', () async {
    final none = await reloader().reload();
    expect(none['error'], contains('--vmservice-out-file'));

    final remote = await reloader().reload(
      address: 'http://10.0.0.5:${service.port}/abc=/',
    );
    expect(remote['error'], contains('not a debug service address'));
    expect(service.reloadedIsolates, isEmpty);

    // As flutter run prints it.
    expect((await reloader().reload(address: service.httpUri))['ok'], isTrue);
    // The next call needs no address.
    expect((await reloader().reload())['ok'], isTrue);
    expect(service.reloadedIsolates, hasLength(2));
  });
}

/// A debug service as `flutter run -d chrome` has one: DDS with
/// `s2.reloadSources` from Flutter Tools and Pinpoint's reload count.
class _FakeDebugService {
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
