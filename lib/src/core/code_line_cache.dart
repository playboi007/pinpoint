import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sink/bridge_client.dart';
import '../trace/code_lines.dart';

/// The source lines under the chain rows of the state lens, asked from the
/// bridge (`GET /source`) once per `file:line` for the whole Pinpoint
/// session.
///
/// A lookup that finds nothing (the bridge answered 400, 403 or 404, or
/// null, or failed) is kept as "no lines" and never asked again: the
/// browser logs each 404 as a red console line, and the answer does not
/// change while the app runs. The State tab and the watch card share one
/// cache (`PinPointController.codeLines`), so closing and opening them asks
/// nothing new.
///
/// Notifies when lines for a new key arrive.
class CodeLineCache extends ChangeNotifier {
  /// Files that are never asked for: no source file of the project.
  static const List<String> skippedPrefixes = <String>[
    'package:',
    'dart:',
    'lib/_engine',
    'packages/',
  ];

  /// Whether the bridge is asked for [file]: a Dart file that is not in a
  /// package, the SDK or the web engine.
  static bool askable(String file) {
    if (!file.endsWith('.dart')) return false;
    for (final prefix in skippedPrefixes) {
      if (file.startsWith(prefix)) return false;
    }
    return true;
  }

  // Lines per key; a null value is a lookup that found nothing.
  final Map<String, List<String>?> _lines = <String, List<String>?>{};
  final Set<String> _asked = <String>{};
  bool _disposed = false;

  /// How many requests went out in this session.
  int get requests => _asked.length;

  /// The lines around [file]:[line], or null when there are none (yet).
  List<String>? linesAt(Object? file, Object? line) {
    final found = _lines['$file:$line'];
    return found == null || found.isEmpty ? null : found;
  }

  /// Asks the bridge for the lines around [file]:[line], once. Does nothing
  /// for a file that [askable] refuses, a line below 1, a key that was asked
  /// before, or when [bridge] gives no client (the key stays unasked then).
  void need(Object? file, Object? line, BridgeClient? Function()? bridge) {
    if (file is! String || line is! int || line < 1) return;
    if (!askable(file)) return;
    final key = '$file:$line';
    if (_asked.contains(key)) return;
    final client = bridge?.call();
    if (client == null) return;
    _asked.add(key);
    unawaited(_fetch(key, client, file, line));
  }

  Future<void> _fetch(
    String key,
    BridgeClient client,
    String file,
    int line,
  ) async {
    List<String>? lines;
    try {
      final snippet = await client.source(file, line);
      if (snippet != null) {
        lines = codeLinesAt(snippet.text, snippet.start, line);
      }
    } catch (_) {
      lines = null;
    }
    if (_disposed) return;
    if (lines == null || lines.isEmpty) {
      // Nothing new to show: no notify, and no second request.
      _lines[key] = null;
      return;
    }
    _lines[key] = lines;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
