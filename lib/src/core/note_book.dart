import 'package:flutter/foundation.dart';

import '../model/annotation.dart';

/// The notes this app knows about: drafts written here, sent notes, and
/// notes loaded from the bridge. Each one with a status other than
/// [NoteStatus.verified] shows as a pin.
///
/// Ordered by creation time, so a pin keeps its number across a restart.
class NoteBook extends ChangeNotifier {
  final List<Annotation> _notes = <Annotation>[];

  /// Every note, oldest first.
  List<Annotation> get notes => List<Annotation>.unmodifiable(_notes);

  /// The notes that show as pins, oldest first. A verified note is done:
  /// the user accepted the result.
  List<Annotation> get pinned => [
    for (final note in _notes)
      if (note.status != NoteStatus.verified) note,
  ];

  /// The drafts, oldest first.
  List<Annotation> get drafts => [
    for (final note in _notes)
      if (note.status == NoteStatus.draft) note,
  ];

  /// The note with [id], or null.
  Annotation? byId(String id) {
    for (final note in _notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  /// The pin number of the note with [id]: its 1-based place in [pinned],
  /// or null when it shows no pin.
  int? numberOf(String id) {
    final pins = pinned;
    for (var i = 0; i < pins.length; i++) {
      if (pins[i].id == id) return i + 1;
    }
    return null;
  }

  /// Adds [note], or replaces the note with its id.
  void put(Annotation note) {
    final at = _notes.indexWhere((n) => n.id == note.id);
    if (at >= 0) {
      _notes[at] = note;
    } else {
      _notes
        ..add(note)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    notifyListeners();
  }

  /// Puts every note in [notes] in at once, with one notification.
  void putAll(Iterable<Annotation> notes) {
    for (final note in notes) {
      final at = _notes.indexWhere((n) => n.id == note.id);
      if (at >= 0) {
        _notes[at] = note;
      } else {
        _notes.add(note);
      }
    }
    _notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    notifyListeners();
  }

  /// Removes the note with [id]. Returns whether there was one.
  bool remove(String id) {
    final before = _notes.length;
    _notes.removeWhere((n) => n.id == id);
    if (_notes.length == before) return false;
    notifyListeners();
    return true;
  }

  /// Records that the note's widget is now at [anchor], for example after
  /// an edit moved it ten lines down. Nobody is told: the pin is already
  /// there, and the next edit is measured from here.
  void moveAnchor(String id, NoteAnchor anchor) {
    final at = _notes.indexWhere((n) => n.id == id);
    if (at < 0) return;
    _notes[at] = _notes[at].copyWith(anchor: () => anchor);
  }
}
