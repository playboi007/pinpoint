import 'package:flutter/material.dart';

/// The three palettes of the "Drafting" design. Same structure, different
/// colours. The user picks one in the rail's theme menu.
enum PinPointPalette {
  /// White paper, red accent. Selection and edits are both red.
  redline('Redline'),

  /// Warm grey paper, blue selection, green edits.
  cobalt('Cobalt'),

  /// Amber paper, orange-red accent.
  ember('Ember');

  const PinPointPalette(this.label);

  /// The name shown in the theme menu.
  final String label;

  /// The colours of this palette.
  PinPointTokens get tokens => switch (this) {
    PinPointPalette.redline => PinPointTokens.redline,
    PinPointPalette.cobalt => PinPointTokens.cobalt,
    PinPointPalette.ember => PinPointTokens.ember,
  };

  /// The palette called [name] (`redline`, `cobalt` or `ember`), or null for
  /// anything else, including null. Used to read the saved pick.
  static PinPointPalette? parse(String? name) {
    for (final palette in values) {
      if (palette.name == name) return palette;
    }
    return null;
  }
}

/// Every colour of the Drafting design, plus its type styles and elevation.
///
/// Pinpoint's own [Theme] carries one instance as a [ThemeExtension]. A
/// widget reads it with [PinPointTokens.of]; it never reads the host app's
/// theme. Switching the palette swaps the instance and rebuilds only
/// Pinpoint's overlay.
///
/// Roboto and Roboto Mono styles have their colour baked in. Call
/// `copyWith(color: ...)` on the result to change it.
@immutable
class PinPointTokens extends ThemeExtension<PinPointTokens> {
  const PinPointTokens({
    required this.paper,
    required this.input,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.rule,
    required this.field,
    required this.accent,
    required this.accentBg,
    required this.accentInk,
    required this.onAccent,
    required this.edit,
    required this.editBg,
    required this.editInk,
    required this.halo,
    required this.shadow,
    required this.ok,
    required this.err,
    required this.errBg,
    required this.warn,
    required this.warnBg,
    required this.info,
    required this.infoBg,
  });

  /// Panel, rail and label background. Also the halo of every canvas stroke.
  final Color paper;

  /// Field fill.
  final Color input;

  /// Text, borders, hover outline and rulers.
  final Color ink;

  /// Labels and secondary text.
  final Color muted;

  /// Disabled text and hints.
  final Color faint;

  /// Dividers inside panels.
  final Color rule;

  /// Field and chip border at rest.
  final Color field;

  /// The selected outline, the focused pin, Send.
  final Color accent;

  /// Focus ring and the active rail item.
  final Color accentBg;

  /// Text on [accentBg].
  final Color accentInk;

  /// Text on an [accent] fill. White in every palette.
  final Color onAccent;

  /// Tweaked values, the dotted outline of a tweaked widget, the "modified"
  /// mark.
  final Color edit;

  /// Fill of a tweaked field.
  final Color editBg;

  /// Text of a tweaked field.
  final Color editInk;

  /// The outer 1 px ring of an elevated surface. Slightly see-through.
  final Color halo;

  /// The hard offset shadow of an elevated surface.
  final Color shadow;

  /// A fixed tick, a passed check, a success toast.
  final Color ok;

  /// Errors, a failed check, an invalid field.
  final Color err;

  /// Fill behind [err].
  final Color errBg;

  /// Overflow and truncation findings.
  final Color warn;

  /// Fill behind [warn].
  final Color warnBg;

  /// Accessibility hints.
  final Color info;

  /// Fill behind [info].
  final Color infoBg;

  /// White paper, red accent.
  static const PinPointTokens redline = PinPointTokens(
    paper: Color(0xFFFFFFFF),
    input: Color(0xFFFAFAFA),
    ink: Color(0xFF111111),
    muted: Color(0xFF555555),
    faint: Color(0xFF8C8C8C),
    rule: Color(0xFFE2E2E2),
    field: Color(0xFFC4C4C4),
    accent: Color(0xFFE1140A),
    accentBg: Color(0xFFFFEDEB),
    accentInk: Color(0xFFB30E06),
    onAccent: Color(0xFFFFFFFF),
    edit: Color(0xFFE1140A),
    editBg: Color(0xFFFFEDEB),
    editInk: Color(0xFFB30E06),
    halo: Color(0xEBFFFFFF), // rgba(255,255,255,.92)
    shadow: Color(0xFFE1140A),
    ok: Color(0xFF1E7B3A),
    err: Color(0xFFA3001B),
    errBg: Color(0xFFFBE6E9),
    warn: Color(0xFFA35F00),
    warnBg: Color(0xFFFFF1DB),
    info: Color(0xFF2050D8),
    infoBg: Color(0xFFE7EDFF),
  );

  /// Warm grey paper, blue selection, green edits.
  static const PinPointTokens cobalt = PinPointTokens(
    paper: Color(0xFFF1EFE8),
    input: Color(0xFFFBFAF6),
    ink: Color(0xFF23262D),
    muted: Color(0xFF5C5F66),
    faint: Color(0xFF8B8D92),
    rule: Color(0xFFD6D3CA),
    field: Color(0xFFB9B6AD),
    accent: Color(0xFF1F5BFF),
    accentBg: Color(0xFFE6ECFF),
    accentInk: Color(0xFF0B3FD1),
    onAccent: Color(0xFFFFFFFF),
    edit: Color(0xFF0E8A4F),
    editBg: Color(0xFFE3F3EA),
    editInk: Color(0xFF0A6E3F),
    halo: Color(0xE6F1EFE8), // rgba(241,239,232,.90)
    shadow: Color(0xD923262D), // rgba(35,38,45,.85)
    ok: Color(0xFF0E8A4F),
    err: Color(0xFFC8261B),
    errBg: Color(0xFFFBE5E2),
    warn: Color(0xFF9A5B00),
    warnBg: Color(0xFFFBEFD8),
    info: Color(0xFF1F5BFF),
    infoBg: Color(0xFFE6ECFF),
  );

  /// Amber paper, orange-red accent.
  static const PinPointTokens ember = PinPointTokens(
    paper: Color(0xFFFFDD9C),
    input: Color(0xFFFFF0CC),
    ink: Color(0xFF2A1408),
    muted: Color(0xFF6B3A14),
    faint: Color(0xFF8F5A26),
    rule: Color(0xFFF9B637),
    field: Color(0xFFD9962A),
    accent: Color(0xFFE73F1E),
    accentBg: Color(0xFFFFEFD0),
    accentInk: Color(0xFFB82D10),
    onAccent: Color(0xFFFFFFFF),
    edit: Color(0xFFE73F1E),
    editBg: Color(0xFFFFEFD0),
    editInk: Color(0xFFB82D10),
    halo: Color(0xEBFFDD9C), // rgba(255,221,156,.92)
    shadow: Color(0xFFFB6C00),
    ok: Color(0xFF2F6B1F),
    err: Color(0xFF9E1408),
    errBg: Color(0xFFFFD0B8),
    warn: Color(0xFF7A4300),
    warnBg: Color(0xFFFFE9B8),
    info: Color(0xFF1F4FB8),
    infoBg: Color(0xFFFFF0CC),
  );

  /// The tokens of the nearest Pinpoint theme. Outside one (a widget test
  /// without [pinPointThemeData]) this is [redline].
  static PinPointTokens of(BuildContext context) =>
      Theme.of(context).extension<PinPointTokens>() ?? redline;

  // Typography. Fixed sizes: Pinpoint ignores the system text scale.

  static const FontFeature _tabular = FontFeature.tabularFigures();

  TextStyle _roboto(double size, double line, FontWeight weight, Color color) =>
      TextStyle(
        fontFamily: 'Roboto',
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        color: color,
        fontFeatures: const [_tabular],
      );

  TextStyle _mono(
    double size,
    double line,
    FontWeight weight,
    Color color, {
    double? letterSpacing,
  }) => TextStyle(
    fontFamily: 'RobotoMono',
    package: 'pinpoint',
    fontSize: size,
    height: line / size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
  );

  /// Roboto 13/16 bold, [ink]. Panel header widget name.
  TextStyle get title => _roboto(13, 16, FontWeight.w700, ink);

  /// Roboto 12/16, [ink]. Comment text, rows, menus, buttons.
  TextStyle get body => _roboto(12, 16, FontWeight.w400, ink);

  /// Roboto 12/16, [muted]. Property names.
  TextStyle get label => _roboto(12, 16, FontWeight.w400, muted);

  /// Roboto Mono 12/16, [ink]. Numbers, hex, enums, paths.
  TextStyle get value => _mono(12, 16, FontWeight.w400, ink);

  /// Roboto Mono 10/12 medium, letter spacing 0.8, [muted]. Section headers
  /// ("02 PADDING"), tab labels, badges.
  TextStyle get caps =>
      _mono(10, 12, FontWeight.w500, muted, letterSpacing: 0.8);

  /// Roboto Mono 10/14 medium, [muted]. Ruler labels, counts, "1/87".
  TextStyle get micro => _mono(10, 14, FontWeight.w500, muted);

  // Elevation. A hard shadow: `blurRadius` stays 0 everywhere.

  /// Labels and chips on the canvas: a 1 px [halo] ring around the 1 px ink
  /// border that [surface] draws.
  List<BoxShadow> get e1 => [BoxShadow(spreadRadius: 1, color: halo)];

  /// Rail, toasts, menus: [e1] plus a 3 px hard [shadow].
  List<BoxShadow> get e2 => [
    ...e1,
    BoxShadow(offset: const Offset(3, 3), color: shadow),
  ];

  /// Panels: [e1] plus a 4 px hard [shadow].
  List<BoxShadow> get e3 => [
    ...e1,
    BoxShadow(offset: const Offset(4, 4), color: shadow),
  ];

  /// A [paper] box with a 1 px [ink] border, no radius, and the shadows of
  /// elevation [level] (1, 2 or 3).
  BoxDecoration surface(int level) {
    assert(level >= 1 && level <= 3, 'elevation is 1, 2 or 3');
    return BoxDecoration(
      color: paper,
      border: Border.all(color: ink),
      boxShadow: switch (level) {
        1 => e1,
        2 => e2,
        _ => e3,
      },
    );
  }

  @override
  PinPointTokens copyWith({
    Color? paper,
    Color? input,
    Color? ink,
    Color? muted,
    Color? faint,
    Color? rule,
    Color? field,
    Color? accent,
    Color? accentBg,
    Color? accentInk,
    Color? onAccent,
    Color? edit,
    Color? editBg,
    Color? editInk,
    Color? halo,
    Color? shadow,
    Color? ok,
    Color? err,
    Color? errBg,
    Color? warn,
    Color? warnBg,
    Color? info,
    Color? infoBg,
  }) => PinPointTokens(
    paper: paper ?? this.paper,
    input: input ?? this.input,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    rule: rule ?? this.rule,
    field: field ?? this.field,
    accent: accent ?? this.accent,
    accentBg: accentBg ?? this.accentBg,
    accentInk: accentInk ?? this.accentInk,
    onAccent: onAccent ?? this.onAccent,
    edit: edit ?? this.edit,
    editBg: editBg ?? this.editBg,
    editInk: editInk ?? this.editInk,
    halo: halo ?? this.halo,
    shadow: shadow ?? this.shadow,
    ok: ok ?? this.ok,
    err: err ?? this.err,
    errBg: errBg ?? this.errBg,
    warn: warn ?? this.warn,
    warnBg: warnBg ?? this.warnBg,
    info: info ?? this.info,
    infoBg: infoBg ?? this.infoBg,
  );

  /// Snaps: a palette switch is instant, so there is nothing to blend.
  @override
  PinPointTokens lerp(ThemeExtension<PinPointTokens>? other, double t) {
    if (other is! PinPointTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// Sizes of the Drafting design, in logical pixels.
abstract final class PinPointSizes {
  /// Inner padding of a panel body.
  static const double panelPadding = 12;

  /// Gap between two sections of a panel.
  static const double sectionGap = 14;

  /// Height of a field, stepper or chip.
  static const double controlHeight = 24;

  /// Height of a list row.
  static const double rowHeight = 28;

  /// Height of a panel header.
  static const double panelHeader = 40;

  /// Height of the tab bar.
  static const double tabBar = 30;

  /// Height of the breadcrumb.
  static const double breadcrumb = 26;

  /// Height of the Tweak panel's footer.
  static const double footer = 34;

  /// Height of the Comment panel's footer.
  static const double footerTall = 40;

  /// Width of the rail.
  static const double railWidth = 40;

  /// Width and height of a rail item.
  static const double railItem = 40;

  /// Width and height of the launcher at the foot of the rail.
  static const double launcher = 44;

  /// Gap between the rail and the right edge of the screen.
  static const double railInset = 8;

  /// Width and height of a pin.
  static const double pin = 22;

  /// Width of a panel, before it is clamped to the viewport.
  static const double panelWidth = 360;

  /// Height of a toast.
  static const double toastHeight = 40;

  /// Widest a toast gets.
  static const double toastMaxWidth = 340;
}

/// Icons of the Drafting design. The design uses Material Symbols Outlined;
/// these are the Material Icons equivalents, which ship with Flutter.
abstract final class PinPointIcons {
  static const IconData dragIndicator = Icons.drag_indicator;
  static const IconData unfoldMore = Icons.unfold_more;
  static const IconData close = Icons.close;
  static const IconData restartAlt = Icons.restart_alt;
  static const IconData linkOff = Icons.link_off;
  static const IconData link = Icons.link;
  static const IconData expandMore = Icons.expand_more;
  static const IconData lock = Icons.lock;
  static const IconData add = Icons.add;
  static const IconData tune = Icons.tune;
  static const IconData warning = Icons.warning;
  static const IconData smartToy = Icons.smart_toy;
  static const IconData palette = Icons.palette;

  /// The launcher. Symbols has `point_scan` (corner brackets around a dot),
  /// which Material Icons lacks; `filter_center_focus` is the same shape.
  static const IconData launcher = Icons.filter_center_focus;
  static const IconData check = Icons.check;
  static const IconData moreHoriz = Icons.more_horiz;
  static const IconData doneAll = Icons.done_all;
  static const IconData bugReport = Icons.bug_report;
  static const IconData help = Icons.help;
  static const IconData contentCopy = Icons.content_copy;
  static const IconData checkCircle = Icons.check_circle;
  static const IconData error = Icons.error;
  static const IconData info = Icons.info;
  static const IconData acUnit = Icons.ac_unit;

  /// The Improve intent chip. The design names no icon for it.
  static const IconData improve = Icons.auto_fix_high;
}
