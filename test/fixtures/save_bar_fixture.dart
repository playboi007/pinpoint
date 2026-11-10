import 'package:flutter/material.dart';

import 'generated_fixture.g.dart';

/// Fixture for the source-location tests (Milestone 3).
///
/// Each `// PIN:<name>` marker names a constructor call: the call on the
/// same line, or on the next line when the marker stands alone. Tests find
/// the line by its marker, so this file can be edited freely.
class FixturePage extends StatelessWidget {
  const FixturePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SaveBar(), // PIN:save_bar
            SizedBox(width: 200, child: generatedLabel('generated')),
          ],
        ),
      ),
    );
  }
}

/// A custom widget that encloses a button.
class SaveBar extends StatelessWidget {
  const SaveBar({super.key});

  @override
  Widget build(BuildContext context) {
    // PIN:save_bar_padding
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _hint(),
          // PIN:save_button
          ElevatedButton(
            onPressed: () {},
            child: const Text('Save'), // PIN:save_text
          ),
        ],
      ),
    );
  }

  // The location of a widget built in a helper method is the helper's line,
  // which is the right place to edit.
  Widget _hint() => const Text('hint'); // PIN:helper_text
}
