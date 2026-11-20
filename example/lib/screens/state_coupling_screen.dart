import 'package:flutter/material.dart';

/// The state lens demo (PLAN-v3 Milestone 21): one screen with the three
/// ways two values change together, with framework classes only.
///
/// To see it with Pinpoint: pick the "loading: ..." line, open the State
/// tab and tap "Watch state". Then:
///
/// 1. Tap "Open dialog", then "Fetch" in the dialog. [ProductModel
///    .fetchDialog] sets `loading` and `dialogLoading` and notifies once.
///    The screen and the dialog both rebuild, and both rows show the same
///    tag: one method changed both values (shape 1), and two widgets read
///    one object (shape 3). The dialog is a route in the Navigator's
///    overlay, not a child of this screen.
/// 2. Tap "Add to cart". The quantity notifier's listener sets the total
///    notifier. The lens says: one notifier triggers another (shape 2).
///    Pick the screen itself (not the "loading" line) to watch these two.
class StateCouplingScreen extends StatefulWidget {
  const StateCouplingScreen({super.key});

  static const String route = '/state-coupling';
  static const String title = 'State coupling';

  @override
  State<StateCouplingScreen> createState() => _StateCouplingScreenState();
}

class _StateCouplingScreenState extends State<StateCouplingScreen> {
  final ProductModel _model = ProductModel();

  /// Shape 2: a listener on [_quantity] sets [_total].
  final ValueNotifier<int> _quantity = ValueNotifier<int>(0);
  final ValueNotifier<int> _total = ValueNotifier<int>(0);

  static const int _price = 12;

  @override
  void initState() {
    super.initState();
    _quantity.addListener(_updateTotal);
  }

  @override
  void dispose() {
    _quantity.removeListener(_updateTotal);
    _quantity.dispose();
    _total.dispose();
    _model.dispose();
    super.dispose();
  }

  void _updateTotal() => _total.value = _quantity.value * _price;

  Future<void> _openDialog() {
    // A dialog is not below this screen, so it gets the same model through
    // its own scope. Same object: same tag in the lens.
    return showDialog<void>(
      context: context,
      builder: (_) =>
          ProductScope(notifier: _model, child: const _FetchDialog()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ProductScope(
      notifier: _model,
      child: Scaffold(
        appBar: AppBar(title: const Text(StateCouplingScreen.title)),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Status(),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _model.fetchDialog,
                    child: const Text('Fetch'),
                  ),
                  OutlinedButton(
                    onPressed: _model.reset,
                    child: const Text('Reset'),
                  ),
                  OutlinedButton(
                    onPressed: _openDialog,
                    child: const Text('Open dialog'),
                  ),
                ],
              ),
              const Divider(height: 32),
              ValueListenableBuilder<int>(
                valueListenable: _quantity,
                builder: (context, quantity, _) => Text('Quantity: $quantity'),
              ),
              ValueListenableBuilder<int>(
                valueListenable: _total,
                builder: (context, total, _) => Text('Total: $total'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _quantity.value = _quantity.value + 1,
                child: const Text('Add to cart'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shape 1: two flags, and one method that sets both and notifies once.
class ProductModel extends ChangeNotifier {
  bool _loading = false;
  bool _dialogLoading = false;

  bool get loading => _loading;
  bool get dialogLoading => _dialogLoading;

  void fetchDialog() {
    _dialogLoading = true;
    _loading = true;
    notifyListeners();
  }

  void reset() {
    _dialogLoading = false;
    _loading = false;
    notifyListeners();
  }
}

/// Provides a [ProductModel] to everything below it.
class ProductScope extends InheritedNotifier<ProductModel> {
  const ProductScope({
    super.key,
    required ProductModel super.notifier,
    required super.child,
  });

  /// The model, and a dependency on it: the caller rebuilds when it
  /// notifies.
  static ProductModel of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProductScope>()!.notifier!;
}

/// Reads `loading` on the screen.
class _Status extends StatelessWidget {
  const _Status();

  @override
  Widget build(BuildContext context) {
    final model = ProductScope.of(context);
    return Text('loading: ${model.loading}');
  }
}

/// Reads `dialogLoading` in the dialog: the same object as [_Status].
class _FetchDialog extends StatelessWidget {
  const _FetchDialog();

  @override
  Widget build(BuildContext context) {
    final model = ProductScope.of(context);
    return AlertDialog(
      title: const Text('Product dialog'),
      content: Text('dialog loading: ${model.dialogLoading}'),
      actions: [
        TextButton(onPressed: model.fetchDialog, child: const Text('Fetch')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
