import 'package:flutter/material.dart';

/// A custom widget that encloses a button, for the Milestone 3 manual check:
/// clicking "Save" selects the `Text` in this file, and Arrow Up climbs to
/// the `ElevatedButton`, the `Row` and on to `SaveBar` in the form screen.
class SaveBar extends StatelessWidget {
  const SaveBar({super.key, required this.onSave, required this.onCancel});

  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 8,
      children: [
        TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ElevatedButton(onPressed: onSave, child: const Text('Save')),
      ],
    );
  }
}
