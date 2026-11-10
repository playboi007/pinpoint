import 'package:flutter/material.dart';

/// Manual check for Milestone 1: the counter and the text keep their values
/// across toggling Pinpoint, and freeze (P while picking) stops the spinner.
class CounterScreen extends StatefulWidget {
  const CounterScreen({super.key});

  @override
  State<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<CounterScreen> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Counter and spinner')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 24,
            children: [
              Text(
                'count: $_count',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              FilledButton(
                onPressed: () => setState(() => _count++),
                child: const Text('Increment'),
              ),
              const TextField(
                decoration: InputDecoration(labelText: 'Type here'),
              ),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
