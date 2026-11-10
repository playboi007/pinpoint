import 'package:flutter/material.dart';

/// Fixture for `SourceIndex` and pins (Milestone 8).
///
/// Each `// PIN:<name>` marker names a constructor call: the call on the
/// same line, or on the next line when the marker stands alone. Tests find
/// the line by its marker, so this file can be edited freely.
class PinFixture extends StatelessWidget {
  const PinFixture({super.key, this.rows = 3});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Title'), // PIN:title
          for (var i = 0; i < rows; i++) Text('row $i'), // PIN:row
          for (final name in ['a', 'b'])
            // PIN:keyed
            SizedBox(key: ValueKey<String>(name), height: 20, width: 40),
          const SizedBox(height: 40),
          // The only Icon in this file: the line-shift tests move its
          // anchor ten lines up and expect the pin to find it again.
          const Icon(Icons.star), // PIN:star
        ],
      ),
    );
  }
}

/// A lazy list of 1000 rows: only the rows on screen are built.
class PinListFixture extends StatelessWidget {
  const PinListFixture({super.key, this.controller});

  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 1000,
        itemExtent: 40,
        itemBuilder: (context, i) => ListTile(
          title: Text('Item $i'), // PIN:item
        ),
      ),
    );
  }
}
