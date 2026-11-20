import 'package:flutter/widgets.dart';

/// A provider-like scope for the state lens tests: named as the `provider`
/// package's scope is, and it does what `ChangeNotifierProvider` does: when
/// the notifier it holds notifies, the scope is marked dirty and, in the
/// next build, it marks each reader (`notifyClients`).
class FakeScope<T extends ChangeNotifier> extends StatelessWidget {
  const FakeScope({required this.model, required this.child, super.key});

  final T model;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _InheritedProviderScope<T?>(value: model, child: child);
}

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

  bool _changed = false;

  Object? get value => (widget as _InheritedProviderScope<Object?>).value;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    (value as Listenable?)?.addListener(_onChange);
  }

  void _onChange() {
    _changed = true;
    markNeedsBuild();
  }

  @override
  Widget build() {
    if (_changed) {
      _changed = false;
      notifyClients(widget as InheritedWidget);
    }
    return super.build();
  }

  @override
  void unmount() {
    (value as Listenable?)?.removeListener(_onChange);
    super.unmount();
  }
}

/// `context.watch<T>()`: reads the scope of [T] and depends on it.
T watchFake<T extends ChangeNotifier>(BuildContext context) =>
    context
            .dependOnInheritedWidgetOfExactType<_InheritedProviderScope<T?>>()!
            .value!
        as T;

/// A notifier that counts its listeners, to see none is left behind.
mixin CountsListeners on ChangeNotifier {
  final Set<VoidCallback> _held = <VoidCallback>{};

  int get listenerCount => _held.length;

  @override
  void addListener(VoidCallback listener) {
    _held.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _held.remove(listener);
    super.removeListener(listener);
  }
}

/// What the example of PLAN-v3 Milestone 21 has: a provider with two flags
/// that one method sets together.
class ProductModel extends ChangeNotifier with CountsListeners {
  bool loading = false;
  bool dialogLoading = false;

  void fetchDialog() {
    dialogLoading = true;
    loading = true;
    notifyListeners();
  }
}

/// A second notifier, for the shape where one notifier triggers another.
class CartModel extends ChangeNotifier with CountsListeners {
  int count = 0;

  void bump() {
    count++;
    notifyListeners();
  }
}

/// The screen: reads the product model in `build`.
class ProductScreen extends StatelessWidget {
  const ProductScreen({this.child, super.key});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final model = watchFake<ProductModel>(context);
    return Column(children: [Text('screen ${model.loading}'), ?child]);
  }
}

/// The dialog's content: reads the same product model.
class FetchDialog extends StatelessWidget {
  const FetchDialog({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('dialog ${watchFake<ProductModel>(context).dialogLoading}');
}

/// Reads both models.
class ProductAndCart extends StatelessWidget {
  const ProductAndCart({super.key});

  @override
  Widget build(BuildContext context) {
    final product = watchFake<ProductModel>(context);
    final cart = watchFake<CartModel>(context);
    return Text('both ${product.loading} ${cart.count}');
  }
}

/// A `State` with a `setState`, for the stacks.
class Spinner extends StatefulWidget {
  const Spinner({super.key});

  @override
  State<Spinner> createState() => SpinnerState();
}

class SpinnerState extends State<Spinner> {
  bool busy = false;

  void toggle() {
    setState(() => busy = !busy);
  }

  @override
  Widget build(BuildContext context) => Text('spinner $busy');
}
