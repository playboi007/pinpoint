import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bridge_protocol.dart';
import '../model/annotation.dart';
import '../sink/bridge_client.dart';
import 'note_book.dart';

/// Keeps [notes] and the bridge in step.
///
/// - [load] once at start: a restarted app gets its pins back.
/// - While the overlay is active ([active]), asks the bridge every
///   [pollInterval] what the agent changed. Never while idle.
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
  });

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
  Timer? _timer;
  bool _active = false;
  bool _busy = false;
  bool _disposed = false;

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
    _timer?.cancel();
    _timer = null;
    if (!value) return;
    unawaited(poll());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  /// Asks once what changed. Loads everything when there is no cursor yet
  /// or the bridge restarted.
  Future<void> poll() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final cursor = _cursor;
      if (cursor == null) {
        await load();
        return;
      }
      final changes = await client.changes(cursor, origin: origin);
      if (_disposed) return;
      if (changes.reset) {
        _cursor = null;
        await load();
        return;
      }
      _cursor = changes.cursor;
      for (final id in changes.deleted) {
        notes.remove(id);
      }
      _merge(changes.notes, announce: true);
    } on Object {
      // Offline: the next tick tries again. The badge says so already.
    } finally {
      _busy = false;
    }
  }

  /// Stores [note] (a draft) on the bridge. Returns whether it took it.
  Future<bool> save(Annotation note) =>
      _write(() => client.save(note), 'Draft kept in this tab only');

  /// Changes the note [id] on the bridge.
  Future<bool> update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? message,
  }) => _write(
    () => client.update(id, status: status, comment: comment, message: message),
    'Change kept in this tab only',
  );

  /// Deletes the note [id] on the bridge.
  Future<bool> delete(String id) =>
      _write(() => client.delete(id), 'Deleted in this tab only');

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
    _timer?.cancel();
  }
}
