import 'package:flutter/material.dart';

class DialogSheetScreen extends StatelessWidget {
  const DialogSheetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dialog and bottom sheet')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete item?'),
                  content: const Text('This action cannot be undone.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open dialog'),
            ),
            OutlinedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (context) => const SizedBox(
                  height: 240,
                  child: Center(child: Text('Bottom sheet content')),
                ),
              ),
              child: const Text('Open bottom sheet'),
            ),
          ],
        ),
      ),
    );
  }
}
