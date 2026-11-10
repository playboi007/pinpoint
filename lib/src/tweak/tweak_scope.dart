import 'package:flutter/widgets.dart';

import '../capture/subtree_outline.dart' show typeName;
import '../info/widget_info.dart';
import '../model/annotation.dart' show SourceRef;
import '../search/pick_result.dart';
import '../search/source_resolver.dart';

/// One section the Tweak tab shows: what a render object of the selected
/// widget holds, the extractor that read it, and which widget made it.
@immutable
class TweakTarget {
  const TweakTarget({
    required this.renderObject,
    required this.extractor,
    required this.section,
    this.createdBy,
    this.nearestLocal,
    this.owner,
  });

  final RenderObject renderObject;

  /// Reads [section] from [renderObject] again, for example after a tweak
  /// or a rebuild.
  final InfoExtractor extractor;

  final InfoSection section;

  /// The type of the widget that made the render object, or for a parent
  /// data section (`Flex child`, `Positioned`) the parent data widget, for
  /// example `Padding` inside a `Container`. Null outside debug.
  final String? createdBy;

  /// The nearest widget written in the project at or above [createdBy]:
  /// where the agent changes the value.
  final LocalWidget? nearestLocal;

  /// The element that wrote the values: it writes them back when it builds
  /// again. Null outside debug.
  final Element? owner;
}

/// A widget written in the project, and where.
@immutable
class LocalWidget {
  const LocalWidget({required this.widget, this.source});

  /// The type name, for example `Container`.
  final String widget;

  /// The constructor call, relative to the project root.
  final SourceRef? source;

  Map<String, Object?> toJson() => {
    'widget': widget,
    'source': source?.toJson(),
  };
}

/// Extractors for values a parent keeps on its child (`FlexParentData`,
/// `StackParentData`). They describe the selected widget's place in its
/// parent, so they run on its top render object only.
bool isParentDataSection(InfoExtractor extractor) =>
    WidgetInfo.parentDataExtractors.contains(extractor);

/// The sections of every render object that belongs to the selected
/// widget, top first.
///
/// A widget's render objects are the ones whose owning element has the
/// selected element as its nearest local ancestor: a `Container` owns the
/// `RenderPadding`, `RenderConstrainedBox` and `RenderDecoratedBox` its
/// build makes, so they show together. The walk stops at a render object
/// that belongs to a widget written in the project below it (the
/// `Container`'s child). Bounded (engineering rule 4).
List<TweakTarget> tweakTargetsFor(
  PickResult selection, {
  List<InfoExtractor> extractors = WidgetInfo.defaultExtractors,
  int maxNodes = 64,
}) {
  final resolver = selection.chain.resolver;
  final selected = selection.element;
  final targets = <TweakTarget>[];
  var visited = 0;

  void visit(RenderObject renderObject, {required bool top}) {
    if (++visited > maxNodes) return;
    try {
      final owner = _ownerOf(renderObject);
      if (!top && owner != null && !_belongsTo(owner, selected, resolver)) {
        return;
      }
      for (final extract in extractors) {
        final parentData = isParentDataSection(extract);
        if (parentData && !top) continue;
        final section = _tryExtract(extract, renderObject);
        if (section == null) continue;
        final maker = parentData && owner != null
            ? _parentDataElementOf(owner)
            : owner;
        targets.add(
          TweakTarget(
            renderObject: renderObject,
            extractor: extract,
            section: section,
            createdBy: maker == null ? null : typeName(maker),
            nearestLocal: maker == null
                ? _localOf(selection.entry, resolver)
                : _nearestLocal(maker, resolver),
            owner: maker,
          ),
        );
      }
    } catch (_) {
      // A render object that throws while read is left out, not the rest.
      return;
    }
    renderObject.visitChildren((child) => visit(child, top: false));
  }

  visit(selection.renderObject, top: true);
  return targets;
}

/// The element that owns [renderObject], or null outside debug.
Element? _ownerOf(RenderObject renderObject) {
  final creator = renderObject.debugCreator;
  return creator is DebugCreator ? creator.element : null;
}

/// Whether the first element at or above [owner] that is [selected] or
/// written in the project is [selected].
bool _belongsTo(Element owner, Element selected, SourceResolver resolver) {
  if (identical(owner, selected)) return true;
  if (resolver.entryOf(owner).isLocal) return false;
  var belongs = false;
  var steps = 0;
  owner.visitAncestorElements((element) {
    if (identical(element, selected)) {
      belongs = true;
      return false;
    }
    if (++steps > 64) return false;
    return !resolver.entryOf(element).isLocal;
  });
  return belongs;
}

/// The parent data widget's element above [owner] (`Expanded`,
/// `Positioned`), or [owner] when there is none near.
Element _parentDataElementOf(Element owner) {
  Element? found;
  var steps = 0;
  owner.visitAncestorElements((element) {
    if (element.widget is ParentDataWidget) {
      found = element;
      return false;
    }
    // A parent data widget sits between its child's render object and the
    // parent's; a render object element above means there is none.
    if (element is RenderObjectElement || ++steps > 32) return false;
    return true;
  });
  return found ?? owner;
}

LocalWidget? _nearestLocal(Element from, SourceResolver resolver) {
  final own = resolver.entryOf(from);
  if (own.isLocal) return _localOf(own, resolver);
  LocalWidget? found;
  var steps = 0;
  from.visitAncestorElements((element) {
    final entry = resolver.entryOf(element);
    if (entry.isLocal) {
      found = _localOf(entry, resolver);
      return false;
    }
    return ++steps <= 64;
  });
  return found;
}

LocalWidget? _localOf(ChainEntry entry, SourceResolver resolver) {
  final location = entry.location;
  return LocalWidget(
    widget: entry.name,
    source: location == null
        ? null
        : SourceRef(
            file: resolver.paths.relativePath(location.uri),
            line: location.line,
            column: location.column,
          ),
  );
}

InfoSection? _tryExtract(InfoExtractor extract, RenderObject renderObject) {
  try {
    return extract(renderObject);
  } catch (_) {
    return null;
  }
}
