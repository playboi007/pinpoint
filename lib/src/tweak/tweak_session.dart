import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show Element;

import '../info/widget_info.dart';
import '../model/annotation.dart' show clipText;
import '../search/render_search.dart';
import 'tweak_scope.dart';

/// One live edit: a property of a render object, its value before the
/// first edit and the value it has now.
class Tweak {
  Tweak._({
    required this.target,
    required this.property,
    required this.original,
    required this.fromLabel,
    required this.value,
    required this.toLabel,
  });

  /// The section and render object the property belongs to.
  final TweakTarget target;

  /// For example `padding`.
  final String property;

  /// The widget's own value: from before the first edit, or the last value
  /// the widget wrote back over the edit.
  Object? original;

  /// [original] as the panel showed it, for example `EdgeInsets.all(8.0)`.
  String fromLabel;

  /// True when the widget wrote its own value back more than
  /// [TweakSession.maxResetsPerSecond] times in a second: it is animating,
  /// and the edit cannot hold. The session stops putting it back.
  bool animating = false;

  /// When the widget wrote its own value back, within the last second.
  final List<Duration> _resets = <Duration>[];

  /// The value to keep.
  Object? value;

  /// [value] as the panel shows it.
  String toLabel;

  RenderObject get renderObject => target.renderObject;

  /// For example `RenderPadding`.
  String get renderType => renderObject.runtimeType.toString();

  /// The from-and-to pair for the note, as the agent applies it in source.
  Map<String, Object?> toJson() => {
    'renderType': renderType,
    'property': property,
    'from': clipText(fromLabel, _maxLabel),
    'to': clipText(toLabel, _maxLabel),
    'createdBy': target.createdBy,
    'nearestLocal': target.nearestLocal?.toJson(),
  };

  static const int _maxLabel = 200;

  bool _matches(TweakTarget other, String name) =>
      identical(other.renderObject, renderObject) &&
      other.section.title == target.section.title &&
      name == property;
}

/// The live edits on screen.
///
/// Changes go straight to the render objects' setters, so the app relayouts
/// or repaints as if the widget had the value. A widget that builds again
/// writes its own values back, so after each frame the app draws, every
/// edit is read again and put back if it was reset: at most one frame shows
/// the old value. Nothing runs while no frame is drawn (engineering rule 2).
class TweakSession extends ChangeNotifier {
  /// More resets than this in a second mark an edit as animating.
  static const int maxResetsPerSecond = 5;

  /// The most edits a note lists; more are named in its `truncated`.
  static const int maxInNote = 20;

  final List<Tweak> _tweaks = <Tweak>[];
  final ValueNotifier<List<Rect>> _outlines = ValueNotifier<List<Rect>>(
    const <Rect>[],
  );
  final _FrameHook _frameHook = _FrameHook();
  bool _hooked = false;
  bool _checkArmed = false;
  bool _suspended = false;
  bool _disposed = false;

  /// The on-screen rects of the edited render objects, in global logical
  /// pixels, as of the last drawn frame. The overlay outlines them, so a
  /// changed screen is never taken for the real one.
  ValueListenable<List<Rect>> get outlines => _outlines;

  /// Whether the edits are taken off for a moment (the "before" image).
  bool get suspended => _suspended;

  /// Every active edit, oldest first.
  List<Tweak> get tweaks => List<Tweak>.unmodifiable(_tweaks);

  int get length => _tweaks.length;

  bool get isEmpty => _tweaks.isEmpty;

  /// The edit of [property] in [target]'s section, or null.
  Tweak? tweakOf(TweakTarget target, String property) {
    for (final tweak in _tweaks) {
      if (tweak._matches(target, property)) return tweak;
    }
    return null;
  }

  /// Sets [property] of [target] to [value].
  ///
  /// Returns false, with nothing changed, when the property is not editable
  /// or did not take the value (read back, it differs). Setting the widget's
  /// own value again ends the edit.
  ///
  /// Call from an input handler or a post-frame callback: a render object
  /// asserts when a setter runs during layout or paint.
  bool apply(TweakTarget target, String property, Object? value) {
    assert(
      _canWrite,
      'Tweaks are applied from input handlers and post-frame callbacks '
      'only, never during build, layout or paint.',
    );
    final current = _read(target, property);
    if (current == null || !current.editable) return false;
    final existing = tweakOf(target, property);
    final original = existing == null ? current.value : existing.original;
    final fromLabel = existing?.fromLabel ?? current.label;
    final previous = current.value;
    try {
      current.applyValue(value);
    } catch (_) {
      return false;
    }
    final after = _read(target, property);
    if (after == null || after.value != value) {
      // It did not take: a value the render object refuses or rewrites.
      _restore(target, property, previous);
      return false;
    }
    if (value == original) {
      if (existing != null) {
        _tweaks.remove(existing);
        notifyListeners();
      }
      return true;
    }
    _hook();
    if (existing != null) {
      existing
        ..value = value
        ..toLabel = after.label
        ..animating = false
        .._resets.clear();
    } else {
      _tweaks.add(
        Tweak._(
          target: target,
          property: property,
          original: original,
          fromLabel: fromLabel,
          value: value,
          toLabel: after.label,
        ),
      );
    }
    notifyListeners();
    return true;
  }

  /// Puts [tweak]'s render object back to the widget's own value and ends
  /// the edit.
  void reset(Tweak tweak) {
    if (!_tweaks.remove(tweak)) return;
    _restore(tweak.target, tweak.property, tweak.original);
    notifyListeners();
  }

  /// Ends every edit: puts back each widget's own value, then asks each
  /// owning element to build again, so the widget writes its values itself
  /// (a value [Tweak.original] missed included).
  void resetAll() {
    if (_tweaks.isEmpty) return;
    final owners = <Element>{};
    for (final tweak in _tweaks.reversed) {
      _restore(tweak.target, tweak.property, tweak.original);
      final owner = tweak.target.owner;
      if (owner != null) owners.add(owner);
    }
    _tweaks.clear();
    for (final owner in owners) {
      if (owner.mounted) owner.markNeedsBuild();
    }
    notifyListeners();
  }

  /// Takes every edit off for a moment, for the "before" image of a note:
  /// each render object gets the widget's own value. The edits stay in
  /// the list; [resume] puts them back.
  void suspend() {
    if (_suspended) return;
    _suspended = true;
    for (final tweak in _tweaks) {
      _restore(tweak.target, tweak.property, tweak.original);
    }
  }

  /// Puts back every edit [suspend] took off.
  void resume() {
    if (!_suspended) return;
    _suspended = false;
    for (final tweak in _tweaks) {
      if (!tweak.animating) _restore(tweak.target, tweak.property, tweak.value);
    }
  }

  /// The notes' diff: one from-and-to pair per edit, at most [max].
  List<Map<String, Object?>> toJson({int max = maxInNote}) => [
    for (final tweak in _tweaks.take(max)) tweak.toJson(),
  ];

  void _hook() {
    if (_hooked) return;
    _hooked = true;
    _frameHook.session = this;
    // There is no way to remove a persistent frame callback
    // (docs/api-notes.md, item 7). The hook drops its session on dispose.
    SchedulerBinding.instance.addPersistentFrameCallback(_frameHook.onFrame);
  }

  // Runs in the persistent phase of every frame, where a render object
  // must not be changed (it is being laid out). Arm a post-frame callback
  // instead: there the frame is done and a change asks for the next one.
  void _onFrame() {
    if (_checkArmed || (_tweaks.isEmpty && _outlines.value.isEmpty)) return;
    _checkArmed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkArmed = false;
      if (!_disposed) _check();
    }, debugLabel: 'pinpoint.reapplyTweaks');
  }

  /// Puts back every edit the frame just drawn reset, drops edits whose
  /// render object is gone, and reads the outlines.
  void _check() {
    var changed = false;
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    for (final tweak in List<Tweak>.of(_tweaks)) {
      if (!tweak.renderObject.attached) {
        _tweaks.remove(tweak);
        changed = true;
        continue;
      }
      if (_suspended || tweak.animating) continue;
      final current = _read(tweak.target, tweak.property);
      if (current == null) {
        _tweaks.remove(tweak);
        changed = true;
        continue;
      }
      if (current.value == tweak.value) continue;
      // The widget built again and wrote its own value: that is its value
      // now, and the one a reset puts back.
      tweak
        ..original = current.value
        ..fromLabel = current.label
        .._resets.add(now)
        .._resets.removeWhere((t) => now - t > const Duration(seconds: 1));
      if (tweak._resets.length > maxResetsPerSecond) {
        tweak.animating = true;
        changed = true;
        continue;
      }
      // Only when the value really changed: this asks for one more frame,
      // which finds nothing to do (engineering rule 2).
      try {
        current.applyValue(tweak.value);
      } catch (_) {
        _tweaks.remove(tweak);
        changed = true;
      }
    }
    final rects = [
      for (final tweak in _tweaks)
        ?RenderSearch.visibleRectOf(tweak.renderObject),
    ];
    if (!listEquals(rects, _outlines.value)) _outlines.value = rects;
    if (changed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _frameHook.session = null;
    _outlines.dispose();
    super.dispose();
  }

  static bool get _canWrite =>
      switch (SchedulerBinding.instance.schedulerPhase) {
        SchedulerPhase.idle || SchedulerPhase.postFrameCallbacks => true,
        _ => false,
      };

  /// [property] as [target]'s extractor reads it now, or null.
  static InfoProperty<Object?>? _read(TweakTarget target, String property) {
    try {
      final section = target.extractor(target.renderObject);
      if (section == null) return null;
      for (final p in section.properties) {
        if (p.name == property) return p;
      }
    } catch (_) {
      // A render object that throws while read cannot be tweaked.
    }
    return null;
  }

  static void _restore(TweakTarget target, String property, Object? value) {
    try {
      _read(target, property)?.applyValue(value);
    } catch (_) {
      // Nothing more to do: the next build writes the widget's value.
    }
  }
}

/// The persistent frame callback's only reference to its session.
class _FrameHook {
  TweakSession? session;

  void onFrame(Duration _) => session?._onFrame();
}
