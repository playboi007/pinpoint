import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../bridge/bridge_protocol.dart';
import '../model/annotation.dart';
import '../sink/bridge_client.dart';
import 'note_book.dart';

/// Keeps [notes] and the bridge in step.
///
/// - [load] once at start: a restarted app gets its pins back.
/// - While the overlay is active ([active]), asks the bridge what the
///   agent changed, and the bridge holds each request until there is
///   something to say (a long poll of [changesWait]). Never while idle.
/// - [save], [update] and [delete] write the app's own changes through.
///
/// A bridge that does not answer is not an error the user must act on: the
/// notes stay in this tab, and [onError] says so once per failure.
class NoteSync {
  NoteSync({
    required this.client,
    required this.notes,
    this.origin,
    this.onAgentChange,
    this.onError,
    String? clientId,
  }) : clientId = clientId ?? _newClientId();

  /// Tells this tab from another on the bridge: it is sent with every
  /// write and every `/changes` request, so the bridge leaves out the
  /// changes this tab made itself. A change by the agent has no id, so
  /// every tab gets it.
  final String clientId;

  static String _newClientId() {
    final random = math.Random();
    return 'c${random.nextInt(1 << 31).toRadixString(36)}'
        '${random.nextInt(1 << 31).toRadixString(36)}';
  }

  /// A held request that answers empty in less than this came from a
  /// bridge that does not hold requests (an older one): the next call
  /// waits [pollInterval], so such a bridge is asked as before, every 2 s.
  static const Duration minHold = Duration(seconds: 1);

  final BridgeClient client;
  final NoteBook notes;

  /// The page's origin. Only notes written on it are loaded, so two apps
  /// on one bridge (two tabs) never show each other's pins.
  final String? origin;

  /// The agent moved a note on, for example to resolved.
  final void Function(Annotation note)? onAgentChange;

  /// A call to the bridge failed.
  final void Function(String message)? onError;

  /// The origin of the page this app runs on, on web; else null.
  static String? pageOrigin() {
    if (!kIsWeb) return null;
    final base = Uri.base;
    return base.isScheme('http') || base.isScheme('https') ? base.origin : null;
  }

  String? _cursor;
  bool _active = false;
  bool _disposed = false;

  /// Bumped by every change of [active], so that when the overlay goes off
  /// and on again fast, only the newest loop runs.
  int _generation = 0;

  /// The request the loop holds open. Closing it ends it at once (on web,
  /// it aborts the XHR).
  http.Client? _held;
  Timer? _retryTimer;
  Completer<void>? _retryWait;

  /// Statuses the agent sets. A change to one of them is news for the user.
  static const Set<NoteStatus> _agentStatuses = {
    NoteStatus.inProgress,
    NoteStatus.fixed,
    NoteStatus.resolved,
    NoteStatus.rejected,
  };

  /// Whether the poll runs.
  bool get active => _active;

  /// Loads every note to show as a pin. Returns whether the bridge
  /// answered.
  Future<bool> load() async {
    try {
      final result = await client.load(origin: origin);
      if (_disposed) return false;
      _cursor = result.cursor;
      _merge(result.notes, announce: false);
      return true;
    } on Object {
      // Offline: try again when the overlay becomes active.
      return false;
    }
  }

  /// Starts or stops the poll. Polling must stop while the overlay is
  /// idle: it would keep the network panel noisy and the tab awake.
  set active(bool value) {
    if (value == _active || _disposed) return;
    _active = value;
    _generation++;
    _endLoop();
    if (value) unawaited(_loop(_generation));
  }

  /// Ends the request in flight and the pause between two, so a stopped
  /// loop does not outlive the call that stopped it.
  void _endLoop() {
    _held?.close();
    _held = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final pause = _retryWait;
    _retryWait = null;
    if (pause != null && !pause.isCompleted) pause.complete();
  }

  /// Asks, and asks again after each answer, while [generation] is the
  /// newest and the overlay is active.
  Future<void> _loop(int generation) async {
    bool live() => _active && !_disposed && generation == _generation;
    while (live()) {
      // A client of its own per request, so it can be closed (see
      // [_held]). Tests that fake the HTTP client cannot abort.
      final held = BridgeClient.debugClient == null ? http.Client() : null;
      _held = held;
      final asked = Stopwatch()..start();
      try {
        final news = await _step(held, live);
        if (!live()) return;
        if (!news && asked.elapsed < minHold) await _pause();
      } on Object {
        // Offline: try again after a pause. The badge says so already.
        if (!live()) return;
        await _pause();
      } finally {
        if (identical(_held, held)) _held = null;
        held?.close();
      }
    }
  }

  /// One request. Loads everything when there is no cursor yet or the
  /// bridge restarted. Returns whether the bridge had news.
  Future<bool> _step(http.Client? held, bool Function() live) async {
    final cursor = _cursor;
    if (cursor == null) return load();
    final changes = await client.changes(
      cursor,
      origin: origin,
      wait: changesWait,
      client: clientId,
      connection: held,
    );
    if (!live()) return false;
    if (changes.reset) {
      _cursor = null;
      return true;
    }
    _cursor = changes.cursor;
    for (final id in changes.deleted) {
      notes.remove(id);
    }
    _merge(changes.notes, announce: true);
    return changes.deleted.isNotEmpty || changes.notes.isNotEmpty;
  }

  Future<void> _pause() {
    final done = _retryWait = Completer<void>();
    _retryTimer = Timer(pollInterval, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  /// Stores [note] (a draft) on the bridge. Returns whether it took it.
  Future<bool> save(Annotation note) => _write(
    () => client.save(note, client: clientId),
    'Draft kept in this tab only',
  );

  /// Changes the note [id] on the bridge.
  Future<bool> update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? message,
  }) => _write(
    () => client.update(
      id,
      status: status,
      comment: comment,
      message: message,
      client: clientId,
    ),
    'Change kept in this tab only',
  );

  /// Undoes [changes] of round [round] of note [id] on the bridge (see
  /// [BridgeClient.undo]), and puts the note it answers with in the book:
  /// this tab's own write is left out of its `/changes`, so the answer is
  /// how the pin learns that the note is submitted again. Returns null when
  /// the call failed ([onError] says why).
  Future<UndoResult?> undo(
    String id, {
    required int round,
    required List<String> changes,
    String? reason,
  }) async {
    try {
      final result = await client.undo(
        id,
        round,
        changes,
        reason: reason,
        client: clientId,
      );
      if (!_disposed && result.note != null) {
        _merge([result.note!], announce: false);
      }
      return result;
    } on Object catch (error) {
      if (!_disposed) onError?.call('Undo failed: $error');
      return null;
    }
  }

  /// Deletes the note [id] on the bridge.
  Future<bool> delete(String id) => _write(
    () => client.delete(id, client: clientId),
    'Deleted in this tab only',
  );

  Future<bool> _write(Future<void> Function() call, String fallback) async {
    try {
      await call();
      return true;
    } on Object catch (error) {
      if (!_disposed) onError?.call('$fallback: $error');
      return false;
    }
  }

  /// Puts [remote] notes in the book. The app's own copy keeps what the
  /// bridge does not store: the PNG bytes of a draft not yet sent, and an
  /// anchor moved by an edit.
  void _merge(List<Annotation> remote, {required bool announce}) {
    final merged = <Annotation>[];
    for (final note in remote) {
      final local = notes.byId(note.id);
      var next = note;
      if (local != null) {
        final shot = local.screenshot;
        if (shot?.png != null) next = next.withScreenshot(shot);
        if (local.anchor case final anchor?) {
          next = next.copyWith(anchor: () => anchor);
        }
      }
      merged.add(next);
      if (announce &&
          local != null &&
          local.status != note.status &&
          _agentStatuses.contains(note.status)) {
        onAgentChange?.call(next);
      }
    }
    if (merged.isNotEmpty) notes.putAll(merged);
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _endLoop();
  }
}
