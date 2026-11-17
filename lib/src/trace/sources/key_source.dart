import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../model/trace_event.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `input.key` events (level 1), fed by the wrapper's one
/// `HardwareKeyboard` handler from Milestone 1: no second handler.
///
/// A key typed while the focus is in a field with `obscureText` is masked
/// when recorded, not when shown (rule 16). Pinpoint's own keys, and keys
/// typed into Pinpoint's own fields, are left out (rule 14).
class KeySource extends TraceSource {
  TraceRecorder? _recorder;

  @override
  String get name => 'key';

  @override
  int get level => 1;

  @override
  bool get isInput => true;

  @override
  void start(TraceRecorder recorder) => _recorder = recorder;

  @override
  void stop() => _recorder = null;

  /// Records [event], unless it is Pinpoint's ([ours]).
  void record(KeyEvent event, {required bool ours}) {
    final recorder = _recorder;
    if (recorder == null || ours) return;
    try {
      final masked = _focusIsObscured();
      final character = event.character;
      recorder.add(
        TraceKind.key,
        data: {
          'phase': switch (event) {
            KeyDownEvent() => 'down',
            KeyRepeatEvent() => 'repeat',
            _ => 'up',
          },
          'key': masked ? '[masked]' : _label(event.logicalKey),
          if (!masked && character != null && character.trim().isNotEmpty)
            'char': character,
          if (masked) 'masked': true,
        },
      );
    } catch (error) {
      debugPrint('pinpoint: key source failed: $error');
    }
  }

  static String _label(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    return label.isNotEmpty ? label : (key.debugName ?? '0x${key.keyId}');
  }

  /// Whether the focused widget is inside an obscured text field.
  static bool _focusIsObscured() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return false;
    // Not `.of`: nothing here may subscribe an element (engineering rule 3).
    final field = context.findAncestorStateOfType<EditableTextState>();
    return field?.widget.obscureText ?? false;
  }
}
