import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../model/tape.dart';
import '../sink/bridge_client.dart';
import 'browser_page.dart';

/// What a replay that restarts the page leaves for the next start, in
/// `sessionStorage` (PLAN-v2 Milestone 15, step 7).
class BootFlag {
  const BootFlag({
    required this.tape,
    required this.run,
    required this.bridge,
    this.options = const <String, Object?>{},
    this.control = false,
  });

  static BootFlag? decode(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      final tape = json['tape'];
      final run = json['run'];
      final bridge = json['bridge'];
      if (tape is! String || run is! String || bridge is! String) return null;
      final options = json['options'];
      return BootFlag(
        tape: tape,
        run: run,
        bridge: bridge,
        options: options is Map<String, Object?> ? options : const {},
        control: json['control'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  /// The tape id.
  final String tape;

  /// The run id the bridge waits on.
  final String run;

  /// The bridge's base URL: the tape comes from there.
  final String bridge;

  /// `until`, `speed`, `unmatched`, `latency`, as the `replay` tool took
  /// them.
  final Map<String, Object?> options;

  /// Whether agent control was on: the replay was the agent's, and control
  /// comes back on after the restart so it can resume or stop the replay.
  final bool control;

  String encode() => jsonEncode({
    'tape': tape,
    'run': run,
    'bridge': bridge,
    'options': options,
    'control': control,
  });
}

/// The start of a page that a replay restarted.
///
/// `PinPoint.run` loads the tape before `runApp`, so the network source
/// answers from it before the app makes its first request. Without
/// `PinPoint.run`, the wrapper loads it at its start, and requests made
/// before the tape arrived were real: the result says so.
///
/// State is static: the flag is read once per page and shared by
/// `PinPoint.run`, the wrapper and the overlay.
abstract final class TapeBoot {
  /// The `sessionStorage` key. Pinpoint's own keys start with `pinpoint.`
  /// and are never copied into a tape.
  static const String key = 'pinpoint.replay';

  /// The page, replaceable in tests.
  static BrowserPage page = browserPage();

  static bool _read = false;
  static BootFlag? _flag;
  static Future<Tape?>? _loading;

  /// The tape, once loaded.
  static Tape? tape;

  /// Why the tape could not be loaded, or null.
  static String? error;

  /// Whether `PinPoint.run` loaded the tape before the app started.
  static bool loadedBeforeApp = false;

  /// Whether the replay of this start was handed to a player already.
  static bool started = false;

  /// The flag of this start, read and removed on first use, so a later
  /// reload by the user is a normal start.
  static BootFlag? get flag {
    if (!_read) {
      _read = true;
      if (page.available) {
        _flag = BootFlag.decode(page.sessionGet(key));
        if (_flag != null) page.sessionRemove(key);
      }
    }
    return _flag;
  }

  /// Leaves [flag] for the next start of the page.
  static void arm(BootFlag flag) => page.sessionSet(key, flag.encode());

  /// Loads the tape of this start from the bridge, once. With
  /// [restoreStorage] and a tape that kept storage, puts the storage back
  /// first (step 4). Completes with null when there is no flag or the
  /// load failed ([error] says why).
  static Future<Tape?> load({bool restoreStorage = false}) =>
      _loading ??= _load(restoreStorage);

  static Future<Tape?> _load(bool restoreStorage) async {
    final flag = TapeBoot.flag;
    if (flag == null) return null;
    try {
      final loaded = await BridgeClient(Uri.parse(flag.bridge))
          .loadTape(flag.tape);
      if (loaded == null) {
        error = 'the bridge has no tape ${flag.tape}';
        return null;
      }
      // Watch out for: the app checks the clock, and v2 does not fake time.
      // A token that was fresh when recorded is expired now, and the app
      // may log out; the first difference shows it. Putting back the
      // storage of the recording (TraceConfig.storage) is the fix, or an
      // app TraceSource for the session.
      final storage = loaded.start.storage;
      if (restoreStorage && storage != null) page.writeStorage(storage);
      return tape = loaded;
    } catch (failure) {
      error = 'could not load tape ${flag.tape}: $failure';
      debugPrint('pinpoint: $error');
      return null;
    }
  }

  /// Forgets everything, for tests.
  @visibleForTesting
  static void debugReset({BrowserPage? page}) {
    TapeBoot.page = page ?? browserPage();
    _read = false;
    _flag = null;
    _loading = null;
    tape = null;
    error = null;
    loadedBeforeApp = false;
    started = false;
  }
}
