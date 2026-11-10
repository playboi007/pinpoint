import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One short message, for example the result of one sink.
class ToastMessage {
  ToastMessage(this.text, {this.error = false});

  final String text;

  /// Shown in error colors, and longer.
  final bool error;
}

/// The messages on screen. Each one goes away by itself.
///
/// One timer per message, which changes something when it fires; nothing
/// runs while no message shows (engineering rule 2).
class ToastController {
  final ValueNotifier<List<ToastMessage>> _messages =
      ValueNotifier<List<ToastMessage>>(const <ToastMessage>[]);
  final Map<ToastMessage, Timer> _timers = <ToastMessage, Timer>{};

  /// At most this many show at once; the oldest goes first.
  static const int maxMessages = 4;

  ValueListenable<List<ToastMessage>> get messages => _messages;

  void show(String text, {bool error = false}) {
    final message = ToastMessage(text, error: error);
    var next = [..._messages.value, message];
    while (next.length > maxMessages) {
      _timers.remove(next.first)?.cancel();
      next = next.sublist(1);
    }
    _messages.value = next;
    _timers[message] = Timer(
      error ? const Duration(seconds: 8) : const Duration(seconds: 4),
      () => _remove(message),
    );
  }

  void _remove(ToastMessage message) {
    _timers.remove(message);
    _messages.value = [
      for (final other in _messages.value)
        if (!identical(other, message)) other,
    ];
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _messages.dispose();
  }
}

/// Shows [toasts] at the bottom center, oldest on top. Takes no pointer
/// events, so it never blocks the panel or the trap.
class ToastLayer extends StatelessWidget {
  const ToastLayer({super.key = layerKey, required this.toasts});

  static const Key layerKey = ValueKey<String>('pinpoint.toasts');

  final ToastController toasts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: ValueListenableBuilder<List<ToastMessage>>(
        valueListenable: toasts.messages,
        builder: (context, messages, _) => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final message in messages)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(6),
                        color: message.error
                            ? theme.colorScheme.errorContainer
                            : theme.colorScheme.inverseSurface,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Text(
                            message.text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: message.error
                                  ? theme.colorScheme.onErrorContainer
                                  : theme.colorScheme.onInverseSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
