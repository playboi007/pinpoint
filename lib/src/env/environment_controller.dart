import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../info/widget_info.dart' show formatColor;
import 'device_presets.dart';

/// What the app inherits instead of the real values: the what-if
/// switches.
///
/// Every field is nullable; null means "not overridden".
@immutable
class Environment {
  const Environment({
    this.viewport,
    this.textScale,
    this.boldText,
    this.safeArea,
    this.keyboardHeight,
    this.textDirection,
    this.brightness,
    this.themeVariant,
    this.seedColor,
    this.platform,
    this.timeDilation,
  }) : assert(timeDilation == null || timeDilation > 0),
       assert(textScale == null || textScale > 0),
       assert(keyboardHeight == null || keyboardHeight >= 0);

  /// Nothing overridden.
  static const Environment none = Environment();

  /// The app's size in logical pixels: `MediaQuery.size` and the
  /// constraints the app gets.
  final Size? viewport;

  /// `MediaQuery.textScaler` becomes `TextScaler.linear(textScale)`.
  final double? textScale;

  /// `MediaQuery.boldText`.
  final bool? boldText;

  /// `MediaQuery.padding` and `viewPadding`.
  final EdgeInsets? safeArea;

  /// A fake on-screen keyboard this high: `MediaQuery.viewInsets.bottom`.
  final double? keyboardHeight;

  /// The `Directionality` the app gets. Strings stay in the current
  /// locale.
  final TextDirection? textDirection;

  /// The app's own light or dark theme (`MaterialApp.theme` or
  /// `darkTheme`).
  final Brightness? brightness;

  /// The name of one of `PinPointConfig.themeVariants`. Wins over
  /// [brightness].
  final String? themeVariant;

  /// A Material 3 color scheme made from this seed.
  final Color? seedColor;

  /// `debugDefaultTargetPlatformOverride`. Debug builds only.
  final TargetPlatform? platform;

  /// `timeDilation`: 5 makes every animation five times slower.
  final double? timeDilation;

  /// Whether nothing is overridden.
  bool get isEmpty => this == none;

  /// [viewport] with width and height swapped.
  Environment rotated() => viewport == null
      ? this
      : copyWith(viewport: () => Size(viewport!.height, viewport!.width));

  /// A copy. Pass a function to set a field, including to null:
  /// `copyWith(viewport: () => null)` clears the viewport.
  Environment copyWith({
    Size? Function()? viewport,
    double? Function()? textScale,
    bool? Function()? boldText,
    EdgeInsets? Function()? safeArea,
    double? Function()? keyboardHeight,
    TextDirection? Function()? textDirection,
    Brightness? Function()? brightness,
    String? Function()? themeVariant,
    Color? Function()? seedColor,
    TargetPlatform? Function()? platform,
    double? Function()? timeDilation,
  }) => Environment(
    viewport: viewport == null ? this.viewport : viewport(),
    textScale: textScale == null ? this.textScale : textScale(),
    boldText: boldText == null ? this.boldText : boldText(),
    safeArea: safeArea == null ? this.safeArea : safeArea(),
    keyboardHeight: keyboardHeight == null
        ? this.keyboardHeight
        : keyboardHeight(),
    textDirection: textDirection == null ? this.textDirection : textDirection(),
    brightness: brightness == null ? this.brightness : brightness(),
    themeVariant: themeVariant == null ? this.themeVariant : themeVariant(),
    seedColor: seedColor == null ? this.seedColor : seedColor(),
    platform: platform == null ? this.platform : platform(),
    timeDilation: timeDilation == null ? this.timeDilation : timeDilation(),
  );

  /// The overridden fields only, for the note. Empty when nothing is
  /// overridden.
  Map<String, Object?> toJson() => {
    if (viewport case final v?)
      'viewport': {'width': _num(v.width), 'height': _num(v.height)},
    if (textScale case final t?) 'textScale': _num(t),
    'boldText': ?boldText,
    if (safeArea case final s?)
      'safeArea': {
        'left': _num(s.left),
        'top': _num(s.top),
        'right': _num(s.right),
        'bottom': _num(s.bottom),
      },
    if (keyboardHeight case final k?) 'keyboardHeight': _num(k),
    if (textDirection case final d?) 'textDirection': d.name,
    if (brightness case final b?) 'brightness': b.name,
    'themeVariant': ?themeVariant,
    if (seedColor case final c?) 'seedColor': formatColor(c),
    if (platform case final p?) 'platform': p.name,
    if (timeDilation case final t?) 'timeDilation': _num(t),
  };

  /// A short line for the chip, for example `360 × 800 · text 1.5× · RTL`.
  String get summary => [
    if (viewport case final v?) sizeLabelOf(v),
    if (textScale case final t?) 'text ${_label(t)}×',
    if (boldText == true) 'bold',
    if (safeArea != null) 'safe area',
    if (keyboardHeight != null) 'keyboard',
    if (textDirection == TextDirection.rtl) 'RTL',
    if (textDirection == TextDirection.ltr) 'LTR',
    if (themeVariant case final t?) t else if (brightness case final b?) b.name,
    if (seedColor != null) 'seed ${formatColor(seedColor!)}',
    if (platform case final p?) p.name,
    if (timeDilation case final t?) 'slow ${_label(t)}×',
  ].join(' · ');

  static num _num(double value) =>
      value == value.truncateToDouble() && value.abs() < 1e15
      ? value.toInt()
      : value;

  static String _label(double value) => _num(value).toString();

  @override
  bool operator ==(Object other) =>
      other is Environment &&
      other.viewport == viewport &&
      other.textScale == textScale &&
      other.boldText == boldText &&
      other.safeArea == safeArea &&
      other.keyboardHeight == keyboardHeight &&
      other.textDirection == textDirection &&
      other.brightness == brightness &&
      other.themeVariant == themeVariant &&
      other.seedColor == seedColor &&
      other.platform == platform &&
      other.timeDilation == timeDilation;

  @override
  int get hashCode => Object.hash(
    viewport,
    textScale,
    boldText,
    safeArea,
    keyboardHeight,
    textDirection,
    brightness,
    themeVariant,
    seedColor,
    platform,
    timeDilation,
  );

  @override
  String toString() =>
      isEmpty ? 'Environment.none' : 'Environment(${toJson()})';
}

/// Holds the active [Environment] and notifies when it changes.
///
/// It only holds the value. `PinPointWrapper` applies it: the frame and
/// `EnvironmentHost` for what the app inherits, `HookRegistry` for the
/// two globals (platform and slow motion).
class EnvironmentController extends ChangeNotifier {
  Environment _value = Environment.none;

  /// The active overrides.
  Environment get value => _value;
  set value(Environment next) {
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  /// Whether any override is active.
  bool get isActive => !_value.isEmpty;

  /// Changes the active overrides with [change].
  void update(Environment Function(Environment current) change) =>
      value = change(_value);

  /// Sets the viewport. Null: the real window.
  void setViewport(Size? size) =>
      update((e) => e.copyWith(viewport: () => size));

  /// Swaps the viewport's width and height.
  void rotate() => update((e) => e.rotated());

  /// Removes every override.
  void reset() => value = Environment.none;

  /// The overridden fields only, for the note.
  Map<String, Object?> toJson() => _value.toJson();
}
