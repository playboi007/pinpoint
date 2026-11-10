import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/pinpoint_controller.dart';
import '../env/device_presets.dart';
import '../env/environment_controller.dart';
import '../info/widget_info.dart' show formatColor;
import 'panel_keys.dart';

/// A seed color's option value in the panel: its hex without `#`.
String formatSeed(Color color) => formatColor(color).substring(1);

/// The what-if bar, bottom-left: a button that opens [EnvironmentPanel],
/// and while any override is active, what is overridden and a reset.
///
/// It shows while a mode is active, and in idle too while an override is
/// active: the app looks different from the real thing, and the bar says
/// so.
class EnvironmentBar extends StatelessWidget {
  const EnvironmentBar({
    super.key,
    required this.controller,
    required this.panelOpen,
  });

  static const Key barKey = ValueKey<String>('pinpoint.env.bar');
  static const Key toggleKey = ValueKey<String>('pinpoint.env.toggle');
  static const Key resetKey = ValueKey<String>('pinpoint.env.reset');

  final PinPointController controller;

  /// Whether the panel is open. The bar toggles it.
  final ValueNotifier<bool> panelOpen;

  void _toggle() {
    if (!controller.isActive) {
      // The panel lives with the active modes, behind the pointer trap.
      controller.startPicking();
      panelOpen.value = true;
      return;
    }
    panelOpen.value = !panelOpen.value;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.environment,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final environment = controller.environment;
    if (!controller.isActive && !environment.isActive) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final active = environment.isActive;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            key: barKey,
            elevation: 4,
            color: active ? colors.tertiaryContainer : colors.surface,
            borderRadius: BorderRadius.circular(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, minHeight: 44),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: TextButton.icon(
                      key: toggleKey,
                      onPressed: _toggle,
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(
                        active
                            ? 'What-if: ${environment.value.summary}'
                            : 'What-if',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (active)
                    IconButton(
                      key: resetKey,
                      tooltip: 'Reset every what-if switch',
                      onPressed: environment.reset,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
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

  static const double width = 320;

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

  static String _number(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toString();

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
    final theme = Theme.of(context);
    final env = _env.value;
    return PanelKeyScope(
      child: Material(
        key: EnvironmentPanel.panelKey,
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: EnvironmentPanel.width,
          child: Column(
            children: [
              _header(theme),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
                          for (final step in textScaleSteps)
                            _number(step): step,
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
                            keyboardHeight: () =>
                                on ? fakeKeyboardHeight : null,
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
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          key: EnvironmentPanel.resetAllKey,
                          onPressed: env.isEmpty ? null : _env.reset,
                          icon: const Icon(Icons.restart_alt, size: 18),
                          label: const Text('Reset all'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
    child: Row(
      children: [
        Expanded(child: Text('What-if', style: theme.textTheme.titleMedium)),
        IconButton(
          key: EnvironmentPanel.closeKey,
          tooltip: 'Close',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close, size: 18),
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
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text('×'),
            ),
            Expanded(
              child: _field(
                EnvironmentPanel.heightKey,
                _height,
                'Height',
                _applySize,
              ),
            ),
            IconButton(
              key: EnvironmentPanel.rotateKey,
              tooltip: 'Rotate',
              onPressed: size == null ? null : _env.rotate,
              icon: const Icon(Icons.screen_rotation, size: 18),
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
              ChoiceChip(
                key: EnvironmentPanel.option('seed', formatSeed(color)),
                tooltip: formatColor(color),
                selected: env.seedColor == color,
                onSelected: enabled
                    ? (_) => _set((e) => e.copyWith(seedColor: () => color))
                    : null,
                label: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 16),
                ),
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
  ) => ChoiceChip(
    key: EnvironmentPanel.option(section, value),
    label: Text(label),
    selected: selected,
    visualDensity: VisualDensity.compact,
    onSelected: onSelected == null ? null : (_) => onSelected(),
  );

  Widget _switch(
    String title,
    String section,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        Switch(
          key: EnvironmentPanel.option(section, 'switch'),
          value: value,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Widget _field(
    Key key,
    TextEditingController controller,
    String label,
    VoidCallback onSubmit,
  ) => TextField(
    key: key,
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    textInputAction: TextInputAction.done,
    decoration: InputDecoration(labelText: label, isDense: true),
    onSubmitted: (_) => onSubmit(),
  );

  Widget _section(String title, List<Widget> children, {String? note}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          ...children,
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(note, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// Places [EnvironmentPanel] on the left while it is open and a mode is
/// active. Only the panel takes pointer events.
class EnvironmentPanelLayer extends StatelessWidget {
  const EnvironmentPanelLayer({
    super.key,
    required this.controller,
    required this.panelOpen,
    required this.themeVariants,
    required this.material3,
  });

  final PinPointController controller;
  final ValueNotifier<bool> panelOpen;
  final List<String> themeVariants;
  final bool material3;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: panelOpen,
      builder: (context, open, _) {
        if (!open || !controller.isActive) return const SizedBox.shrink();
        return SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              // Above the bar, which sits bottom-left.
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              child: EnvironmentPanel(
                environment: controller.environment,
                themeVariants: themeVariants,
                material3: material3,
                onClose: () => panelOpen.value = false,
              ),
            ),
          ),
        );
      },
    );
  }
}
