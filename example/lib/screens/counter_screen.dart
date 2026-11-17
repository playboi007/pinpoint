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
              _SquishOnPress(
                child: FilledButton(
                  onPressed: () => setState(() => _count++),
                  child: const Text('Increment'),
                ),
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

/// Squeezes its child while a pointer is down and springs it back on release.
/// A [Listener] sees the pointer without taking the tap from the button.
class _SquishOnPress extends StatefulWidget {
  const _SquishOnPress({required this.child});

  final Widget child;

  @override
  State<_SquishOnPress> createState() => _SquishOnPressState();
}

class _SquishOnPressState extends State<_SquishOnPress> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: _down
            ? const Duration(milliseconds: 90)
            : const Duration(milliseconds: 320),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}
