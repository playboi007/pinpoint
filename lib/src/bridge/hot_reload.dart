// Plain Dart with `dart:io`: the bridge's `hot_reload` tool. It talks to
// the app's debug service, not to the app, so it works with agent control
// off and with the app's tab hidden.

import 'dart:async';
import 'dart:io';

import 'bridge_protocol.dart';
import 'vm_service_client.dart';

/// Asks `flutter run` for a hot reload of the running app, and says
/// whether the new code runs.
///
/// The debug service address comes from the tool call, else from
/// [vmServiceFileName] in the notes folder, which
/// `flutter run --vmservice-out-file=.pinpoint/vm-service.txt` writes. An
/// address given in a call that worked is written there too, so the agent
/// gives it once per `flutter run`.
///
/// Flutter Tools' `reloadSources` answers success on web even when the code
/// did not compile. So the reload counts only when the app's reload count
/// ([reloadsExtension]) went up.
class HotReloader {
  HotReloader(
    this.dir, {
    this.confirmWait = const Duration(seconds: 5),
    this.reloadTimeout = const Duration(seconds: 120),
  });

  /// The notes folder.
  final Directory dir;

  /// How long after the reload the count may take to go up.
  final Duration confirmWait;

  /// The longest a reload (the compile included) may take.
  final Duration reloadTimeout;

  File get addressFile => File('${dir.path}/$vmServiceFileName');

  /// Why no reload can be asked for without an address.
  String get _howToConnect =>
      'Start the app with flutter run '
      '--vmservice-out-file=${_shown(addressFile.path)}, or give vm_service: '
      'the address flutter run prints ("A Dart VM Service on Chrome is '
      'available at: http://127.0.0.1:…").';

  Future<Map<String, Object?>>? _running;

  /// Reloads, through [address] when given. The answer is
  /// `{ok: true, result: …}` or `{ok: false, error: …}`; never throws.
  ///
  /// A call while a reload runs gets that reload's answer: two reloads at
  /// once would overlap in `flutter run`.
  Future<Map<String, Object?>> reload({String? address}) {
    final running = _running;
    if (running != null) return running;
    final next = _running = _reload(address);
    return next.whenComplete(() => _running = null);
  }

  Future<Map<String, Object?>> _reload(String? address) async {
    final watch = Stopwatch()..start();
    final given = address == null || address.trim().isEmpty
        ? null
        : address.trim();
    final text = given ?? await _readAddress();
    if (text == null) {
      return _error('No debug service address. $_howToConnect');
    }
    final uri = vmServiceWebSocketUri(text);
    if (uri == null) {
      return _error(
        '$text is not a debug service address on this machine. '
        '$_howToConnect',
      );
    }
    final VmServiceClient client;
    try {
      client = await VmServiceClient.connect(uri);
    } on VmServiceException catch (failure) {
      return _error(
        '${failure.message}. ${given == null ? 'The address in '
                  '${_shown(addressFile.path)} may be from an earlier '
                  'flutter run (it changes at each start). ' : ''}'
        '$_howToConnect',
      );
    }
    try {
      final reload = await client.serviceMethod('reloadSources');
      if (reload == null) {
        return _error(
          'The debug service has no reloadSources: the app must run under '
          'flutter run or flutter attach.',
        );
      }
      final isolate = await client.mainIsolateId();
      final before = await _reloads(client, isolate);
      await client.call(reload, {'isolateId': isolate}, reloadTimeout);
      if (given != null) await _remember(given);
      if (before == null) {
        return _ok({
          'reloaded': true,
          'confirmed': false,
          'why':
              'the app has no Pinpoint reload count yet (an older Pinpoint; '
              'it is there after this reload). Check the screen.',
          'ms': watch.elapsedMilliseconds,
        });
      }
      final waited = Stopwatch()..start();
      while (waited.elapsed < confirmWait) {
        final after = await _reloads(client, isolate);
        if (after != null && after > before) {
          return _ok({
            'reloaded': true,
            'confirmed': true,
            'ms': watch.elapsedMilliseconds,
            'handles':
                'handles from before the reload are gone: use target, or '
                'find the widgets again',
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return _error(
        'The reload did not apply: the app runs the old code. Most often '
        'the code does not compile: run flutter analyze, and the flutter run '
        'terminal shows the compiler error.',
      );
    } on VmServiceException catch (failure) {
      return _error('Hot reload failed: ${failure.message}');
    } finally {
      await client.close();
    }
  }

  /// The app's reload count, or null when it has no counter.
  static Future<int?> _reloads(VmServiceClient client, String isolate) async {
    try {
      final result = await client.call(reloadsExtension, {
        'isolateId': isolate,
      });
      final reloads = result['reloads'];
      return reloads is int ? reloads : null;
    } on VmServiceException {
      return null;
    }
  }

  Future<String?> _readAddress() async {
    try {
      final text = (await addressFile.readAsString()).trim();
      return text.isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _remember(String address) async {
    try {
      await addressFile.writeAsString('$address\n');
    } on FileSystemException {
      // Only a convenience: the next call can give the address again.
    }
  }

  /// [path] relative to the working folder when under it.
  static String _shown(String path) {
    final here = '${Directory.current.path}/';
    return path.startsWith(here) ? path.substring(here.length) : path;
  }

  static Map<String, Object?> _ok(Map<String, Object?> result) => {
    'ok': true,
    'result': result,
  };

  static Map<String, Object?> _error(String message) => {
    'ok': false,
    'error': message,
  };
}
