import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';

/// One short message, for example the result of one sink.
class ToastMessage {
  ToastMessage(
    this.text, {
    this.error = false,
    this.actionLabel,
    this.onAction,
  });

  final String text;

  /// Shown with the error bar and a close button, and kept until dismissed.
  final bool error;

  /// An underlined action after the text, for example `Open` or `Retry`.
  final String? actionLabel;

  /// What the action does. The toast goes away after it runs.
  final VoidCallback? onAction;
}

/// The messages on screen.
///
/// A message goes away by itself after four seconds, except an error, which
/// stays until it is dismissed. One timer per message that goes by itself,
/// which changes something when it fires; nothing runs while no message
/// shows (engineering rule 2).
class ToastController {
  final ValueNotifier<List<ToastMessage>> _messages =
      ValueNotifier<List<ToastMessage>>(const <ToastMessage>[]);
  final Map<ToastMessage, Timer> _timers = <ToastMessage, Timer>{};

  /// At most this many show at once; the oldest goes first.
  static const int maxMessages = 4;

  /// How long a message that is not an error stays.
  static const Duration lifetime = Duration(seconds: 4);

  ValueListenable<List<ToastMessage>> get messages => _messages;

  void show(
    String text, {
    bool error = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final message = ToastMessage(
      text,
      error: error,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    var next = [..._messages.value, message];
    while (next.length > maxMessages) {
      _timers.remove(next.first)?.cancel();
      next = next.sublist(1);
    }
    _messages.value = next;
    if (!error) _timers[message] = Timer(lifetime, () => dismiss(message));
  }

  /// Takes [message] off the screen.
  void dismiss(ToastMessage message) {
    _timers.remove(message)?.cancel();
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

/// Shows [toasts] at the bottom center, oldest on top: a success with its
/// action, an error with its bar, retry and close, and, while [controller] is
/// sending, a loading toast.
///
/// A toast takes pointer events only when it has something to click (an
/// action or a close button); the empty space around them lets every event
/// through, so it never blocks the panel or the trap.
class ToastLayer extends StatelessWidget {
  const ToastLayer({
    super.key = layerKey,
    required this.toasts,
    this.controller,
  });

  static const Key layerKey = ValueKey<String>('pinpoint.toasts');
  static const Key sendingKey = ValueKey<String>('pinpoint.toasts.sending');

  final ToastController toasts;

  /// The controller whose `sending` mode shows the loading toast.
  final PinPointController? controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([toasts.messages, ?controller]),
      builder: (context, _) {
        final messages = toasts.messages.value;
        final sending = controller?.mode == PinPointMode.sending;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final message in messages)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _Toast(
                      message: message,
                      onDismiss: () => toasts.dismiss(message),
                    ),
                  ),
                if (sending)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _Toast.loading(
                      key: sendingKey,
                      text:
                          'Sending note '
                          '${controller!.notes.pinned.length + 1}…',
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.message, required this.onDismiss})
    : loadingText = null;

  const _Toast.loading({super.key, required String text})
    : loadingText = text,
      message = null,
      onDismiss = null;

  final ToastMessage? message;
  final VoidCallback? onDismiss;
  final String? loadingText;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final message = this.message;
    final error = message?.error ?? false;
    final action = message?.actionLabel;
    final interactive = error || action != null;
    final base = tokens.surface(2);
    // An error's left edge is a 4 px bar in the error colour.
    final decoration = error
        ? base.copyWith(
            border: Border(
              top: BorderSide(color: tokens.ink),
              right: BorderSide(color: tokens.ink),
              bottom: BorderSide(color: tokens.ink),
              left: BorderSide(color: tokens.err, width: 4),
            ),
          )
        : base;
    final Widget lead = loadingText != null
        ? const DraftSpinner()
        : Icon(
            error ? PinPointIcons.error : PinPointIcons.checkCircle,
            size: 18,
            color: error ? tokens.err : tokens.ok,
          );
    return IgnorePointer(
      ignoring: !interactive,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: PinPointSizes.toastMaxWidth,
          minHeight: PinPointSizes.toastHeight,
        ),
        child: DecoratedBox(
          decoration: decoration,
          child: Padding(
            padding: EdgeInsets.fromLTRB(10, 4, interactive ? 2 : 10, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                lead,
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message?.text ?? loadingText!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.body,
                  ),
                ),
                if (action != null)
                  DraftButton.link(
                    label: action,
                    onPressed: () {
                      message!.onAction?.call();
                      onDismiss?.call();
                    },
                  ),
                if (error)
                  DraftIconButton(
                    icon: PinPointIcons.close,
                    iconSize: 16,
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
