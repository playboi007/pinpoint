import 'package:flutter/material.dart';

import 'pinpoint_tokens.dart';

final Map<PinPointPalette, ThemeData> _themes = <PinPointPalette, ThemeData>{};

const _square = RoundedRectangleBorder();
const _clear = Color(0x00000000);

/// The [ThemeData] of Pinpoint's overlay for [palette].
///
/// It carries the palette's [PinPointTokens] as an extension, and maps
/// Material's own widgets (text fields, menus, tooltips, checkboxes,
/// scrollbars) onto the Drafting look, so a stray Material widget in a panel
/// does not look foreign. One instance per palette, built on first use, so
/// switching palettes does not rebuild a theme and `Theme` sees the same
/// object each time.
ThemeData pinPointThemeData(PinPointPalette palette) =>
    _themes.putIfAbsent(palette, () => _build(palette.tokens));

ThemeData _build(PinPointTokens t) {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: _colorScheme(t),
    extensions: <ThemeExtension<dynamic>>[t],
    fontFamily: 'Roboto',
    textTheme: _textTheme(t),
    canvasColor: t.paper,
    splashFactory: NoSplash.splashFactory,
    splashColor: _clear,
    highlightColor: _clear,
    hoverColor: t.accentBg,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    iconTheme: IconThemeData(color: t.ink, size: 18),
    dividerTheme: DividerThemeData(color: t.rule, thickness: 1, space: 1),
    textSelectionTheme: _selectionTheme(t),
    tooltipTheme: _tooltipTheme(t),
    menuTheme: _menuTheme(t),
    menuButtonTheme: _menuButtonTheme(t),
    popupMenuTheme: _popupMenuTheme(t),
    inputDecorationTheme: _inputTheme(t),
    checkboxTheme: _checkboxTheme(t),
    scrollbarTheme: _scrollbarTheme(t),
  );
}

ColorScheme _colorScheme(PinPointTokens t) => ColorScheme(
  brightness: Brightness.light,
  primary: t.accent,
  onPrimary: t.onAccent,
  primaryContainer: t.accentBg,
  onPrimaryContainer: t.accentInk,
  secondary: t.ink,
  onSecondary: t.paper,
  secondaryContainer: t.rule,
  onSecondaryContainer: t.ink,
  tertiary: t.edit,
  onTertiary: t.onAccent,
  tertiaryContainer: t.editBg,
  onTertiaryContainer: t.editInk,
  error: t.err,
  onError: t.onAccent,
  errorContainer: t.errBg,
  onErrorContainer: t.err,
  surface: t.paper,
  onSurface: t.ink,
  onSurfaceVariant: t.muted,
  surfaceTint: _clear,
  surfaceContainerLowest: t.paper,
  surfaceContainerLow: t.paper,
  surfaceContainer: t.paper,
  surfaceContainerHigh: t.paper,
  surfaceContainerHighest: t.input,
  outline: t.field,
  outlineVariant: t.rule,
  shadow: _clear,
  scrim: t.ink,
  inverseSurface: t.ink,
  onInverseSurface: t.paper,
  inversePrimary: t.accentBg,
);

/// Every slot gets a Drafting size, so a stray Material default is 12/16.
TextTheme _textTheme(PinPointTokens t) => TextTheme(
  displayLarge: t.title,
  displayMedium: t.title,
  displaySmall: t.title,
  headlineLarge: t.title,
  headlineMedium: t.title,
  headlineSmall: t.title,
  titleLarge: t.title,
  titleMedium: t.title,
  titleSmall: t.title,
  bodyLarge: t.body,
  bodyMedium: t.body,
  bodySmall: t.body,
  labelLarge: t.body,
  labelMedium: t.body,
  labelSmall: t.caps,
);

TextSelectionThemeData _selectionTheme(PinPointTokens t) =>
    TextSelectionThemeData(
      cursorColor: t.accent,
      selectionColor: t.accentBg,
      selectionHandleColor: t.accent,
    );

TooltipThemeData _tooltipTheme(PinPointTokens t) => TooltipThemeData(
  decoration: BoxDecoration(color: t.ink),
  textStyle: t.body.copyWith(fontSize: 11, height: 14 / 11, color: t.paper),
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
  waitDuration: const Duration(milliseconds: 500),
);

MenuThemeData _menuTheme(PinPointTokens t) => MenuThemeData(
  style: MenuStyle(
    backgroundColor: WidgetStatePropertyAll<Color>(t.paper),
    surfaceTintColor: const WidgetStatePropertyAll<Color>(_clear),
    shadowColor: const WidgetStatePropertyAll<Color>(_clear),
    elevation: const WidgetStatePropertyAll<double>(0),
    side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: t.ink)),
    shape: const WidgetStatePropertyAll<OutlinedBorder>(_square),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
  ),
);

MenuButtonThemeData _menuButtonTheme(PinPointTokens t) => MenuButtonThemeData(
  style: ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 30)),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(horizontal: 10),
    ),
    textStyle: WidgetStatePropertyAll<TextStyle>(t.body),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? t.faint : t.ink,
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)
          ? t.accentBg
          : t.paper,
    ),
    overlayColor: const WidgetStatePropertyAll<Color>(_clear),
    shape: const WidgetStatePropertyAll<OutlinedBorder>(_square),
  ),
);

PopupMenuThemeData _popupMenuTheme(PinPointTokens t) => PopupMenuThemeData(
  color: t.paper,
  surfaceTintColor: _clear,
  shadowColor: _clear,
  elevation: 0,
  shape: RoundedRectangleBorder(side: BorderSide(color: t.ink)),
  textStyle: t.body,
);

InputDecorationThemeData _inputTheme(PinPointTokens t) =>
    InputDecorationThemeData(
      isDense: true,
      filled: true,
      fillColor: t.input,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      hintStyle: t.body.copyWith(color: t.faint),
      labelStyle: t.label,
      helperStyle: t.body.copyWith(fontSize: 11, color: t.muted),
      errorStyle: t.body.copyWith(fontSize: 11, color: t.err),
      border: _outline(t.field, 1),
      enabledBorder: _outline(t.field, 1),
      disabledBorder: _outline(t.field, 1),
      focusedBorder: _outline(t.ink, 1.5),
      errorBorder: _outline(t.err, 1.5),
      focusedErrorBorder: _outline(t.err, 1.5),
    );

CheckboxThemeData _checkboxTheme(PinPointTokens t) => CheckboxThemeData(
  shape: _square,
  side: BorderSide(color: t.ink, width: 1.5),
  fillColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.selected) ? t.ink : t.input,
  ),
  checkColor: WidgetStatePropertyAll<Color>(t.paper),
  overlayColor: const WidgetStatePropertyAll<Color>(_clear),
  visualDensity: VisualDensity.compact,
  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

ScrollbarThemeData _scrollbarTheme(PinPointTokens t) => ScrollbarThemeData(
  thickness: const WidgetStatePropertyAll<double>(6),
  radius: Radius.zero,
  thumbColor: WidgetStatePropertyAll<Color>(t.ink),
  minThumbLength: 24,
);

InputBorder _outline(Color color, double width) => OutlineInputBorder(
  borderRadius: BorderRadius.zero,
  borderSide: BorderSide(color: color, width: width),
);
