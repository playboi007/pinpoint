import 'package:flutter/widgets.dart';

import '../capture/context_collector.dart';
import '../model/annotation.dart' show clipText;

/// Adds an app's own state to `get_state`, for example a Bloc's state, a
/// Riverpod provider or a Provider model. Set them in
/// `PinPointConfig.stateAdapters`.
///
/// [read] gets the element of the widget the agent asked about. It must
/// read without subscribing that element (engineering rule 3): use
/// `context.read<T>()`, `ProviderScope.containerOf(context, listen:
/// false)` or `findAncestorWidgetOfExactType`, never `watch` or `of`.
abstract class StateAdapter {
  const StateAdapter();

  /// The key the values go under, for example `cart`.
  String get name;

  /// The values for the widget at [context], as JSON values, or null when
  /// this adapter has nothing there. Other values are sent as text.
  Map<String, Object?>? read(BuildContext context);
}

/// The state dump of [element] (plan Milestone 12, step 9): the nearest
/// `State`'s diagnostics properties, the enclosing scroll position,
/// whether focus is inside the widget, a text field's value and selection,
/// the route and whether it is current, the inherited widgets above it,
/// and what [adapters] add.
///
/// Every list holds at most [items] entries and every string at most
/// [chars] characters.
Map<String, Object?> stateDump(
  Element element, {
  List<StateAdapter> adapters = const [],
  int items = 20,
  int chars = 200,
}) {
  String clip(Object? value) => clipText('$value', chars);
  final result = <String, Object?>{};

  // The nearest State, at the widget or above it.
  final stateful = element is StatefulElement
      ? element
      : _ancestor<StatefulElement>(element);
  if (stateful != null) {
    final properties = <String, Object?>{};
    try {
      for (final property
          in stateful.state.toDiagnosticsNode().getProperties()) {
        if (properties.length >= items) break;
        final name = property.name;
        if (name == null) continue;
        properties[name] = clip(property.toDescription());
      }
    } catch (_) {
      // Diagnostics run app code; one that throws leaves the list short.
    }
    result['state'] = {
      'type': stateful.state.runtimeType.toString(),
      'widget': stateful.widget.runtimeType.toString(),
      'properties': properties,
    };
  }

  // The scroll position around it, or its own for a scroll view (a text
  // field has an inner one of its own, which is not what is asked).
  final widget = element.widget;
  final scrollView =
      widget is ScrollView ||
      widget is Scrollable ||
      widget is SingleChildScrollView ||
      widget is PageView;
  final scrollable =
      (scrollView ? _own<ScrollableState>(element) : null) ??
      element.findAncestorStateOfType<ScrollableState>();
  if (scrollable != null) {
    try {
      final position = scrollable.position;
      result['scroll'] = {
        'pixels': _round(position.pixels),
        'min': _round(position.minScrollExtent),
        'max': _round(position.maxScrollExtent),
        'viewport': _round(position.viewportDimension),
        'axis': axisDirectionToAxis(position.axisDirection).name,
      };
    } catch (_) {
      // No dimensions yet.
    }
  }

  // Focus inside the widget.
  final focus = FocusManager.instance.primaryFocus?.context;
  result['focused'] =
      focus != null && focus.mounted && _isAtOrBelow(focus as Element, element);

  // A text field's value and selection. Masked when obscured (engineering
  // rule 9).
  final field = _own<EditableTextState>(element);
  if (field != null) {
    final value = field.textEditingValue;
    result['text'] = {
      'value': field.widget.obscureText ? '[masked]' : clip(value.text),
      'selection': [value.selection.baseOffset, value.selection.extentOffset],
    };
  }

  // The route. `ModalRoute.isCurrentOf` subscribes, but narrowly: only to
  // whether the route is current, as `settingsOf` only to its settings.
  // It is called on a render object element, never an InheritedElement
  // (api-notes item 20), and only when the agent asks.
  final owner = element is RenderObjectElement
      ? element
      : _own<RenderObjectElement>(element);
  if (owner != null) {
    try {
      result['route'] = {
        'name': ContextCollector.routeNameOf(owner),
        'current': ModalRoute.isCurrentOf(owner),
      };
    } catch (_) {
      // Not under a route.
    }
  }

  // The inherited widgets above it, nearest first.
  final inherited = <String>[];
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is InheritedWidget) {
      final name = ancestor.widget.runtimeType.toString();
      if (!inherited.contains(name)) inherited.add(name);
    }
    return inherited.length < 30;
  });
  result['inherited'] = inherited;

  if (adapters.isNotEmpty) {
    final values = <String, Object?>{};
    for (final adapter in adapters) {
      try {
        final read = adapter.read(element);
        if (read == null) continue;
        values[adapter.name] = {
          for (final MapEntry(:key, :value) in read.entries.take(items))
            key: value is num || value is bool || value == null
                ? value
                : clip(value),
        };
      } catch (error) {
        values[adapter.name] = clip('failed: $error');
      }
    }
    result['adapters'] = values;
  }
  return result;
}

/// The first [T] at [element] or below it, in a short walk.
T? _own<T>(Element element) {
  T? found;
  var visited = 0;
  void visit(Element e) {
    if (found != null || ++visited > 200) return;
    if (e is T) {
      found = e as T;
      return;
    }
    if (e is StatefulElement && e.state is T) {
      found = e.state as T;
      return;
    }
    e.visitChildren(visit);
  }

  visit(element);
  return found;
}

T? _ancestor<T extends Element>(Element element) {
  T? found;
  element.visitAncestorElements((ancestor) {
    if (ancestor is T) found = ancestor;
    return found == null;
  });
  return found;
}

bool _isAtOrBelow(Element node, Element target) {
  if (identical(node, target)) return true;
  var found = false;
  var steps = 0;
  node.visitAncestorElements((ancestor) {
    found = identical(ancestor, target);
    return !found && ++steps < 2000;
  });
  return found;
}

num _round(double value) {
  final r = (value * 10).roundToDouble() / 10;
  return r == r.roundToDouble() ? r.round() : r;
}
