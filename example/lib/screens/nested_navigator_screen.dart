import 'package:flutter/material.dart';

class NestedNavigatorScreen extends StatelessWidget {
  const NestedNavigatorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nested navigator')),
      body: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => switch (settings.name) {
            '/detail' => const _InnerDetail(),
            _ => const _InnerHome(),
          },
        ),
      ),
    );
  }
}

class _InnerHome extends StatelessWidget {
  const _InnerHome();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton(
        onPressed: () => Navigator.of(context).pushNamed('/detail'),
        child: const Text('Open inner detail'),
      ),
    );
  }
}

class _InnerDetail extends StatelessWidget {
  const _InnerDetail();

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Inner detail route'),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
