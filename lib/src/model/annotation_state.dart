part of 'annotation.dart';

/// An object that holds state for the target widget.
class StateOwnerInfo {
  const StateOwnerInfo({
    required this.kind,
    required this.type,
    this.source,
    this.dependencies = const <DependencyInfo>[],
  });

  static StateOwnerInfo? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final kind = json['kind'];
    final type = json['type'];
    if (kind is! String || type is! String) return null;
    return StateOwnerInfo(
      kind: kind,
      type: type,
      source: SourceRef._fromJson(json['source']),
      dependencies: [
        for (final d in asJsonList(json['dependencies']))
          ?DependencyInfo._fromJson(d),
      ],
    );
  }

  /// `state` (a `State` of a widget made in the project), `provider` (a
  /// provider-like scope), `notifier` (an `InheritedNotifier`) or `reader`
  /// (a stateless widget made in the project that reads a state object).
  final String kind;

  /// For example `ProductDetailProvider`: the `State`'s type, or the value
  /// type of the scope.
  final String type;

  /// The creating widget's file and line, when it is local.
  final SourceRef? source;

  /// The state objects this owner reads, at most [maxDependencies]: what
  /// its `build` asked for with `watch`, `of`
  /// or `dependOnInheritedWidgetOfExactType`. Framework scopes such as
  /// `MediaQuery` are left out. Empty for a provider-like scope.
  final List<DependencyInfo> dependencies;

  /// Most dependencies kept for one owner.
  static const int maxDependencies = 4;

  StateOwnerInfo withoutDependencies() =>
      StateOwnerInfo(kind: kind, type: type, source: source);

  Map<String, Object?> toJson() => {
    'kind': kind,
    'type': type,
    'source': source?.toJson(),
    if (dependencies.isNotEmpty)
      'dependencies': [for (final d in dependencies) d.toJson()],
  };
}

/// One object a state owner reads.
class DependencyInfo {
  const DependencyInfo({
    required this.kind,
    required this.type,
    required this.tag,
    this.source,
  });

  static DependencyInfo? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final kind = json['kind'];
    final type = json['type'];
    final tag = json['tag'];
    if (kind is! String || type is! String || tag is! String) return null;
    return DependencyInfo(
      kind: kind,
      type: type,
      tag: tag,
      source: SourceRef._fromJson(json['source']),
    );
  }

  /// `provider` (a provider-like scope), `notifier` (an `InheritedNotifier`)
  /// or `inherited` (any other inherited widget that is not the
  /// framework's).
  final String kind;

  /// The provided value's type (`ProductDetailProvider`), or the inherited
  /// widget's own type.
  final String type;

  /// A short name for the object, for example `#a1`. Two owners that show
  /// the same tag read the same object. Stable while the lens runs.
  final String tag;

  /// Where the scope was created, when that is in the project.
  final SourceRef? source;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'type': type,
    'tag': tag,
    'source': source?.toJson(),
  };
}

/// The children of the nearest ancestor with more than one child.
///
/// [children] is a window around the target's branch: [firstIndex] is the
/// index of its first entry, [count] the number of children in all.
class SiblingsInfo {
  const SiblingsInfo({
    required this.parent,
    required this.index,
    required this.count,
    required this.firstIndex,
    required this.children,
  });

  static SiblingsInfo? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final parent = json['parent'];
    if (parent is! String) return null;
    return SiblingsInfo(
      parent: parent,
      index: asInt(json['index']) ?? 0,
      count: asInt(json['count']) ?? 0,
      firstIndex: asInt(json['firstIndex']) ?? 0,
      children: asStrings(json['children']),
    );
  }

  final String parent;

  /// The index of the child that holds the target.
  final int index;

  final int count;
  final int firstIndex;
  final List<String> children;

  Map<String, Object?> toJson() => {
    'parent': parent,
    'index': index,
    'count': count,
    'firstIndex': firstIndex,
    'children': children,
  };
}

/// Inherited values seen by the target.
class InheritedInfo {
  const InheritedInfo({
    this.themeBrightness,
    this.useMaterial3,
    this.textDirection,
  });

  factory InheritedInfo._fromJson(Map<String, Object?> json) => InheritedInfo(
    themeBrightness: asString(json['themeBrightness']),
    useMaterial3: json['useMaterial3'] is bool
        ? json['useMaterial3']! as bool
        : null,
    textDirection: asString(json['textDirection']),
  );

  final String? themeBrightness;
  final bool? useMaterial3;
  final String? textDirection;

  Map<String, Object?> toJson() => {
    'themeBrightness': themeBrightness,
    'useMaterial3': useMaterial3,
    'textDirection': textDirection,
  };
}
