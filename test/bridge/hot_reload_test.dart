import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/bridge/hot_reload.dart';

import '../support/fake_debug_service.dart';

/// The bridge's `hot_reload`: through the app's debug service, confirmed by
/// the app's reload count.
void main() {
  late Directory dir;
  late FakeDebugService service;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pinpoint_reload_');
    service = FakeDebugService();
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
