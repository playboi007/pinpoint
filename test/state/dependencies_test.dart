import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/search/source_resolver.dart';
import 'package:pinpoint/src/state/dependencies.dart';

/// PLAN-v3 Milestone 21, build step 1: who reads what.
void main() {
  const resolver = SourceResolver();

  DependencyRef only(Element reader, {IdentityTags? tags}) {
    final deps = dependenciesOf(reader, resolver, tags: tags);
    expect(deps, hasLength(1), reason: '$deps');
    return deps.single;
  }

  testWidgets('a widget that reads a provider-like scope lists it; '
      'MediaQuery is left out', (tester) async {
    final model = _Model();
    await tester.pumpWidget(
      MaterialApp(
        home: _InheritedProviderScope<_Model?>(
          value: model,
          child: const _Reader(),
        ),
      ),
    );
    final element = tester.element(find.byType(_Reader));
    // The widget really depends on MediaQuery too (and Theme, via Text).
    expect(element.dependOnInheritedWidgetOfExactType<MediaQuery>(), isNotNull);

    final dep = only(element);
    expect(dep.kind, 'provider');
    expect(dep.type, '_Model');
    expect(dep.tag, matches(RegExp(r'^#a\d+$')));
    expect(dep.value, same(model));
    expect(dep.listenable, same(model));
    // The scope is made by the test file: its source is a project line.
    expect(dep.location, isNotNull);
    expect(dep.location!.uri, contains('dependencies_test.dart'));
  });

  testWidgets('a dialog and its screen that read one object get one tag', (
    tester,
  ) async {
    final model = _Model();
    final other = _Model();
    final tags = IdentityTags();
    late BuildContext screen;
    await tester.pumpWidget(
      MaterialApp(
        home: _InheritedProviderScope<_Model?>(
          value: model,
          child: Builder(
            builder: (context) {
              screen = context;
              return const _Reader(key: ValueKey('screen'));
            },
          ),
        ),
      ),
    );
    // The dialog is a route in the Navigator's overlay, not a child of the
    // screen: it provides the same object again with its own scope.
    unawaited(
      showDialog<void>(
        context: screen,
        builder: (_) => _InheritedProviderScope<_Model?>(
          value: model,
          child: const _Reader(key: ValueKey('dialog')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A third reader under a scope with another object.
    unawaited(
      showDialog<void>(
        context: screen,
        builder: (_) => _InheritedProviderScope<_Model?>(
          value: other,
          child: const _Reader(key: ValueKey('stranger')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Element reader(String key) => tester.element(find.byKey(ValueKey(key)));
    final fromScreen = only(reader('screen'), tags: tags);
    final fromDialog = only(reader('dialog'), tags: tags);
    final fromStranger = only(reader('stranger'), tags: tags);
    expect(fromDialog.element, isNot(same(fromScreen.element)));
    expect(fromDialog.tag, fromScreen.tag);
    expect(fromStranger.tag, isNot(fromScreen.tag));
    // Asking again gives the same tag.
    expect(only(reader('screen'), tags: tags).tag, fromScreen.tag);
  });

  testWidgets('a scope with no readable value is tagged by the scope itself', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: _InheritedProviderScope<_Model?>(
          value: null,
          child: Column(
            children: [
              _Reader(key: ValueKey('a')),
              _Reader(),
            ],
          ),
        ),
      ),
    );
    final first = only(tester.element(find.byKey(const ValueKey('a'))));
    final second = only(tester.element(find.byType(_Reader).last));
    expect(first.tag, second.tag);
  });

  testWidgets('an inherited widget that the project made is listed as '
      'inherited', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _Flags(flag: true, child: _FlagReader())),
    );
    final dep = only(tester.element(find.byType(_FlagReader)));
    expect(dep.kind, 'inherited');
    expect(dep.type, '_Flags');
    expect(dep.location!.uri, contains('dependencies_test.dart'));
  });

  testWidgets('nearest readers: a State, a reader, at most the limit; a '
      'framework State is not one', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Counter(
            child: _InheritedProviderScope<_Model?>(
              value: _Model(),
              child: const _Reader(child: Text('deep')),
            ),
          ),
        ),
      ),
    );
    final target = tester.element(find.text('deep'));
    final readers = nearestReaders(target, resolver);
    expect(
      [for (final r in readers) (r.kind, r.type)],
      [('reader', '_Reader'), ('state', '_CounterState')],
    );
    expect(readers.first.dependencies.single.type, '_Model');
    expect(readers.last.dependencies, isEmpty);

    expect(nearestReaders(target, resolver, max: 1), hasLength(1));
    final info = readers.first.toInfo(const SourceResolver().paths);
    expect(info.dependencies.single.tag, readers.first.dependencies.single.tag);
  });

  test('IdentityTags: same object, same tag; values that cannot carry a tag '
      'still get one', () {
    final tags = IdentityTags();
    final a = Object();
    final b = Object();
    expect(tags.of(a), tags.of(a));
    expect(tags.of(a), isNot(tags.of(b)));
    expect(tags.of(a), '#a1');
    expect(IdentityTags.canTag(3), isFalse);
    expect(IdentityTags.canTag('x'), isFalse);
    expect(IdentityTags.canTag(null), isFalse);
    expect(IdentityTags.canTag(a), isTrue);
    expect(tags.of(3), startsWith('#a'));
  });

  test('scopeOf reads the kind and the value type from the type name', () {
    expect(scopeOf('_InheritedProviderScope<Foo?>'), ('provider', 'Foo'));
    expect(scopeOf('InheritedNotifier<Bar>'), ('notifier', 'Bar'));
    expect(scopeOf('InheritedModel<Baz>'), ('provider', 'Baz'));
    expect(scopeOf('Container'), isNull);
    expect(scopeOf('Foo<Bar>'), isNull);
  });
}

class _Model extends ChangeNotifier {}

/// Named like the `provider` package's scope, with a `value` on its
/// element as the package's scope element has.
class _InheritedProviderScope<T> extends InheritedWidget {
  const _InheritedProviderScope({required this.value, required super.child});

  final Object? value;

  @override
  bool updateShouldNotify(_InheritedProviderScope<T> oldWidget) => false;

  @override
  InheritedElement createElement() => _ScopeElement(this);
}

class _ScopeElement extends InheritedElement {
  _ScopeElement(super.widget);

  Object? get value => (widget as _InheritedProviderScope<Object?>).value;
}

/// Reads the scope and `MediaQuery` in `build`, as `context.watch` would.
class _Reader extends StatelessWidget {
  const _Reader({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    context
        .dependOnInheritedWidgetOfExactType<_InheritedProviderScope<_Model?>>();
    MediaQuery.of(context);
    return child ?? const SizedBox();
  }
}

class _Flags extends InheritedWidget {
  const _Flags({required this.flag, required super.child});

  final bool flag;

  @override
  bool updateShouldNotify(_Flags oldWidget) => flag != oldWidget.flag;
}

class _FlagReader extends StatelessWidget {
  const _FlagReader();

  @override
  Widget build(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_Flags>();
    Theme.of(context);
    return const SizedBox();
  }
}

class _Counter extends StatefulWidget {
  const _Counter({required this.child});

  final Widget child;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  Widget build(BuildContext context) => widget.child;
}
