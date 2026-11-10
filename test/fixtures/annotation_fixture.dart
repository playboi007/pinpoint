import 'package:flutter/material.dart';

/// Fixture for the context-capture tests (Milestone 4).
///
/// Each `// PIN:<name>` marker names a constructor call: the call on the
/// same line, or on the next line when the marker stands alone.
class OrderPage extends StatelessWidget {
  const OrderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // PIN:order_save_bar
            const SaveChangesBar(),
          ],
        ),
      ),
    );
  }
}

/// A custom widget with a row of three children; the middle one is a
/// button with a label.
class SaveChangesBar extends StatelessWidget {
  const SaveChangesBar({super.key});

  @override
  Widget build(BuildContext context) {
    // PIN:bar_padding
    return Padding(
      padding: const EdgeInsets.all(16),
      // PIN:bar_row
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // PIN:bar_icon
          const Icon(Icons.save, color: Color(0xFFF44336)),
          // PIN:bar_button
          ElevatedButton(
            onPressed: () {},
            // PIN:bar_text
            child: const Text(
              'Save changes',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // PIN:bar_gap
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Counts its builds, so a test can prove that collecting context does not
/// subscribe it to anything.
class BuildCounter extends StatelessWidget {
  const BuildCounter({super.key, required this.child});

  static int builds = 0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    builds++;
    return child;
  }
}
