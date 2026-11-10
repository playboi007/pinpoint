import 'package:flutter/material.dart';

class LongListScreen extends StatelessWidget {
  const LongListScreen({super.key});

  static const int itemCount = 1000;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Long list')),
      body: ListView.builder(
        itemCount: itemCount,
        itemBuilder: (context, index) => ListTile(
          leading: CircleAvatar(child: Text('${index + 1}')),
          title: Text('Item ${index + 1}'),
          subtitle: const Text('A subtitle that may wrap on narrow viewports.'),
          trailing: const Icon(Icons.more_vert),
        ),
      ),
    );
  }
}
