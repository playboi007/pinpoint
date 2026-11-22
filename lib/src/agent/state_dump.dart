import 'package:flutter/widgets.dart';

import '../capture/context_collector.dart';
import '../model/annotation.dart' show clipText;

/// Adds an app's own state to `get_state`, for example a Bloc's state, a
/// Riverpod provider or a Provider model. Set them in
/// `PinPointConfig.stateAdapters`.
///
/// [read] gets the element of the widget the agent asked about. It must
/// read without subscribing that element: use
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

/// The state dump of [element]: the nearest `State`'s diagnostics
/// properties, the enclosing scroll position, whether focus is inside the
/// widget, a text field's value and selection, the route and whether it is
/// current, the inherited widgets above it, and what [adapters] add.
///
/// Every list holds at most [items] entries and every string at most
/// [chars] characters.
Map<String, Object?> stateDump(
  Element element, {
  List<StateAdapter> adapters = const [],
  int items = 20,
  int chars = 200,
}) => {
  'state': ?_stateOf(element, items, chars),
  'scroll': ?_scrollOf(element),
  'focused': _hasFocusIn(element),
  'text': ?_textOf(element, chars),
  'route': ?_routeOf(element),
  'inherited': _inheritedNames(element),
  if (adapters.isNotEmpty)
    'adapters': _adapterValues(element, adapters, items, chars),
};

String _clip(Object? value, int chars) => clipText('$value', chars);

/// The nearest State, at the widget or above it.
Map<String, Object?>? _stateOf(Element element, int items, int chars) {
  final stateful = element is StatefulElement
      ? element
      : _ancestor<StatefulElement>(element);
  if (stateful == null) return null;
  final properties = <String, Object?>{};
  try {
    for (final property in stateful.state.toDiagnosticsNode().getProperties()) {
      if (properties.length >= items) break;
      final name = property.name;
      if (name == null) continue;
      properties[name] = _clip(property.toDescription(), chars);
    }
  } catch (_) {
    // Diagnostics run app code; one that throws leaves the list short.
  }
  return {
    'type': stateful.state.runtimeType.toString(),
    'widget': stateful.widget.runtimeType.toString(),
    'properties': properties,
  };
}

/// The scroll position around it, or its own for a scroll view (a text
/// field has an inner one of its own, which is not what is asked).
Map<String, Object?>? _scrollOf(Element element) {
  final widget = element.widget;
  final scrollView =
      widget is ScrollView ||
      widget is Scrollable ||
      widget is SingleChildScrollView ||
      widget is PageView;
  final scrollable =
      (scrollView ? _own<ScrollableState>(element) : null) ??
      element.findAncestorStateOfType<ScrollableState>();
  if (scrollable == null) return null;
  try {
    final position = scrollable.position;
    return {
      'pixels': _round(position.pixels),
      'min': _round(position.minScrollExtent),
      'max': _round(position.maxScrollExtent),
      'viewport': _round(position.viewportDimension),
      'axis': axisDirectionToAxis(position.axisDirection).name,
    };
  } catch (_) {
    return null; // No dimensions yet.
  }
}

bool _hasFocusIn(Element element) {
  final focus = FocusManager.instance.primaryFocus?.context;
  return focus != null &&
      focus.mounted &&
      _isAtOrBelow(focus as Element, element);
}

/// A text field's value and selection. Masked when obscured.
Map<String, Object?>? _textOf(Element element, int chars) {
  final field = _own<EditableTextState>(element);
  if (field == null) return null;
  final value = field.textEditingValue;
  return {
    'value': field.widget.obscureText ? '[masked]' : _clip(value.text, chars),
    'selection': [value.selection.baseOffset, value.selection.extentOffset],
  };
}

/// The route. `ModalRoute.isCurrentOf` subscribes, but narrowly: only to
/// whether the route is current. It is called on a render object element,
/// never an InheritedElement, and only when the agent asks.
Map<String, Object?>? _routeOf(Element element) {
  final owner = element is RenderObjectElement
      ? element
      : _own<RenderObjectElement>(element);
  if (owner == null) return null;
  try {
    return {
      'name': ContextCollector.routeNameOf(owner),
      'current': ModalRoute.isCurrentOf(owner),
    };
  } catch (_) {
    return null; // Not under a route.
  }
}

/// The inherited widgets above it, nearest first.
List<String> _inheritedNames(Element element) {
  final inherited = <String>[];
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is InheritedWidget) {
      final name = ancestor.widget.runtimeType.toString();
      if (!inherited.contains(name)) inherited.add(name);
    }
    return inherited.length < 30;
  });
  return inherited;
}

Map<String, Object?> _adapterValues(
  Element element,
  List<StateAdapter> adapters,
  int items,
  int chars,
) {
  final values = <String, Object?>{};
  for (final adapter in adapters) {
    try {
      final read = adapter.read(element);
      if (read == null) continue;
      values[adapter.name] = {
        for (final MapEntry(:key, :value) in read.entries.take(items))
          key: value is num || value is bool || value == null
              ? value
              : _clip(value, chars),
      };
    } catch (error) {
      values[adapter.name] = _clip('failed: $error', chars);
    }
  }
  return values;
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
