import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../info/widget_info.dart';
import '../search/pick_result.dart';
import '../tweak/tweak_scope.dart';
import '../tweak/tweak_session.dart';

/// Sets [property] of [target] to [value]; returns whether it took.
typedef TweakApply = bool Function(
  TweakTarget target,
  String property,
  Object? value,
);

/// The Tweak tab of the info panel: every editable value of the selected
/// widget's render objects, with an editor each.
///
/// It edits values the widget already has. Wrapping the widget in another
/// one (for example a `Padding`) has no render object to edit, so that
/// stays a written request in the comment.
class TweakTab extends StatefulWidget {
  const TweakTab({
    super.key,
    required this.selection,
    required this.session,
    required this.onApply,
  });

  final PickResult selection;
  final TweakSession session;
  final TweakApply onApply;

  /// The key of [property]'s editor in [section], or of one of its [part]s
  /// (`left` of an inset, `width` of a border).
  static Key fieldKey(String section, String property, [String? part]) =>
      ValueKey<String>(
        'pinpoint.tweak.$section.$property${part == null ? '' : '.$part'}',
      );

  /// The key of the menu item [label] of [property]'s choices.
  static Key choiceKey(String section, String property, String label) =>
      ValueKey<String>('pinpoint.tweak.$section.$property.choice.$label');

  /// The key of the step button for [step] (1, 4 or 8).
  static Key stepKey(int step) => ValueKey<String>('pinpoint.tweak.step.$step');

  static const Key emptyKey = ValueKey<String>('pinpoint.tweak.empty');
  static const Key chainKey = ValueKey<String>('pinpoint.tweak.chain');

  @override
  State<TweakTab> createState() => _TweakTabState();
}

class _TweakTabState extends State<TweakTab> {
  /// What one stepper click or arrow key adds to a length.
  int _step = 1;

  bool _showChain = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    List<TweakTarget> targets;
    try {
      targets = tweakTargetsFor(widget.selection);
    } catch (_) {
      // The tracker clears a selection whose element is gone after the
      // next frame; until then there is nothing to read.
      targets = const <TweakTarget>[];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Step', style: muted),
            const SizedBox(width: 8),
            for (final step in const [1, 4, 8])
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  key: TweakTab.stepKey(step),
                  label: Text('$step'),
                  selected: _step == step,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _step = step),
                ),
              ),
          ],
        ),
        if (targets.isEmpty)
          Padding(
            key: TweakTab.emptyKey,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Nothing to tweak on this widget. Tweak edits padding, size, '
              'flex, alignment, text style and decoration it already has.',
              style: muted,
            ),
          ),
        for (final target in targets) _section(theme, target),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'To add a widget (for example wrap this in a Padding), write it '
            'in the comment.',
            style: muted,
          ),
        ),
        TextButton(
          key: TweakTab.chainKey,
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
          onPressed: () => setState(() => _showChain = !_showChain),
          child: Text(
            _showChain
                ? 'Hide constraints from above'
                : 'Constraints from above',
          ),
        ),
        if (_showChain)
          for (final row in constraintChain(widget.selection.renderObject))
            _Row(
              name: row.$1,
              child: Text(row.$2, style: theme.textTheme.bodySmall),
            ),
      ],
    );
  }

  Widget _section(ThemeData theme, TweakTarget target) {
    final title = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final section = target.section;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: section.title, style: title),
                TextSpan(
                  text:
                      '  ${target.renderObject.runtimeType}'
                      '${target.createdBy == null ? '' : ' from ${target.createdBy}'}',
                  style: muted,
                ),
              ],
            ),
          ),
        ),
        for (final property in section.properties)
          _property(theme, target, property),
      ],
    );
  }

  Widget _property(
    ThemeData theme,
    TweakTarget target,
    InfoProperty<Object?> property,
  ) {
    final tweak = widget.session.tweakOf(target, property.name);
    final note = property.note;
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final editor = property.editable
        ? _editorFor(target, property)
        : Text(property.label, style: small);
    return _Row(
      name: property.name,
      highlighted: tweak != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          editor,
          if (tweak != null) Text('was ${tweak.fromLabel}', style: muted),
          if (note != null) Text(note, style: muted),
        ],
      ),
    );
  }

  Widget _editorFor(TweakTarget target, InfoProperty<Object?> property) {
    final section = target.section.title;
    final name = property.name;
    Key key([String? part]) => TweakTab.fieldKey(section, name, part);
    void set(Object? value) => widget.onApply(target, name, value);
    final value = property.value;
    return switch (property.editor!) {
      final NumberEditor e => _NumberField(
        key: key(),
        value: value is num ? value.toDouble() : null,
        integer: e.integer,
        nullable: e.nullable,
        min: e.min,
        max: e.max,
        step: e.spacing ? _step.toDouble() : e.step,
        onChanged: (v) => set(e.integer ? v?.round() : v),
      ),
      final ChoiceEditor<Object?> e => _ChoiceField(
        key: key(),
        value: value,
        editor: e,
        itemKey: (label) => TweakTab.choiceKey(section, name, label),
        onChanged: set,
      ),
      ColorEditor() => _ColorField(
        key: key(),
        value: value is Color ? value : null,
        onChanged: set,
      ),
      InsetsEditor() => _InsetsField(
        value: value is EdgeInsets ? value : EdgeInsets.zero,
        keyOf: key,
        step: _step.toDouble(),
        onChanged: set,
      ),
      ConstraintsEditor() => _ConstraintsField(
        value: value is BoxConstraints ? value : const BoxConstraints(),
        keyOf: key,
        step: _step.toDouble(),
        onChanged: set,
      ),
      RadiusEditor() => _NumberField(
        key: key(),
        value: value is BorderRadius ? value.topLeft.x : 0,
        min: 0,
        step: _step.toDouble(),
        onChanged: (v) => set(BorderRadius.circular(v ?? 0)),
      ),
      BorderEditor() => _BorderField(
        value: value is Border ? value : const Border(),
        keyOf: key,
        onChanged: set,
      ),
    };
  }
}

/// The constraints each render ancestor passes down, nearest first: which
/// ancestor to tweak when the incoming constraints are the problem. They
/// cannot be set directly.
List<(String, String)> constraintChain(RenderObject from, {int max = 8}) {
  final rows = <(String, String)>[];
  RenderObject? child = from;
  for (var i = 0; i < max && child != null; i++) {
    final parent = child.parent;
    if (parent == null) break;
    String label;
    try {
      label = WidgetInfo.describeConstraints(constraintsOf(child));
    } catch (_) {
      label = 'unknown';
    }
    rows.add(('${parent.runtimeType}', 'gives $label'));
    child = parent;
  }
  return rows;
}

class _Row extends StatelessWidget {
  const _Row({
    required this.name,
    required this.child,
    this.highlighted = false,
  });

  final String name;
  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                name,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: highlighted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: highlighted ? FontWeight.w700 : null,
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A number with a stepper. Enter or leaving the field applies what was
/// typed; the arrow keys and the buttons apply one [step] at once.
class _NumberField extends StatefulWidget {
  const _NumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.integer = false,
    this.nullable = false,
    this.infinite = false,
    this.min,
    this.max,
    this.step = 1,
    this.compact = false,
  });

  final double? value;
  final ValueChanged<double?> onChanged;
  final bool integer;
  final bool nullable;

  /// Accepts `∞` (or `inf`), for a maximum constraint.
  final bool infinite;
  final double? min;
  final double? max;
  final double step;

  /// No stepper buttons: for the four fields of an inset.
  final bool compact;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _text = TextEditingController(
    text: _format(widget.value),
  );
  late final FocusNode _focus = FocusNode(
    debugLabel: 'pinpoint tweak number',
    onKeyEvent: _onKey,
  )..addListener(_onFocus);

  String _format(double? v) => v == null ? '' : formatPrecise(v);

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A value changed elsewhere (a stepper, a rebuild) shows, unless the
    // user is typing.
    if (!_focus.hasFocus && widget.value != oldWidget.value) {
      _text.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  // The arrow keys nudge the number. They would otherwise move the caret,
  // which in a one-line field does nothing useful.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _nudge(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _nudge(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onFocus() {
    if (!_focus.hasFocus) _submit();
  }

  double? _parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (widget.infinite && (t == '∞' || t.toLowerCase().startsWith('inf'))) {
      return double.infinity;
    }
    return double.tryParse(t);
  }

  double _clamp(double v) {
    var out = v;
    if (widget.min != null && out < widget.min!) out = widget.min!;
    if (widget.max != null && out > widget.max!) out = widget.max!;
    return widget.integer && out.isFinite ? out.roundToDouble() : out;
  }

  void _submit() {
    final parsed = _parse(_text.text);
    if (parsed == null && !(widget.nullable && _text.text.trim().isEmpty)) {
      _text.text = _format(widget.value); // not a number: show the value
      return;
    }
    final next = parsed == null ? null : _clamp(parsed);
    _text.text = _format(next);
    if (next != widget.value) widget.onChanged(next);
  }

  void _nudge(int direction) {
    final from = _parse(_text.text) ?? widget.value ?? widget.min ?? 0;
    if (!from.isFinite) return;
    // Round away float error: 0.1 steps should read 1.2, not 1.2000000002.
    final raw = from + direction * widget.step;
    final next = _clamp(double.parse(raw.toStringAsFixed(4)));
    _text.text = _format(next);
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      height: 32,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        style: Theme.of(context).textTheme.bodySmall,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.nullable ? 'none' : null,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 8,
          ),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
    if (widget.compact) return field;
    return Row(
      children: [
        Expanded(child: field),
        _StepButton(
          key: _partKey('dec'),
          icon: Icons.remove,
          onPressed: () => _nudge(-1),
        ),
        _StepButton(
          key: _partKey('inc'),
          icon: Icons.add,
          onPressed: () => _nudge(1),
        ),
      ],
    );
  }

  Key? _partKey(String part) {
    final key = widget.key;
    return key is ValueKey<String>
        ? ValueKey<String>('${key.value}.$part')
        : null;
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon, size: 16),
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
  );
}

/// A list of values in a menu. The menu draws in the Overlay that
/// `InspectorOverlay` provides; Pinpoint has no Navigator above it, so a
/// `DropdownButton` (a route) cannot open here.
class _ChoiceField extends StatelessWidget {
  const _ChoiceField({
    super.key,
    required this.value,
    required this.editor,
    required this.itemKey,
    required this.onChanged,
  });

  final Object? value;
  final ChoiceEditor<Object?> editor;
  final Key Function(String label) itemKey;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final current = editor.choices.contains(value)
        ? editor.labelOf(value)
        : '$value';
    return MenuAnchor(
      menuChildren: [
        for (final choice in editor.choices)
          MenuItemButton(
            key: itemKey(editor.labelOf(choice)),
            onPressed: () => onChanged(choice),
            child: Text(editor.labelOf(choice), style: style),
          ),
      ],
      builder: (context, menu, _) => OutlinedButton(
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

/// A hex field with a swatch: `#RRGGBB`, or `#AARRGGBB` with alpha.
class _ColorField extends StatefulWidget {
  const _ColorField({super.key, required this.value, required this.onChanged});

  final Color? value;
  final ValueChanged<Color> onChanged;

  @override
  State<_ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<_ColorField> {
  late final TextEditingController _text = TextEditingController(
    text: _format(widget.value),
  );
  late final FocusNode _focus = FocusNode(debugLabel: 'pinpoint tweak color')
    ..addListener(() {
      if (!_focus.hasFocus) _submit();
    });

  static String _format(Color? c) => c == null ? '' : formatColor(c);

  @override
  void didUpdateWidget(_ColorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != oldWidget.value) {
      _text.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final color = parseHexColor(_text.text);
    if (color == null) {
      _text.text = _format(widget.value);
      return;
    }
    _text.text = _format(color);
    if (color != widget.value) widget.onChanged(color);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: widget.value,
            border: Border.all(color: const Color(0x61000000)),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _text,
              focusNode: _focus,
              style: Theme.of(context).textTheme.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 8,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
        ),
      ],
    );
  }
}

/// `#RRGGBB`, `#AARRGGBB`, with or without `#`, as a color; else null.
Color? parseHexColor(String text) {
  var hex = text.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(hex)) {
    return null;
  }
  final value = int.parse(hex, radix: 16);
  return Color(hex.length == 6 ? 0xFF000000 | value : value);
}

/// Four fields for left, top, right and bottom. Linked (the default when
/// all four are equal), a change to one sets all four.
class _InsetsField extends StatefulWidget {
  const _InsetsField({
    required this.value,
    required this.keyOf,
    required this.step,
    required this.onChanged,
  });

  final EdgeInsets value;
  final Key Function([String? part]) keyOf;
  final double step;
  final ValueChanged<EdgeInsets> onChanged;

  @override
  State<_InsetsField> createState() => _InsetsFieldState();
}

class _InsetsFieldState extends State<_InsetsField> {
  late bool _linked = _uniform(widget.value);

  static bool _uniform(EdgeInsets e) =>
      e.left == e.top && e.top == e.right && e.right == e.bottom;

  void _set(String side, double? v) {
    final n = v ?? 0;
    final e = widget.value;
    widget.onChanged(
      _linked
          ? EdgeInsets.all(n)
          : switch (side) {
              'left' => e.copyWith(left: n),
              'top' => e.copyWith(top: n),
              'right' => e.copyWith(right: n),
              _ => e.copyWith(bottom: n),
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.value;
    final sides = {
      'left': e.left,
      'top': e.top,
      'right': e.right,
      'bottom': e.bottom,
    };
    final small = Theme.of(context).textTheme.labelSmall;
    return Row(
      children: [
        for (final MapEntry(key: side, value: v) in sides.entries)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(side[0].toUpperCase(), style: small),
                  _NumberField(
                    key: widget.keyOf(side),
                    value: v,
                    min: 0,
                    step: widget.step,
                    compact: true,
                    onChanged: (n) => _set(side, n),
                  ),
                ],
              ),
            ),
          ),
        IconButton(
          key: widget.keyOf('link'),
          tooltip: _linked ? 'Linked: one value for all sides' : 'Each side',
          visualDensity: VisualDensity.compact,
          isSelected: _linked,
          icon: Icon(_linked ? Icons.link : Icons.link_off, size: 16),
          onPressed: () => setState(() => _linked = !_linked),
        ),
      ],
    );
  }
}

/// Minimum and maximum width and height of an added constraint. A maximum
/// accepts `∞`.
class _ConstraintsField extends StatelessWidget {
  const _ConstraintsField({
    required this.value,
    required this.keyOf,
    required this.step,
    required this.onChanged,
  });

  final BoxConstraints value;
  final Key Function([String? part]) keyOf;
  final double step;
  final ValueChanged<BoxConstraints> onChanged;

  /// [value] with [field] set to [v]. Moving a minimum above its maximum
  /// moves the maximum too, and the other way round, so the constraints
  /// stay valid.
  BoxConstraints _with(String field, double v) {
    var c = value;
    switch (field) {
      case 'minWidth':
        c = c.copyWith(minWidth: v, maxWidth: v > c.maxWidth ? v : null);
      case 'maxWidth':
        c = c.copyWith(maxWidth: v, minWidth: v < c.minWidth ? v : null);
      case 'minHeight':
        c = c.copyWith(minHeight: v, maxHeight: v > c.maxHeight ? v : null);
      default:
        c = c.copyWith(maxHeight: v, minHeight: v < c.minHeight ? v : null);
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelSmall;
    final fields = {
      'minWidth': value.minWidth,
      'maxWidth': value.maxWidth,
      'minHeight': value.minHeight,
      'maxHeight': value.maxHeight,
    };
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final MapEntry(key: field, value: v) in fields.entries)
          SizedBox(
            width: 112,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(field, style: small),
                _NumberField(
                  key: keyOf(field),
                  value: v,
                  min: 0,
                  infinite: field.startsWith('max'),
                  step: step,
                  compact: true,
                  onChanged: (n) {
                    if (n != null) onChanged(_with(field, n));
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Width and color of a border that is the same on every side.
class _BorderField extends StatelessWidget {
  const _BorderField({
    required this.value,
    required this.keyOf,
    required this.onChanged,
  });

  final Border value;
  final Key Function([String? part]) keyOf;
  final ValueChanged<Border> onChanged;

  @override
  Widget build(BuildContext context) {
    final side = value.top;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: _NumberField(
            key: keyOf('width'),
            value: side.width,
            min: 0,
            step: 0.5,
            compact: true,
            onChanged: (w) =>
                onChanged(Border.fromBorderSide(side.copyWith(width: w ?? 0))),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _ColorField(
            key: keyOf('color'),
            value: side.color,
            onChanged: (c) =>
                onChanged(Border.fromBorderSide(side.copyWith(color: c))),
          ),
        ),
      ],
    );
  }
}
