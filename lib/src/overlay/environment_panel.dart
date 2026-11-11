import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pinpoint_controller.dart';
import '../env/device_presets.dart';
import '../env/environment_controller.dart';
import '../info/widget_info.dart' show formatColor;
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import 'panel_keys.dart';
import 'rail.dart';

/// A seed color's option value in the panel: its hex without `#`.
String formatSeed(Color color) => formatColor(color).substring(1);

/// The what-if bar, bottom-left: a strip with one chip per active override,
/// each with a close that resets it, and a reset for all of them.
///
/// It shows while any override is active, in idle too: the app looks
/// different from the real thing, and the bar says so. The what-if panel is
/// opened from the rail, whose What-if item has [toggleKey].
class EnvironmentBar extends StatelessWidget {
  const EnvironmentBar({super.key, required this.controller});

  static const Key barKey = ValueKey<String>('pinpoint.env.bar');

  /// The What-if item of the rail.
  static const Key toggleKey = ValueKey<String>('pinpoint.env.toggle');
  static const Key resetKey = ValueKey<String>('pinpoint.env.reset');

  /// The chip of the override [name], for example `viewport`.
  static Key chipKey(String name) =>
      ValueKey<String>('pinpoint.env.chip.$name');

  final PinPointController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.environment,
    builder: (context, _) => _build(context),
  );

  /// The active overrides of [env]: a name, a label, and a copy of the
  /// environment without that one.
  static List<(String, String, Environment Function(Environment))> overrides(
    Environment env,
  ) => [
    if (env.viewport case final v?)
      ('viewport', sizeLabelOf(v), (e) => e.copyWith(viewport: () => null)),
    if (env.textScale case final t?)
      (
        'textScale',
        'text ${_number(t)}×',
        (e) => e.copyWith(textScale: () => null),
      ),
    if (env.boldText == true)
      ('bold', 'bold', (e) => e.copyWith(boldText: () => null)),
    if (env.safeArea != null)
      ('safeArea', 'safe area', (e) => e.copyWith(safeArea: () => null)),
    if (env.keyboardHeight != null)
      ('keyboard', 'keyboard', (e) => e.copyWith(keyboardHeight: () => null)),
    if (env.textDirection case final d?)
      (
        'direction',
        d == TextDirection.rtl ? 'RTL' : 'LTR',
        (e) => e.copyWith(textDirection: () => null),
      ),
    if (env.themeVariant case final t?)
      ('theme', t, (e) => e.copyWith(themeVariant: () => null))
    else if (env.brightness case final b?)
      ('theme', b.name, (e) => e.copyWith(brightness: () => null)),
    if (env.seedColor case final c?)
      (
        'seed',
        'seed ${formatColor(c)}',
        (e) => e.copyWith(seedColor: () => null),
      ),
    if (env.platform case final p?)
      ('platform', p.name, (e) => e.copyWith(platform: () => null)),
    if (env.timeDilation case final t?)
      (
        'slow',
        'slow ${_number(t)}×',
        (e) => e.copyWith(timeDilation: () => null),
      ),
  ];

  Widget _build(BuildContext context) {
    final environment = controller.environment;
    if (!environment.isActive) return const SizedBox.shrink();
    final tokens = PinPointTokens.of(context);
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          // Clear of the rail, which sits on the right edge.
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16 + RailPlacement.width + RailPlacement.inset,
            16,
          ),
          child: DraftSurface(
            key: barKey,
            elevation: 2,
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('WHAT-IF', style: tokens.caps),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (name, label, without) in overrides(
                        environment.value,
                      ))
                        DraftChip(
                          key: chipKey(name),
                          label: label,
                          look: ChipLook.override,
                          onTap: () => environment.update(without),
                          onClear: () => environment.update(without),
                        ),
                    ],
                  ),
                ),
                DraftIconButton(
                  key: resetKey,
                  icon: PinPointIcons.restartAlt,
                  tooltip: 'Reset every what-if switch',
                  onPressed: environment.reset,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A number without a trailing `.0`.
String _number(double value) => value == value.truncateToDouble()
    ? value.toInt().toString()
    : value.toString();

/// A swatch of a seed color: a 24 px square with 2 px corners. Selected, it
/// gets a heavier ink border and a check, so the pick does not rest on color.
/// [onTap] null disables it.
class SeedSwatchChip extends StatelessWidget {
  const SeedSwatchChip({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final enabled = onTap != null;
    final onColor = color.computeLuminance() > 0.5
        ? const Color(0xFF111111)
        : const Color(0xFFFFFFFF);
    final swatch = Container(
      width: 24,
      height: 24,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: selected ? tokens.ink : tokens.field,
          width: selected ? 2 : 1,
        ),
      ),
      child: ColoredBox(
        color: color,
        child: selected
            ? Center(child: Icon(PinPointIcons.check, size: 12, color: onColor))
            : null,
      ),
    );
    return Tooltip(
      message: formatColor(color),
      child: Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        label: formatColor(color),
        excludeSemantics: true,
        onTap: onTap,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Opacity(opacity: enabled ? 1 : 0.4, child: swatch),
          ),
        ),
      ),
    );
  }
}

/// The what-if panel: every switch of the [environment], on the left.
class EnvironmentPanel extends StatefulWidget {
  const EnvironmentPanel({
    super.key,
    required this.environment,
    required this.onClose,
    this.themeVariants = const <String>[],
    this.material3 = true,
  });

  static const Key panelKey = ValueKey<String>('pinpoint.env.panel');
  static const Key closeKey = ValueKey<String>('pinpoint.env.close');
  static const Key widthKey = ValueKey<String>('pinpoint.env.width');
  static const Key heightKey = ValueKey<String>('pinpoint.env.height');
  static const Key rotateKey = ValueKey<String>('pinpoint.env.rotate');
  static const Key safeTopKey = ValueKey<String>('pinpoint.env.safeTop');
  static const Key safeBottomKey = ValueKey<String>('pinpoint.env.safeBottom');
  static const Key resetAllKey = ValueKey<String>('pinpoint.env.resetAll');

  /// The key of the option [value] in [section], for example
  /// `option('viewport', '360x800')`.
  static Key option(String section, String value) =>
      ValueKey<String>('pinpoint.env.$section.$value');

  final EnvironmentController environment;
  final VoidCallback onClose;

  /// The names of `PinPointConfig.themeVariants`. When not empty, the theme
  /// section lists these instead of light and dark.
  final List<String> themeVariants;

  /// Whether the app's theme is Material 3. The color scheme switch is off
  /// otherwise.
  final bool material3;

  @override
  State<EnvironmentPanel> createState() => _EnvironmentPanelState();
}

class _EnvironmentPanelState extends State<EnvironmentPanel> {
  final TextEditingController _width = TextEditingController();
  final TextEditingController _height = TextEditingController();
  final TextEditingController _safeTop = TextEditingController();
  final TextEditingController _safeBottom = TextEditingController();

  EnvironmentController get _env => widget.environment;

  @override
  void initState() {
    super.initState();
    _env.addListener(_syncFields);
    _showValues();
  }

  @override
  void didUpdateWidget(EnvironmentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.environment != widget.environment) {
      oldWidget.environment.removeListener(_syncFields);
      widget.environment.addListener(_syncFields);
      _showValues();
    }
  }

  @override
  void dispose() {
    _env.removeListener(_syncFields);
    _width.dispose();
    _height.dispose();
    _safeTop.dispose();
    _safeBottom.dispose();
    super.dispose();
  }

  void _syncFields() {
    _showValues();
    setState(() {});
  }

  /// The fields show the active values.
  void _showValues() {
    final env = _env.value;
    void show(TextEditingController field, double? value) {
      final text = value == null ? '' : _number(value);
      if (field.text != text) field.text = text;
    }

    show(_width, env.viewport?.width);
    show(_height, env.viewport?.height);
    show(_safeTop, env.safeArea?.top);
    show(_safeBottom, env.safeArea?.bottom);
  }

  static double? _parse(TextEditingController field) {
    final value = double.tryParse(field.text.trim());
    return value == null || value < 0 ? null : value;
  }

  void _applySize() {
    final width = _parse(_width);
    final height = _parse(_height);
    if (width == null || height == null || width < 1 || height < 1) {
      _syncFields();
      return;
    }
    _env.setViewport(Size(width, height));
  }

  void _applySafeArea() {
    final top = _parse(_safeTop) ?? 0;
    final bottom = _parse(_safeBottom) ?? 0;
    _env.update(
      (e) => e.copyWith(
        safeArea: () => EdgeInsets.only(top: top, bottom: bottom),
      ),
    );
  }

  void _set(Environment Function(Environment e) change) => _env.update(change);

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final env = _env.value;
    return PanelKeyScope(
      child: DraftSurface(
        key: EnvironmentPanel.panelKey,
        elevation: 3,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(tokens),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(PinPointSizes.panelPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _viewport(env),
                    _choices<double?>(
                      'Text scale',
                      'textScale',
                      env.textScale,
                      {
                        'system': null,
                        for (final step in textScaleSteps) _number(step): step,
                      },
                      label: (value, name) =>
                          value == null ? 'System' : '$name×',
                      onSelected: (v) =>
                          _set((e) => e.copyWith(textScale: () => v)),
                    ),
                    _switch(
                      'Bold text',
                      'bold',
                      env.boldText ?? false,
                      (on) => _set(
                        (e) => e.copyWith(boldText: () => on ? true : null),
                      ),
                    ),
                    _safeArea(env),
                    _switch(
                      'Fake keyboard (${_number(fakeKeyboardHeight)} px)',
                      'keyboard',
                      env.keyboardHeight != null,
                      (on) => _set(
                        (e) => e.copyWith(
                          keyboardHeight: () => on ? fakeKeyboardHeight : null,
                        ),
                      ),
                    ),
                    _choices<TextDirection?>(
                      'Direction',
                      'direction',
                      env.textDirection,
                      const {
                        'system': null,
                        'ltr': TextDirection.ltr,
                        'rtl': TextDirection.rtl,
                      },
                      label: (value, name) =>
                          value == null ? 'System' : name.toUpperCase(),
                      onSelected: (v) =>
                          _set((e) => e.copyWith(textDirection: () => v)),
                      note: 'Strings stay in the current locale.',
                    ),
                    _theme(env),
                    _seed(env),
                    _platform(env),
                    _choices<double?>(
                      'Slow motion',
                      'slow',
                      env.timeDilation,
                      {
                        for (final step in slowMotionSteps)
                          _number(step): step == 1 ? null : step,
                      },
                      label: (value, name) => '$name×',
                      onSelected: (v) =>
                          _set((e) => e.copyWith(timeDilation: () => v)),
                    ),
                    const SizedBox(height: PinPointSizes.sectionGap),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DraftButton.outline(
                        key: EnvironmentPanel.resetAllKey,
                        onPressed: env.isEmpty ? null : _env.reset,
                        icon: PinPointIcons.restartAlt,
                        label: 'Reset all',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(PinPointTokens tokens) => Container(
    height: PinPointSizes.panelHeader,
    padding: const EdgeInsets.only(left: PinPointSizes.panelPadding, right: 8),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: tokens.ink)),
    ),
    child: Row(
      children: [
        Expanded(child: Text('What-if', style: tokens.title)),
        DraftIconButton(
          key: EnvironmentPanel.closeKey,
          icon: PinPointIcons.close,
          tooltip: 'Close',
          onPressed: widget.onClose,
        ),
      ],
    ),
  );

  Widget _viewport(Environment env) {
    final size = env.viewport;
    String keyOf(Size s) => '${s.width.toInt()}x${s.height.toInt()}';
    final selected = size == null
        ? 'window'
        : devicePresets
                  .map((p) => p.size)
                  .where((s) => s == size || s.flipped == size)
                  .map(keyOf)
                  .firstOrNull ??
              'custom';
    return _section(
      'Viewport',
      first: true,
      [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _chip('viewport', 'window', 'Window', selected == 'window', () {
              _env.setViewport(null);
            }),
            for (final preset in devicePresets)
              Tooltip(
                message: preset.name,
                child: _chip(
                  'viewport',
                  keyOf(preset.size),
                  preset.sizeLabel,
                  selected == keyOf(preset.size),
                  () => _env.setViewport(preset.size),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _field(
                EnvironmentPanel.widthKey,
                _width,
                'Width',
                _applySize,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('×', style: PinPointTokens.of(context).value),
            ),
            Expanded(
              child: _field(
                EnvironmentPanel.heightKey,
                _height,
                'Height',
                _applySize,
              ),
            ),
            const SizedBox(width: 4),
            DraftIconButton(
              key: EnvironmentPanel.rotateKey,
              tooltip: 'Rotate',
              onPressed: size == null ? null : _env.rotate,
              icon: Icons.screen_rotation,
            ),
          ],
        ),
      ],
      note:
          'Device pixel ratio cannot be faked. Code that reads '
          'View.of(context) or PlatformDispatcher directly still sees the '
          'real window.',
    );
  }

  Widget _safeArea(Environment env) {
    final area = env.safeArea;
    final selected = area == null
        ? 'system'
        : area == EdgeInsets.zero
        ? 'none'
        : area == notchSafeArea
        ? 'notch'
        : 'custom';
    return _section('Safe area', [
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _chip('safeArea', 'system', 'System', selected == 'system', () {
            _set((e) => e.copyWith(safeArea: () => null));
          }),
          _chip('safeArea', 'none', 'None', selected == 'none', () {
            _set((e) => e.copyWith(safeArea: () => EdgeInsets.zero));
          }),
          _chip(
            'safeArea',
            'notch',
            'Notch (59 / 34)',
            selected == 'notch',
            () {
              _set((e) => e.copyWith(safeArea: () => notchSafeArea));
            },
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _field(
              EnvironmentPanel.safeTopKey,
              _safeTop,
              'Top',
              _applySafeArea,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _field(
              EnvironmentPanel.safeBottomKey,
              _safeBottom,
              'Bottom',
              _applySafeArea,
            ),
          ),
        ],
      ),
    ]);
  }

  Widget _theme(Environment env) {
    if (widget.themeVariants.isNotEmpty) {
      return _choices<String?>(
        'Theme',
        'theme',
        env.themeVariant,
        {'system': null, for (final name in widget.themeVariants) name: name},
        label: (value, name) => value ?? 'App',
        onSelected: (v) => _set((e) => e.copyWith(themeVariant: () => v)),
        note: "The app's own themes, from PinPointConfig.themeVariants.",
      );
    }
    return _choices<Brightness?>(
      'Theme',
      'theme',
      env.brightness,
      const {
        'system': null,
        'light': Brightness.light,
        'dark': Brightness.dark,
      },
      label: (value, name) => value == null
          ? 'App'
          : '${name[0].toUpperCase()}${name.substring(1)}',
      onSelected: (v) => _set((e) => e.copyWith(brightness: () => v)),
      note: "Light and dark use the app's own theme and darkTheme.",
    );
  }

  Widget _seed(Environment env) {
    final enabled = widget.material3;
    return _section(
      'Color scheme',
      [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _chip(
              'seed',
              'none',
              'App',
              env.seedColor == null,
              enabled
                  ? () => _set((e) => e.copyWith(seedColor: () => null))
                  : null,
            ),
            for (final color in seedColors)
              SeedSwatchChip(
                key: EnvironmentPanel.option('seed', formatSeed(color)),
                color: color,
                selected: env.seedColor == color,
                onTap: enabled
                    ? () => _set((e) => e.copyWith(seedColor: () => color))
                    : null,
              ),
          ],
        ),
      ],
      // ThemeData.copyWith(colorScheme:) does not re-derive the component
      // themes of a Material 2 theme, so the colors would mix.
      note: enabled
          ? 'Material 3 only.'
          : 'Material 3 only: this app uses Material 2, where the colors '
                'would mix.',
    );
  }

  Widget _platform(Environment env) {
    // The override's setter throws outside debug builds.
    final enabled = kDebugMode;
    return _choices<TargetPlatform?>(
      'Platform',
      'platform',
      env.platform,
      {
        'system': null,
        for (final platform in TargetPlatform.values) platform.name: platform,
      },
      label: (value, name) => value == null ? 'System' : name,
      onSelected: enabled
          ? (v) => _set((e) => e.copyWith(platform: () => v))
          : null,
      note: [
        if (!enabled) 'Debug builds only.',
        'Rebuilds the whole app, like hot reload: the selection is cleared.',
        if (!kIsWeb)
          'Outside web, a switch between iOS or macOS and another platform '
              'also mounts the widgets above the Navigator again.',
      ].join(' '),
    );
  }

  Widget _choices<T>(
    String title,
    String section,
    T current,
    Map<String, T> options, {
    required String Function(T value, String name) label,
    required void Function(T value)? onSelected,
    String? note,
  }) => _section(title, [
    Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final MapEntry(key: name, :value) in options.entries)
          _chip(
            section,
            name,
            label(value, name),
            value == current,
            onSelected == null ? null : () => onSelected(value),
          ),
      ],
    ),
  ], note: note);

  Widget _chip(
    String section,
    String value,
    String label,
    bool selected,
    VoidCallback? onSelected,
  ) => DraftChip(
    key: EnvironmentPanel.option(section, value),
    label: label,
    look: onSelected == null
        ? ChipLook.disabled
        : selected
        ? ChipLook.selected
        : ChipLook.rest,
    onTap: onSelected,
  );

  Widget _switch(
    String title,
    String section,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(top: PinPointSizes.sectionGap),
    child: Align(
      alignment: Alignment.centerLeft,
      child: DraftCheckbox(
        key: EnvironmentPanel.option(section, 'switch'),
        value: value,
        onChanged: onChanged,
        label: title,
      ),
    ),
  );

  Widget _field(
    Key key,
    TextEditingController controller,
    String label,
    VoidCallback onSubmit,
  ) {
    final tokens = PinPointTokens.of(context);
    return SizedBox(
      height: PinPointSizes.controlHeight,
      child: TextField(
        key: key,
        controller: controller,
        style: tokens.value,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        textInputAction: TextInputAction.done,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 4,
          ),
          prefixText: '$label ',
          prefixStyle: tokens.label.copyWith(color: tokens.faint, fontSize: 10),
        ),
        onSubmitted: (_) => onSubmit(),
      ),
    );
  }

  /// A section: a 1 px `rule` on top (not on the first), 10 px below it, the
  /// caps title, the controls, and a note in small muted text.
  Widget _section(
    String title,
    List<Widget> children, {
    String? note,
    bool first = false,
  }) {
    final tokens = PinPointTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : PinPointSizes.sectionGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!first) ...[const DraftRule(), const SizedBox(height: 10)],
          CapsText(title.toUpperCase()),
          const SizedBox(height: 6),
          ...children,
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                note,
                style: tokens.label.copyWith(fontSize: 11, height: 14 / 11),
              ),
            ),
        ],
      ),
    );
  }
}

/// Places [EnvironmentPanel] beside the rail while it is open and a mode is
/// active. Only the panel takes pointer events.
class EnvironmentPanelLayer extends StatelessWidget {
  const EnvironmentPanelLayer({
    super.key,
    required this.controller,
    required this.panelOpen,
    required this.placement,
    required this.themeVariants,
    required this.material3,
  });

  final PinPointController controller;
  final ValueNotifier<bool> panelOpen;
  final RailPlacement placement;
  final List<String> themeVariants;
  final bool material3;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: panelOpen,
      builder: (context, open, _) {
        if (!open || !controller.isActive) return const SizedBox.shrink();
        return BesideRail(
          placement: placement,
          child: EnvironmentPanel(
            environment: controller.environment,
            themeVariants: themeVariants,
            material3: material3,
            onClose: () => panelOpen.value = false,
          ),
        );
      },
    );
  }
}
