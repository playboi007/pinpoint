import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../info/widget_info.dart';
import '../model/annotation.dart' show clipText;
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

  /// The widget's own value, from before the first edit.
  final Object? original;

  /// [original] as the panel showed it, for example `EdgeInsets.all(8.0)`.
  final String fromLabel;

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
/// or repaints as if the widget had the value.
class TweakSession extends ChangeNotifier {
  final List<Tweak> _tweaks = <Tweak>[];

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
    if (existing != null) {
      existing
        ..value = value
        ..toLabel = after.label;
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

  /// The notes' diff: one from-and-to pair per edit, at most [max].
  List<Map<String, Object?>> toJson({int max = 20}) => [
    for (final tweak in _tweaks.take(max)) tweak.toJson(),
  ];

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
