import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Manual and test probe for Milestone 9: shows what the app inherits, so
/// each what-if switch can be checked by eye or read by a test.
class EnvironmentProbeScreen extends StatefulWidget {
  const EnvironmentProbeScreen({super.key});

  /// Keys of the probe's value lines, for tests.
  static Key line(String name) => ValueKey<String>('probe.$name');

  @override
  State<EnvironmentProbeScreen> createState() => _EnvironmentProbeScreenState();
}

class _EnvironmentProbeScreenState extends State<EnvironmentProbeScreen> {
  int _count = 0;

  static String _insets(EdgeInsets e) =>
      '${e.left.toStringAsFixed(0)},${e.top.toStringAsFixed(0)},'
      '${e.right.toStringAsFixed(0)},${e.bottom.toStringAsFixed(0)}';

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('What-if probe')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final lines = {
            'size':
                '${media.size.width.toStringAsFixed(0)} x '
                '${media.size.height.toStringAsFixed(0)}',
            'constraints':
                '${constraints.maxWidth.toStringAsFixed(0)} x '
                '${constraints.maxHeight.toStringAsFixed(0)}',
            'textScale': media.textScaler.scale(1).toStringAsFixed(2),
            'boldText': '${media.boldText}',
            'padding': _insets(media.padding),
            'viewPadding': _insets(media.viewPadding),
            'viewInsets': _insets(media.viewInsets),
            'direction': Directionality.of(context).name,
            'brightness': theme.brightness.name,
            'primary':
                '#${theme.colorScheme.primary.toARGB32().toRadixString(16)}',
            'platform': defaultTargetPlatform.name,
            'devicePixelRatio': media.devicePixelRatio.toStringAsFixed(2),
          };
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final MapEntry(:key, :value) in lines.entries)
                Text('$key: $value', key: EnvironmentProbeScreen.line(key)),
              const SizedBox(height: 16),
              // RTL flips it: the box moves to the right edge.
              const Row(
                children: [
                  ColoredBox(
                    color: Colors.teal,
                    child: SizedBox(width: 48, height: 24),
                  ),
                  SizedBox(width: 8),
                  Expanded(child: Text('Row, MainAxisAlignment.start')),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text('count: $_count')),
                  const SizedBox(width: 16),
                  FilledButton(
                    onPressed: () => setState(() => _count++),
                    child: const Text('Increment'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const TextField(
                decoration: InputDecoration(labelText: 'Type, then switch'),
              ),
            ],
          );
        },
      ),
    );
  }
}
