import 'dart:convert';
import 'dart:developer' as developer;

import '../bridge/bridge_protocol.dart';

/// Counts the app's hot reloads, and gives the count to the bridge as the
/// service extension `ext.pinpoint.reloads`.
///
/// The bridge's `hot_reload` tool reads it before and after it asks for a
/// reload. On web the reload service answers success even when the code
/// did not compile (the web runner drops its result), so only a count that
/// went up says the new code runs.
///
/// Everything is static: a hot reload does not run the initializer of a
/// new instance field in a state that already exists (docs/api-notes.md,
/// item 29), and the count must outlive each reload. A hot restart starts
/// it again at 0.
abstract final class ReloadCounter {
  /// The extension's name.
  static const String method = reloadsExtension;

  /// Hot reloads since the app started.
  static int count = 0;

  static bool _registered = false;

  /// Registers [method] once per isolate. On web it registers only while a
  /// debugger is attached (docs/api-notes.md, item 14), which is the case
  /// whenever the bridge can ask for a reload.
  static void register() {
    if (_registered) return;
    _registered = true;
    try {
      developer.registerExtension(method, (name, params) async {
        return developer.ServiceExtensionResponse.result(answer());
      });
    } catch (_) {
      // Registered by an earlier Pinpoint in this isolate.
    }
  }

  /// One hot reload is done.
  static void reloaded() => count++;

  /// The extension's answer, as JSON.
  static String answer() => jsonEncode({'reloads': count});
}
