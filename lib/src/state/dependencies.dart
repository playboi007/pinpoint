import 'package:flutter/widgets.dart';

import '../model/annotation.dart'
    show DependencyInfo, SourceRef, StateOwnerInfo, clipText;
import '../model/source_location.dart';
import '../search/source_resolver.dart';

/// Who reads what (PLAN-v3 Milestone 21, step 1): for an element, the
/// nearest local build owners and the state objects each one depends on.
///
/// No hook and no listener: `Element.debugFillProperties` adds a
/// `dependencies` property whose value is the real `Set<InheritedElement>`
/// (`widgets/framework.dart`, `Element.debugFillProperties`). It is read
/// through `toDiagnosticsNode().getProperties()`, which is public;
/// `debugFillProperties` itself is protected.

/// Base type names of inherited widgets that the framework owns. They are
/// not state the app wrote, so they are never listed as a dependency. A
/// base name is the type name without its type arguments and without a
/// leading `_`.
///
/// One list: add a name here when a framework scope shows up in a note.
const Set<String> frameworkInheritedWidgets = <String>{
  'MediaQuery',
  'Theme',
  'InheritedTheme',
  'Directionality',
  'DefaultTextStyle',
  'DefaultTextHeightBehavior',
  'DefaultSelectionStyle',
  'IconTheme',
  'ListTileTheme',
  'ButtonTheme',
  'FocusInheritedScope',
  'FocusTraversalOrder',
  'FocusTraversalGroup',
  'Localizations',
  'LocalizationsScope',
  'DefaultAssetBundle',
  'ScrollConfiguration',
  'PrimaryScrollController',
  'ScrollNotificationObserver',
  'ScrollNotificationObserverScope',
  'HeroControllerScope',
  'ModalScopeStatus',
  'ModalScope',
  'PageStorage',
  'RestorationScope',
  'UnmanagedRestorationScope',
  'ActionsScope',
  'ShortcutsScope',
  'EffectiveTickerMode',
  'TickerMode',
  'ScaffoldScope',
  'ScaffoldMessengerScope',
  'FormScope',
  'TabControllerScope',
  'MediaQueryFromView',
  'ViewScope',
};

/// Gives each state object a short name for the length of the lens
/// session, for example `#a1` (PLAN-v3 Milestone 21, step 1).
///
/// The tag is kept in an [Expando], so it lives as long as the object and
/// leaves no reference behind. Two readers that show the same tag read one
/// object, which is shape 3 of the lens.
class IdentityTags {
  IdentityTags();

  /// The registry the lens uses. A test makes its own.
  static final IdentityTags shared = IdentityTags();

  final Expando<String> _tags = Expando<String>('pinpoint identity tags');
  int _next = 1;

  /// The tag of [object]; the same text for the same object, every time.
  String of(Object object) {
    try {
      return _tags[object] ??= '#a${_next++}';
    } catch (_) {
      // An Expando cannot hold a number, a string, a bool or a record.
      return '#a${_next++}';
    }
  }

  /// Whether [object] can carry a tag. A value that is a number or a
  /// string is tagged through the element that provides it.
  static bool canTag(Object? object) =>
      object != null &&
      object is! num &&
      object is! String &&
      object is! bool &&
      object is! Record;
}

/// One state object an element reads, with the live objects behind it.
class DependencyRef {
  DependencyRef({
    required this.element,
    required this.kind,
    required this.type,
    required this.tag,
    required this.value,
    required this.location,
  });

  /// The scope the reader depends on.
  final InheritedElement element;

  /// `provider`, `notifier` or `inherited`; see [DependencyInfo.kind].
  final String kind;

  /// The provided value's type, or the inherited widget's type.
  final String type;

  /// See [IdentityTags]. The tag of the provided value when there is one,
  /// else the tag of the scope element.
  final String tag;

  /// The provided object when it can be read: a provider scope's value, an
  /// `InheritedNotifier`'s notifier. Null for a plain inherited widget.
  final Object? value;

  /// Where the scope was created, when that is in the project.
  final SourceLocation? location;

  /// The provided object when it is a [Listenable]: what step 2 listens to.
  Listenable? get listenable {
    final v = value;
    return v is Listenable ? v : null;
  }

  DependencyInfo toInfo(SourcePaths paths) => DependencyInfo(
    kind: kind,
    type: clipText(type, 80),
    tag: tag,
    source: _ref(location, paths),
  );

  @override
  String toString() => '$kind $type $tag';
}

/// An element that builds with state it reads: a `State` the project wrote
/// (`state`), or a stateless widget the project wrote that reads a state
/// object (`reader`).
class ReaderRef {
  ReaderRef({
    required this.element,
    required this.kind,
    required this.type,
    required this.location,
    required this.dependencies,
  });

  final Element element;
  final String kind;
  final String type;
  final SourceLocation? location;
  final List<DependencyRef> dependencies;

  StateOwnerInfo toInfo(SourcePaths paths) => StateOwnerInfo(
    kind: kind,
    type: clipText(type, 80),
    source: _ref(location, paths),
    dependencies: [
      for (final d in dependencies.take(StateOwnerInfo.maxDependencies))
        d.toInfo(paths),
    ],
  );
}

SourceRef? _ref(SourceLocation? location, SourcePaths paths) => location == null
    ? null
    : SourceRef(
        file: paths.relativePath(location.uri),
        line: location.line,
        column: location.column,
      );

/// The state objects [reader] depends on, sorted by type then tag. At most
/// [max].
///
/// Framework scopes ([frameworkInheritedWidgets]) are left out. So is an
/// inherited widget that the framework or another package created
/// (its creation location is known and is not the project's): only a
/// provider-like scope, an `InheritedNotifier` and an inherited widget the
/// project made stay.
List<DependencyRef> dependenciesOf(
  Element reader,
  SourceResolver resolver, {
  IdentityTags? tags,
  int max = 8,
}) {
  final registry = tags ?? IdentityTags.shared;
  final Set<InheritedElement>? found = _dependencySet(reader);
  if (found == null || found.isEmpty) return const <DependencyRef>[];
  final result = <DependencyRef>[];
  for (final scope in found) {
    if (result.length >= max) break;
    try {
      final ref = _describe(scope, resolver, registry);
      if (ref != null) result.add(ref);
    } catch (_) {
      // A scope that cannot be read is left out, never an error.
    }
  }
  // A Set has no useful order; a note must not change between two picks.
  result.sort((a, b) {
    final byType = a.type.compareTo(b.type);
    return byType != 0 ? byType : a.tag.compareTo(b.tag);
  });
  return result;
}

/// The `dependencies` property of [element]'s diagnostics, or null.
Set<InheritedElement>? _dependencySet(Element element) {
  try {
    for (final property in element.toDiagnosticsNode().getProperties()) {
      if (property.name != 'dependencies') continue;
      final value = property.value;
      return value is Set<InheritedElement> ? value : null;
    }
  } catch (_) {
    // Diagnostics run code written by widget authors (engineering rule 4).
  }
  return null;
}

DependencyRef? _describe(
  InheritedElement scope,
  SourceResolver resolver,
  IdentityTags tags,
) {
  final widget = scope.widget;
  final typeName = widget.runtimeType.toString();
  final base = baseTypeName(typeName).replaceFirst(RegExp('^_+'), '');
  if (frameworkInheritedWidgets.contains(base)) return null;

  var kind = 'inherited';
  var type = baseTypeName(typeName);
  Object? value;
  final named = scopeOf(typeName);
  if (named != null) {
    (kind, type) = named;
    value = _providedValue(scope, kind);
  } else if (widget is InheritedNotifier) {
    kind = 'notifier';
    value = widget.notifier;
    type = value == null ? type : value.runtimeType.toString();
  }

  final own = resolver.entryOf(scope);
  if (kind == 'inherited' && own.location != null && !own.isLocal) {
    // Made by the framework or by another package: not state the app wrote.
    return null;
  }
  final identity = IdentityTags.canTag(value) ? value! : scope;
  return DependencyRef(
    element: scope,
    kind: kind,
    type: type,
    tag: tags.of(identity),
    value: value,
    location: kind == 'inherited'
        ? own.location
        : _scopeSource(scope, resolver),
  );
}

/// The object a provider-like scope holds. The `provider` package is not a
/// dependency of Pinpoint, so its scope element is read with `dynamic`;
/// anything that fails reads as "no value" and the scope's own identity
/// stands in.
Object? _providedValue(InheritedElement scope, String kind) {
  try {
    final widget = scope.widget;
    if (widget is InheritedNotifier) return widget.notifier;
    return (scope as dynamic).value as Object?;
  } catch (_) {
    return null;
  }
}

/// The scope is made inside its package, by the app's
/// `ChangeNotifierProvider(...)` call: the source is the nearest local
/// widget at the scope or just above it (the rule Milestone 19 uses for
/// the same).
SourceLocation? _scopeSource(InheritedElement scope, SourceResolver resolver) {
  final own = resolver.entryOf(scope);
  if (own.isLocal) return own.location;
  SourceLocation? where;
  var steps = 0;
  try {
    scope.visitAncestorElements((ancestor) {
      if (++steps > 3) return false;
      final entry = resolver.entryOf(ancestor);
      if (!entry.isLocal) return true;
      where = entry.location;
      return false;
    });
  } catch (_) {
    // Unmounted.
  }
  return where;
}

/// A type name without its type arguments: `Foo<Bar>` is `Foo`.
String baseTypeName(String name) {
  final open = name.indexOf('<');
  return open < 0 ? name : name.substring(0, open);
}

/// `(kind, value type)` when [widgetType] names a provider-like scope:
/// `_InheritedProviderScope<Foo?>` (the `provider` package) is `provider` of
/// `Foo`; `InheritedNotifier<Foo>` is `notifier`; `InheritedModel<Foo>` is
/// `provider`. Null for any other widget. Shared with the note's state
/// owners (Milestone 19).
(String, String)? scopeOf(String widgetType) {
  final open = widgetType.indexOf('<');
  if (open < 0 || !widgetType.endsWith('>')) return null;
  final base = widgetType.substring(0, open);
  // `Foo?` for a nullable argument; `Foo<Bar>` stays whole.
  var type = widgetType.substring(open + 1, widgetType.length - 1);
  if (type.endsWith('?')) type = type.substring(0, type.length - 1);
  return switch (base) {
    '_InheritedProviderScope' => ('provider', type),
    'InheritedNotifier' => ('notifier', type),
    'InheritedModel' => ('provider', type),
    _ => null,
  };
}

/// Whether the first child of [element] was created in the project: the
/// `State` behind [element] returned it from a `build` the project wrote.
/// A `Scaffold` or a `ListView` in the app's `build` is made by the
/// project too, but its `State` is the framework's: what tells them apart
/// is what `State.build` returns.
bool buildsLocally(Element element, SourceResolver resolver) {
  Element? child;
  element.visitChildren((c) => child ??= c);
  final first = child;
  return first != null && resolver.entryOf(first).isLocal;
}

/// [element] as a reader, or null when it is none: a `StatefulElement`
/// whose widget and `State` the project wrote (listed even with no
/// dependency), or a `StatelessElement` whose widget the project wrote and
/// that reads at least one state object.
ReaderRef? readerOf(
  Element element,
  SourceResolver resolver, {
  IdentityTags? tags,
}) {
  final isState = element is StatefulElement;
  if (!isState && element is! StatelessElement) return null;
  final entry = resolver.entryOf(element);
  if (!entry.isLocal) return null;
  if (isState && !buildsLocally(element, resolver)) return null;
  final dependencies = dependenciesOf(element, resolver, tags: tags);
  if (!isState && dependencies.isEmpty) return null;
  return ReaderRef(
    element: element,
    kind: isState ? 'state' : 'reader',
    type: isState ? element.state.runtimeType.toString() : entry.name,
    location: entry.location,
    dependencies: dependencies,
  );
}

/// The nearest readers of [target]: [target] itself, then each ancestor
/// (toward the app), at most [max] (PLAN-v3 Milestone 21, step 1).
/// [boundary] is the element just above the app's own widgets: the walk
/// stops there.
List<ReaderRef> nearestReaders(
  Element target,
  SourceResolver resolver, {
  int max = 4,
  Element? boundary,
  IdentityTags? tags,
}) {
  final readers = <ReaderRef>[];
  void visit(Element element) {
    if (readers.length >= max) return;
    final reader = readerOf(element, resolver, tags: tags);
    if (reader != null) readers.add(reader);
  }

  visit(target);
  try {
    target.visitAncestorElements((ancestor) {
      if (identical(ancestor, boundary) || readers.length >= max) return false;
      visit(ancestor);
      return true;
    });
  } catch (_) {
    // An element that is no longer active asserts on ancestor lookup.
  }
  return readers;
}
