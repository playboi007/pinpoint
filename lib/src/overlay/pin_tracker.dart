import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/note_book.dart';
import '../model/annotation.dart';
import '../search/render_search.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';

/// Where one pin is drawn.
@immutable
class PinPlacement {
  const PinPlacement({
    required this.id,
    required this.number,
    required this.status,
    required this.rect,
    this.checksPassed,
  });

  final String id;

  /// 1-based, as in [NoteBook.numberOf].
  final int number;

  final NoteStatus status;

  /// The visible part of the anchor's widget, in global logical pixels.
  final Rect rect;

  /// The outcome of the note's last `verify_note`; null when none ran.
  final bool? checksPassed;

  @override
  bool operator ==(Object other) =>
      other is PinPlacement &&
      other.id == id &&
      other.number == number &&
      other.status == status &&
      other.rect == rect &&
      other.checksPassed == checksPassed;

  @override
  int get hashCode => Object.hash(id, number, status, rect, checksPassed);
}

/// Keeps each pin on its widget.
///
/// After each frame the app draws, every pin is placed again: its element
/// is kept while it still matches the anchor (cheap: a mounted check and a
/// cached location), and looked up again with [SourceIndex] otherwise, for
/// all such pins in one walk. A pin whose anchor matches nothing is looked
/// up again at most every [retryInterval] of frame time, since that walk
/// covers the whole app. A lookup skipped for that reason runs once more
/// after the interval, so a pin whose widget came back in the last frame
/// still shows when the app stops drawing.
///
/// Each lookup that finds nothing doubles the interval, up to
/// [maxRetryInterval]: a note on another page would otherwise walk the
/// whole app twice a second for as long as frames are drawn (hovering
/// draws them), and in a debug web build one walk takes 20 to 60 ms. A
/// change of the page URL, of the notes, or a hot reload looks again at
/// once.
///
/// Like `PickTracker`, it never schedules a frame on its own while nothing
/// changes (engineering rule 2).
class PinTracker {
  PinTracker({
    required this.notes,
    required this.contentKey,
    required SourceResolver resolver,
  }) : _index = SourceIndex(resolver: resolver) {
    _frameHook.tracker = this;
    // A persistent frame callback cannot be removed (docs/api-notes.md,
    // item 7); the hook drops its tracker on dispose.
    SchedulerBinding.instance.addPersistentFrameCallback(_frameHook.onFrame);
    notes.addListener(_onNotes);
  }

  /// Frame time between lookups of a pin that matched nothing.
  static const Duration retryInterval = Duration(milliseconds: 500);

  /// The longest wait between lookups that keep finding nothing.
  static const Duration maxRetryInterval = Duration(seconds: 4);

  /// The page URL, read after each frame to see a navigation. Tests set it.
  @visibleForTesting
  static Uri Function()? debugUrl;

  final NoteBook notes;

  /// Key of the element directly above the app's own widgets: the root of
  /// every lookup.
  final GlobalKey contentKey;

  SourceIndex _index;

  /// Replaced when the project root or the path hints change.
  set resolver(SourceResolver value) {
    _index = SourceIndex(resolver: value);
    _elements.clear();
  }

  final ValueNotifier<List<PinPlacement>> _placements =
      ValueNotifier<List<PinPlacement>>(const <PinPlacement>[]);

  /// The pins on screen, in number order.
  ValueListenable<List<PinPlacement>> get placements => _placements;

  final _FrameHook _frameHook = _FrameHook();
  final Map<String, Element> _elements = <String, Element>{};
  bool _armed = false;
  bool _disposed = false;
  Duration _frameTime = Duration.zero;
  Duration? _lastRetry;
  Timer? _retryTimer;

  /// Lookups in a row that found none of the lost pins.
  int _misses = 0;
  String? _url;

  Duration get _retryWait {
    final wait = retryInterval * (1 << _misses);
    return wait < maxRetryInterval ? wait : maxRetryInterval;
  }

  /// The live element of the note [id]'s pin, or null when it shows none.
  Element? elementOf(String id) {
    final element = _elements[id];
    return element != null && element.mounted ? element : null;
  }

  /// Records that the note [id] belongs to [element], so a new pin shows at
  /// once without a lookup.
  void seed(String id, Element element) {
    _elements[id] = element;
  }

  /// Forgets every element, for example after a hot reload: elements may
  /// be stale, and edited lines are read again.
  void reset() {
    _elements.clear();
    _lastRetry = null;
    _misses = 0;
  }

  /// One lookup after the throttle, from a timer: no frame is drawn for it
  /// unless a pin moves (engineering rule 2).
  void _scheduleRetry(Duration wait) {
    if (_retryTimer != null || _disposed) return;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      if (_disposed) return;
      _lastRetry = null;
      refresh(fromTimer: true);
    });
  }

  void _onNotes() {
    // A new, changed or deleted note: place the pins in the next frame the
    // app draws. Adding a pin repaints Pinpoint's layer, which draws one.
    _misses = 0;
    _arm();
  }

  void _onFrame(Duration timeStamp) {
    _frameTime = timeStamp;
    _arm();
  }

  void _arm() {
    if (_armed || _disposed) return;
    if (notes.pinned.isEmpty && _placements.value.isEmpty) return;
    _armed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _armed = false;
      if (!_disposed) refresh();
    }, debugLabel: 'pinpoint.placePins');
  }

  /// Places every pin now. Called after each drawn frame; tests may call it
  /// directly.
  @visibleForTesting
  void refresh({bool fromTimer = false}) {
    final root = contentKey.currentContext;
    final pinned = notes.pinned;
    if (root is! Element || !root.mounted) {
      _set(const <PinPlacement>[]);
      return;
    }
    _elements.removeWhere((id, _) => !pinned.any((n) => n.id == id));

    // A new page: its widgets may be the lost ones, so look now. On web
    // this reads `window.location`, which costs no walk.
    final url = (debugUrl ?? () => Uri.base)().toString();
    if (url != _url) {
      _url = url;
      _misses = 0;
      _lastRetry = null;
    }

    final lost = <Annotation>[];
    for (final note in pinned) {
      final anchor = note.anchor;
      if (anchor == null || !anchor.resolvable) continue;
      final element = _elements[note.id];
      if (element == null || !_index.stillMatches(element, anchor)) {
        _elements.remove(note.id);
        lost.add(note);
      }
    }
    final retry = _lastRetry;
    final waited = retry == null ? null : _frameTime - retry;
    final wait = _retryWait;
    if (lost.isNotEmpty && waited != null && waited < wait) {
      if (!fromTimer) _scheduleRetry(wait - waited);
    } else if (lost.isNotEmpty) {
      _lastRetry = _frameTime;
      final found = _index.resolveAll([
        for (final note in lost) note.anchor!,
      ], root: root);
      var any = false;
      for (final note in lost) {
        final element = found[note.anchor!];
        if (element != null) {
          _elements[note.id] = element;
          any = true;
        }
      }
      if (any) {
        _misses = 0;
      } else if (_retryWait < maxRetryInterval) {
        _misses++;
      }
    }

    final next = <PinPlacement>[];
    for (final (i, note) in pinned.indexed) {
      final element = _elements[note.id];
      if (element == null) continue;
      _followEdits(note, element);
      final RenderObject? renderObject;
      try {
        renderObject = element.renderObject;
      } catch (_) {
        continue;
      }
      if (renderObject == null) continue;
      // Hidden when its route is beneath another, or scrolled out of its
      // viewport.
      final rect = RenderSearch.visibleRectOf(renderObject);
      if (rect == null || rect.isEmpty) continue;
      next.add(
        PinPlacement(
          id: note.id,
          number: i + 1,
          status: note.status,
          rect: rect,
          checksPassed: note.checksPassed,
        ),
      );
    }
    _set(next);
  }

  /// When an edit and a hot reload moved the widget, the anchor moves with
  /// it, so the next edit is measured from the new line.
  void _followEdits(Annotation note, Element element) {
    final anchor = note.anchor!;
    final location = _index.resolver.locationOf(element);
    if (location == null) return;
    if (location.line == anchor.line && location.column == anchor.column) {
      return;
    }
    notes.moveAnchor(
      note.id,
      anchor.movedTo(line: location.line, column: location.column),
    );
  }

  // Set only when it changed: a post-frame change schedules a frame
  // (docs/api-notes.md, item 7), and that frame must find nothing to do.
  void _set(List<PinPlacement> next) {
    if (listEquals(next, _placements.value)) return;
    _placements.value = next;
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _frameHook.tracker = null;
    notes.removeListener(_onNotes);
    _placements.dispose();
  }
}

/// The persistent frame callback's only reference to its tracker.
class _FrameHook {
  PinTracker? tracker;

  void onFrame(Duration timeStamp) => tracker?._onFrame(timeStamp);
}
