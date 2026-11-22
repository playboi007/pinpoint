import 'package:flutter/widgets.dart';

import '../../model/trace_event.dart';
import '../../search/source_resolver.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `input.text` events (level 1): the focused `EditableTextState`, read
/// after each frame, recorded when its value changed. Masked for
/// `obscureText` when recorded.
///
/// Reads nothing while the app draws no frames, and never subscribes an
/// element (engineering rule 3). Pinpoint's own fields, outside the app's
/// content, are left out.
class TextSource extends TraceSource with FrameWork {
  TextSource({
    required this.contentKey,
    required this.resolver,
    this.agentTyping,
  });

  /// The element directly above the app's own widgets.
  final GlobalKey contentKey;
  final SourceResolver resolver;

  /// Whether the agent's `enter_text` runs now; its changes are tagged.
  final bool Function()? agentTyping;

  TraceRecorder? _recorder;
  FocusNode? _node;
  EditableTextState? _field;
  String? _widget;
  String? _source;
  String? _text;

  @override
  String get name => 'text';

  @override
  int get level => 1;

  @override
  bool get isInput => true;

  @override
  void start(TraceRecorder recorder) => _recorder = recorder;

  @override
  void stop() {
    _recorder = null;
    _node = null;
    _field = null;
    _text = null;
  }

  @override
  void afterFrame() {
    final recorder = _recorder;
    if (recorder == null) return;
    final node = FocusManager.instance.primaryFocus;
    if (!identical(node, _node)) {
      _node = node;
      _focus(node);
    }
    final field = _field;
    if (field == null || !field.mounted) return;
    final value = field.textEditingValue.text;
    if (value == _text) return;
    _text = value;
    final obscured = field.widget.obscureText;
    recorder.add(
      TraceKind.text,
      widget: _widget,
      source: _source,
      data: {
        'value': obscured ? '[masked]' : traceValue(value),
        'length': value.length,
        if (agentTyping?.call() ?? false) 'by': 'agent',
      },
    );
  }

  /// A new focus: remember its field and value; that is no change.
  void _focus(FocusNode? node) {
    _field = null;
    _text = null;
    final context = node?.context;
    final content = contentKey.currentContext;
    if (context is! Element || !context.mounted || content is! Element) {
      return;
    }
    // Not `.of`: nothing here may subscribe an element.
    final field = context.findAncestorStateOfType<EditableTextState>();
    if (field == null) return;
    // A field outside the app's content is Pinpoint's own.
    final element = field.context as Element;
    var inApp = false;
    element.visitAncestorElements((ancestor) {
      inApp = identical(ancestor, content);
      return !inApp;
    });
    if (!inApp) return;
    final chain = resolver.chain(element, boundary: content);
    final local = chain.defaultIndex == null
        ? null
        : chain[chain.defaultIndex!];
    _widget = local?.name ?? 'EditableText';
    final location = local?.location;
    _source = location == null
        ? null
        : '${resolver.paths.relativePath(location.uri)}:'
              '${location.line}:${location.column}';
    _field = field;
    _text = field.textEditingValue.text;
  }
}
