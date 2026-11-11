import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../info/widget_info.dart';
import '../search/pick_result.dart';
import '../theme/controls.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_tokens.dart';
import '../tweak/tweak_scope.dart';
import '../tweak/tweak_session.dart';
import 'panel_parts.dart';

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
///
/// The tab's footer ([TweakFooter]) is a separate widget: the info panel
/// keeps it under the scrolling body.
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

  /// The key of the button that resets [property] in [section]. It shows
  /// beside the editor in a section with several editable properties; with
  /// one, the section's own button ([sectionResetKey]) does the same.
  static Key resetKey(String section, String property) =>
      ValueKey<String>('pinpoint.tweak.$section.$property.reset');

  /// The key of the button in the heading of [section] that resets every
  /// tweak in it.
  static Key sectionResetKey(String section) =>
      ValueKey<String>('pinpoint.tweak.$section.reset');

  static const Key resetAllKey = ValueKey<String>('pinpoint.tweak.resetAll');
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
    final tokens = PinPointTokens.of(context);
    List<TweakTarget> targets;
    try {
      targets = tweakTargetsFor(widget.selection);
    } catch (_) {
      // The tracker clears a selection whose element is gone after the
      // next frame; until then there is nothing to read.
      targets = const <TweakTarget>[];
    }
    final chain = constraintChain(widget.selection.renderObject);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(width: panelLabelWidth, child: const CapsText('STEP')),
            DraftSegmented<int>(
              items: const [(1, '1'), (4, '4'), (8, '8')],
              value: _step,
              onChanged: (step) => setState(() => _step = step),
              cellKey: TweakTab.stepKey,
            ),
          ],
        ),
        if (targets.isEmpty) ...[
          const SizedBox(height: PinPointSizes.sectionGap),
          Container(
            key: TweakTab.emptyKey,
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tokens.rule)),
            ),
            child: Text(
              'Nothing to tweak on this widget. Tweak edits padding, size, '
              'flex, alignment, text style and decoration it already has.',
              style: tokens.label,
            ),
          ),
        ],
        for (final (n, target) in targets.indexed) ...[
          const SizedBox(height: PinPointSizes.sectionGap),
          _section(tokens, target, n + 1),
        ],
        const SizedBox(height: PinPointSizes.sectionGap),
        _ChainSection(
          key: TweakTab.chainKey,
          heading: sectionHeading(targets.length + 1, 'Constraint chain'),
          rows: chain,
          expanded: _showChain,
          onToggle: () => setState(() => _showChain = !_showChain),
        ),
        const SizedBox(height: PinPointSizes.sectionGap),
        Text(
          'To add a widget (for example wrap this in a Padding), write it '
          'in the comment.',
          style: tokens.label.copyWith(fontSize: 11, height: 14 / 11),
        ),
      ],
    );
  }

  Widget _section(PinPointTokens tokens, TweakTarget target, int number) {
    final section = target.section;
    final tweaks = <Tweak>[
      for (final property in section.properties)
        ?widget.session.tweakOf(target, property.name),
    ];
    final editable = section.properties.where((p) => p.editable).length;
    final created = target.createdBy;
    return PanelSection(
      heading: sectionHeading(number, section.title),
      detail:
          '${target.renderObject.runtimeType}'
          '${created == null ? '' : ' from $created'}',
      modified: tweaks.isNotEmpty,
      onReset: tweaks.isEmpty
          ? null
          : () {
              for (final tweak in tweaks) {
                widget.session.reset(tweak);
              }
            },
      resetKey: TweakTab.sectionResetKey(section.title),
      resetTooltip: 'Reset ${section.title}',
      children: [
        for (final property in section.properties)
          _property(tokens, target, property, rowReset: editable > 1),
      ],
    );
  }

  Widget _property(
    PinPointTokens tokens,
    TweakTarget target,
    InfoProperty<Object?> property, {
    required bool rowReset,
  }) {
    final tweak = widget.session.tweakOf(target, property.name);
    final tweaked = tweak != null;
    final note = property.note;
    final small = tokens.label.copyWith(fontSize: 11, height: 14 / 11);
    final Widget row;
    if (!property.editable) {
      row = Row(
        children: [
          Flexible(
            child: Text(
              property.label,
              style: tokens.value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: note ?? 'Not editable here. Change it in source.',
            triggerMode: TooltipTriggerMode.tap,
            child: Opacity(
              opacity: 0.6,
              child: Icon(PinPointIcons.lock, size: 14, color: tokens.ink),
            ),
          ),
        ],
      );
    } else {
      final editor = property.editor!;
      final grows = editor is! NumberEditor && editor is! RadiusEditor;
      final built = _editorFor(target, property, tweak);
      // A colour field carries its own reset; an inset is reset by its
      // section's button.
      final trailing = tweaked && rowReset && editor is! ColorEditor;
      row = Row(
        children: [
          if (grows) Expanded(child: built) else built,
          if (trailing) ...[
            const SizedBox(width: 6),
            DraftIconButton(
              key: TweakTab.resetKey(target.section.title, property.name),
              icon: PinPointIcons.restartAlt,
              iconSize: 14,
              extent: 20,
              tooltip: 'Reset ${property.name}',
              onPressed: () => widget.session.reset(tweak),
            ),
          ],
        ],
      );
    }
    return PanelRow(
      name: property.name,
      nameColor: tweaked ? tokens.editInk : null,
      nameWeight: tweaked ? FontWeight.w500 : null,
      nameInset: property.editable ? 4 : 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          if (tweaked)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'was ${tweak.fromLabel}',
                style: tokens.micro,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Watch out (plan): a widget that builds every frame resets the
          // value every frame; the session stops fighting it.
          if (tweaked && tweak.animating)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'This widget is animating; tweak cannot hold.',
                style: small.copyWith(color: tokens.err),
              ),
            ),
        ],
      ),
    );
  }

  Widget _editorFor(
    TweakTarget target,
    InfoProperty<Object?> property,
    Tweak? tweak,
  ) {
    final section = target.section.title;
    final name = property.name;
    Key key([String? part]) => TweakTab.fieldKey(section, name, part);
    void set(Object? value) => widget.onApply(target, name, value);
    final value = property.value;
    final tweaked = tweak != null;
    final original = tweak?.original;
    return switch (property.editor!) {
      final NumberEditor e => _NumberField(
        key: key(),
        value: value is num ? value.toDouble() : null,
        integer: e.integer,
        nullable: e.nullable,
        min: e.min,
        max: e.max,
        step: e.spacing ? _step.toDouble() : e.step,
        tweaked: tweaked,
        onChanged: (v) => set(e.integer ? v?.round() : v),
      ),
      final ChoiceEditor<Object?> e => _ChoiceField(
        key: key(),
        value: value,
        editor: e,
        tweaked: tweaked,
        itemKey: (label) => TweakTab.choiceKey(section, name, label),
        onChanged: set,
      ),
      ColorEditor() => _ColorField(
        key: key(),
        value: value is Color ? value : null,
        tweaked: tweaked,
        onReset: tweaked ? () => widget.session.reset(tweak) : null,
        resetKey: TweakTab.resetKey(section, name),
        onChanged: set,
      ),
      InsetsEditor() => _InsetsField(
        value: value is EdgeInsets ? value : EdgeInsets.zero,
        original: tweaked && original is EdgeInsets ? original : null,
        tweaked: tweaked,
        keyOf: key,
        step: _step.toDouble(),
        onChanged: set,
      ),
      ConstraintsEditor() => _ConstraintsField(
        value: value is BoxConstraints ? value : const BoxConstraints(),
        original: tweaked && original is BoxConstraints ? original : null,
        tweaked: tweaked,
        keyOf: key,
        step: _step.toDouble(),
        onChanged: set,
      ),
      RadiusEditor() => _NumberField(
        key: key(),
        value: value is BorderRadius ? value.topLeft.x : 0,
        min: 0,
        step: _step.toDouble(),
        tweaked: tweaked,
        onChanged: (v) => set(BorderRadius.circular(v ?? 0)),
      ),
      BorderEditor() => _BorderField(
        value: value is Border ? value : const Border(),
        original: tweaked && original is Border ? original : null,
        tweaked: tweaked,
        keyOf: key,
        onChanged: set,
      ),
    };
  }
}

/// The footer of the Tweak tab: `N tweaks` and `Reset all`. Empty while
/// there is no tweak.
class TweakFooter extends StatelessWidget {
  const TweakFooter({super.key, required this.session});

  final TweakSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final n = session.length;
        if (n == 0) return const SizedBox.shrink();
        final tokens = PinPointTokens.of(context);
        return Container(
          height: PinPointSizes.footer,
          padding: const EdgeInsets.only(left: 12, right: 2),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.ink)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  n == 1 ? '1 tweak' : '$n tweaks',
                  style: tokens.value.copyWith(
                    fontSize: 11,
                    color: tokens.muted,
                  ),
                ),
              ),
              DraftButton.link(
                key: TweakTab.resetAllKey,
                label: 'Reset all',
                onPressed: session.resetAll,
              ),
            ],
          ),
        );
      },
    );
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

/// `04 CONSTRAINT CHAIN`: a 28 px row with a plus and the count, which opens
/// to a two-column list of render ancestors and what each gives down.
class _ChainSection extends StatelessWidget {
  const _ChainSection({
    super.key,
    required this.heading,
    required this.rows,
    required this.expanded,
    required this.onToggle,
  });

  final String heading;
  final List<(String, String)> rows;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final mono = tokens.value.copyWith(fontSize: 11, height: 14 / 11);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          label: expanded
              ? 'Hide constraints from above'
              : 'Constraints from above',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Container(
                height: PinPointSizes.rowHeight,
                decoration: BoxDecoration(
                  border: Border.symmetric(
                    horizontal: BorderSide(color: tokens.rule),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.remove : PinPointIcons.add,
                      size: 16,
                      color: tokens.ink,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: CapsText(heading, color: tokens.ink)),
                    Text(
                      '${rows.length}',
                      style: tokens.value.copyWith(
                        fontSize: 11,
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, row) in rows.indexed) ...[
                  if (i > 0) const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            row.$1,
                            style: mono,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          row.$2,
                          style: mono.copyWith(color: tokens.muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// A number with a stepper. Enter or leaving the field applies what was
/// typed; the arrow keys and the buttons apply one [step] at once.
///
/// With [compact] there are no stepper buttons: a field with a small
/// [prefix] letter, for the four sides of an inset.
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
    this.tweaked = false,
    this.prefix,
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

  /// The value differs from the widget's own.
  final bool tweaked;

  /// A letter or two before the value, in a [compact] field.
  final String? prefix;

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
    // The frame shows focus.
    if (mounted) setState(() {});
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
    final tokens = PinPointTokens.of(context);
    final state = _focus.hasFocus
        ? FieldState.focus
        : widget.tweaked
        ? FieldState.tweaked
        : FieldState.rest;
    final textColor = state == FieldState.tweaked ? tokens.editInk : tokens.ink;
    final field = TextField(
      controller: _text,
      focusNode: _focus,
      style: tokens.value.copyWith(color: textColor),
      textAlign: widget.compact ? TextAlign.start : TextAlign.center,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: InputDecoration.collapsed(
        hintText: widget.nullable ? 'none' : null,
        hintStyle: tokens.value.copyWith(color: tokens.faint),
      ),
      onSubmitted: (_) => _submit(),
    );
    if (widget.compact) {
      final prefix = widget.prefix;
      return DraftFieldFrame(
        state: state,
        child: Row(
          children: [
            if (prefix != null) ...[
              Text(
                prefix,
                style: tokens.value.copyWith(
                  fontSize: 10,
                  color: state == FieldState.tweaked
                      ? tokens.editInk
                      : tokens.faint,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(child: field),
          ],
        ),
      );
    }
    return DraftStepper(
      state: state,
      valueWidth: 40,
      minusKey: _partKey('dec'),
      plusKey: _partKey('inc'),
      onMinus: () => _nudge(-1),
      onPlus: () => _nudge(1),
      value: field,
    );
  }

  Key? _partKey(String part) {
    final key = widget.key;
    return key is ValueKey<String>
        ? ValueKey<String>('${key.value}.$part')
        : null;
  }
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
    this.tweaked = false,
  });

  final Object? value;
  final ChoiceEditor<Object?> editor;
  final Key Function(String label) itemKey;
  final ValueChanged<Object?> onChanged;
  final bool tweaked;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final current = editor.choices.contains(value)
        ? editor.labelOf(value)
        : '$value';
    return MenuAnchor(
      menuChildren: [
        for (final choice in editor.choices)
          MenuItemButton(
            key: itemKey(editor.labelOf(choice)),
            onPressed: () => onChanged(choice),
            child: Text(editor.labelOf(choice), style: tokens.value),
          ),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: current,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => menu.isOpen ? menu.close() : menu.open(),
            child: DraftFieldFrame(
              state: menu.isOpen
                  ? FieldState.focus
                  : tweaked
                  ? FieldState.tweaked
                  : FieldState.rest,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(PinPointIcons.expandMore),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A hex field with a swatch: `#RRGGBB`, or `#AARRGGBB` with alpha. While
/// the text is not a colour it shows the invalid look and says what is
/// accepted; leaving the field then puts the colour back.
class _ColorField extends StatefulWidget {
  const _ColorField({
    super.key,
    required this.value,
    required this.onChanged,
    this.tweaked = false,
    this.onReset,
    this.resetKey,
  });

  final Color? value;
  final ValueChanged<Color> onChanged;
  final bool tweaked;

  /// Shows a `restart_alt` button in the tweaked field.
  final VoidCallback? onReset;
  final Key? resetKey;

  @override
  State<_ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<_ColorField> {
  late final TextEditingController _text = TextEditingController(
    text: _format(widget.value),
  )..addListener(_onText);
  late final FocusNode _focus = FocusNode(debugLabel: 'pinpoint tweak color')
    ..addListener(() {
      if (!_focus.hasFocus) _submit();
      if (mounted) setState(() {});
    });

  static String _format(Color? c) => c == null ? '' : formatColor(c);

  // The invalid look follows what is typed.
  String _seen = '';
  void _onText() {
    if (_text.text == _seen) return;
    _seen = _text.text;
    if (mounted) setState(() {});
  }

  bool get _invalid =>
      parseHexColor(_text.text) == null &&
      !(widget.value == null && _text.text.trim().isEmpty);

  @override
  void initState() {
    super.initState();
    _seen = _text.text;
  }

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

  // The chevron has no list to open: it puts the cursor in the field with
  // the hex selected, ready to be typed over.
  void _edit() {
    _focus.requestFocus();
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final invalid = _invalid;
    final state = invalid
        ? FieldState.invalid
        : _focus.hasFocus
        ? FieldState.focus
        : widget.tweaked
        ? FieldState.tweaked
        : FieldState.rest;
    final textColor = state == FieldState.tweaked ? tokens.editInk : tokens.ink;
    final Widget trailing;
    if (invalid) {
      trailing = Icon(PinPointIcons.error, color: tokens.err);
    } else if (widget.tweaked && widget.onReset != null) {
      trailing = DraftIconButton(
        key: widget.resetKey,
        icon: PinPointIcons.restartAlt,
        iconSize: 15,
        extent: 20,
        color: tokens.editInk,
        tooltip: 'Reset color',
        onPressed: widget.onReset,
      );
    } else {
      trailing = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _edit,
        child: const Icon(PinPointIcons.expandMore),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DraftFieldFrame(
          state: state,
          child: Row(
            children: [
              _Swatch(color: invalid ? null : widget.value),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  style: tokens.value.copyWith(color: textColor),
                  decoration: const InputDecoration.collapsed(hintText: null),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              trailing,
            ],
          ),
        ),
        if (invalid)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Use 6 or 8 hex digits',
              style: tokens.body.copyWith(
                fontSize: 11,
                height: 14 / 11,
                color: tokens.err,
              ),
            ),
          ),
      ],
    );
  }
}

/// 14 px of colour in a 1 px ink ring. A null [color] is hatched: there is no
/// colour to show.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: tokens.ink),
      ),
      child: color == null
          ? CustomPaint(painter: _HatchPainter(tokens.field))
          : null,
    );
  }
}

class _HatchPainter extends CustomPainter {
  const _HatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    // 45 degree lines, 5 px apart.
    for (var d = -size.height; d < size.width + size.height; d += 5) {
      canvas.drawLine(
        Offset(d, size.height),
        Offset(d + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
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
/// all four are equal), a change to one sets all four. A side that differs
/// from the widget's own [original] is drawn as tweaked.
class _InsetsField extends StatefulWidget {
  const _InsetsField({
    required this.value,
    required this.original,
    required this.tweaked,
    required this.keyOf,
    required this.step,
    required this.onChanged,
  });

  final EdgeInsets value;

  /// The widget's own value, when tweaked.
  final EdgeInsets? original;
  final bool tweaked;
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
    final o = widget.original;
    final sides = {
      'left': (e.left, o?.left),
      'top': (e.top, o?.top),
      'right': (e.right, o?.right),
      'bottom': (e.bottom, o?.bottom),
    };
    return Row(
      children: [
        for (final MapEntry(key: side, value: (v, was)) in sides.entries)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _NumberField(
                key: widget.keyOf(side),
                value: v,
                min: 0,
                step: widget.step,
                compact: true,
                prefix: side[0].toUpperCase(),
                tweaked: widget.tweaked && (was == null || was != v),
                onChanged: (n) => _set(side, n),
              ),
            ),
          ),
        DraftIconButton(
          key: widget.keyOf('link'),
          tooltip: _linked ? 'Linked: one value for all sides' : 'Each side',
          icon: _linked ? PinPointIcons.link : PinPointIcons.linkOff,
          iconSize: 16,
          extent: 20,
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
    required this.original,
    required this.tweaked,
    required this.keyOf,
    required this.step,
    required this.onChanged,
  });

  final BoxConstraints value;

  /// The widget's own value, when tweaked.
  final BoxConstraints? original;
  final bool tweaked;
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
    final o = original;
    final fields = [
      ('minWidth', 'min w', value.minWidth, o?.minWidth),
      ('maxWidth', 'max w', value.maxWidth, o?.maxWidth),
      ('minHeight', 'min h', value.minHeight, o?.minHeight),
      ('maxHeight', 'max h', value.maxHeight, o?.maxHeight),
    ];
    Widget cell((String, String, double, double?) f) => Expanded(
      child: _NumberField(
        key: keyOf(f.$1),
        value: f.$3,
        min: 0,
        infinite: f.$1.startsWith('max'),
        step: step,
        compact: true,
        prefix: f.$2,
        tweaked: tweaked && (f.$4 == null || f.$4 != f.$3),
        onChanged: (n) {
          if (n != null) onChanged(_with(f.$1, n));
        },
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            cell(fields[0]),
            const SizedBox(width: 6),
            cell(fields[1]),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            cell(fields[2]),
            const SizedBox(width: 6),
            cell(fields[3]),
          ],
        ),
      ],
    );
  }
}

/// Width and color of a border that is the same on every side.
class _BorderField extends StatelessWidget {
  const _BorderField({
    required this.value,
    required this.original,
    required this.tweaked,
    required this.keyOf,
    required this.onChanged,
  });

  final Border value;

  /// The widget's own value, when tweaked.
  final Border? original;
  final bool tweaked;
  final Key Function([String? part]) keyOf;
  final ValueChanged<Border> onChanged;

  @override
  Widget build(BuildContext context) {
    final side = value.top;
    final was = original?.top;
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
            prefix: 'w',
            tweaked: tweaked && (was == null || was.width != side.width),
            onChanged: (w) =>
                onChanged(Border.fromBorderSide(side.copyWith(width: w ?? 0))),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _ColorField(
            key: keyOf('color'),
            value: side.color,
            tweaked: tweaked && (was == null || was.color != side.color),
            onChanged: (c) =>
                onChanged(Border.fromBorderSide(side.copyWith(color: c))),
          ),
        ),
      ],
    );
  }
}

/// "N tweaks active", top center, in every mode while any edit is active,
/// so a changed screen is never taken for the real one. Its button resets
/// them all.
///
/// The look of an active override: 1.5 px `edit` border, `editBg` fill, mono
/// text in `editInk`, 2 px corners. A warning glyph replaces the tune glyph
/// while a tweaked widget animates, so the state does not rest on colour.
class TweakChip extends StatelessWidget {
  const TweakChip({super.key, required this.session});

  static const Key chipKey = ValueKey<String>('pinpoint.tweak.chip');
  static const Key resetKey = ValueKey<String>('pinpoint.tweak.chip.reset');

  final TweakSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final n = session.length;
      if (n == 0) return const SizedBox.shrink();
      final tokens = PinPointTokens.of(context);
      final animating = session.tweaks.any((t) => t.animating);
      return SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            // A Material for the default text style; it paints nothing.
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: chipKey,
                height: PinPointSizes.controlHeight + 2,
                padding: const EdgeInsets.only(left: 8, right: 2),
                decoration: BoxDecoration(
                  color: tokens.editBg,
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: tokens.edit, width: 1.5),
                  boxShadow: tokens.e1,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      animating ? PinPointIcons.warning : PinPointIcons.tune,
                      size: 14,
                      color: tokens.editInk,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      n == 1 ? '1 tweak active' : '$n tweaks active',
                      style: tokens.value.copyWith(color: tokens.editInk),
                    ),
                    const SizedBox(width: 2),
                    DraftIconButton(
                      key: resetKey,
                      tooltip: 'Reset every tweak',
                      icon: PinPointIcons.close,
                      iconSize: 14,
                      color: tokens.editInk,
                      onPressed: session.resetAll,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A dotted outline around every edited render object, in every mode:
/// 1.5 px dotted `edit` over a paper halo ([paintTweaked]).
///
/// Repaints when [outlines] changes; the session reads them after each
/// frame the app draws, so it adds no frames of its own. [tokens] are the
/// palette's colours; a painter has no context to read them from, so the
/// overlay passes them in.
class TweakOutlinePainter extends CustomPainter {
  TweakOutlinePainter({
    required this.outlines,
    required this.origin,
    this.tokens = PinPointTokens.redline,
  }) : super(repaint: outlines);

  final ValueListenable<List<Rect>> outlines;

  /// The painter's own top-left in global logical pixels.
  final Offset Function() origin;

  final PinPointTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final rects = outlines.value;
    if (rects.isEmpty) return;
    final shift = -origin();
    for (final rect in rects) {
      paintTweaked(canvas, rect.shift(shift), tokens);
    }
  }

  @override
  bool shouldRepaint(TweakOutlinePainter oldDelegate) =>
      oldDelegate.outlines != outlines || oldDelegate.tokens != tokens;
}
