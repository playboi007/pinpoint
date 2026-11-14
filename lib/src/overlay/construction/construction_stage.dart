import 'dart:ui' show Color, Rect;

import 'package:flutter/foundation.dart';

import '../../theme/pinpoint_tokens.dart';
import 'construction_stage_stub.dart'
    if (dart.library.js_interop) 'construction_stage_web.dart'
    as platform;

/// The colours of the drafting design, as CSS, for the site's custom
/// properties. Switching palette gives the stage a new one.
@immutable
class ConstructionColors {
  const ConstructionColors({
    required this.paper,
    required this.ink,
    required this.accent,
    required this.rule,
    required this.shadow,
    required this.hatch,
  });

  /// The colours of [tokens].
  factory ConstructionColors.of(PinPointTokens tokens) => ConstructionColors(
    paper: css(tokens.paper),
    ink: css(tokens.ink),
    accent: css(tokens.accent),
    rule: css(tokens.rule),
    shadow: css(tokens.shadow),
    hatch: css(tokens.ink.withValues(alpha: 0.22)),
  );

  /// [color] as a CSS `rgba()`.
  static String css(Color color) {
    int channel(double v) => (v * 255).round().clamp(0, 255);
    final a = color.a;
    final alpha = a == 1 ? '1' : a.toStringAsFixed(3);
    return 'rgba(${channel(color.r)},${channel(color.g)},${channel(color.b)},'
        '$alpha)';
  }

  final String paper;
  final String ink;
  final String accent;
  final String rule;
  final String shadow;

  /// The ink of the cover's hatching.
  final String hatch;

  @override
  bool operator ==(Object other) =>
      other is ConstructionColors &&
      other.paper == paper &&
      other.ink == ink &&
      other.accent == accent &&
      other.rule == rule &&
      other.shadow == shadow &&
      other.hatch == hatch;

  @override
  int get hashCode => Object.hash(paper, ink, accent, rule, shadow, hatch);
}

/// What draws the "construction site" over a widget the agent is working on.
///
/// On web it is HTML and CSS in the page, over the Flutter canvas, moved by
/// CSS keyframes only: a Flutter animation would draw frames, and the agent's
/// commands wait for the app to stop drawing. The agent's screenshots come
/// from Flutter layers, so nothing here ever shows in them. Elsewhere the
/// stage does nothing.
///
/// Rects are in the Flutter view's logical pixels. Every call is cheap and
/// draws no Flutter frame.
abstract interface class ConstructionStage {
  /// Whether this platform draws sites. When false, nothing else is called.
  bool get available;

  /// Switches the colours.
  void setColors(ConstructionColors colors);

  /// Whether motion is reduced: the site shows still.
  void setReducedMotion(bool reduced);

  /// Puts up the site [id] over [rect].
  void add(String id, Rect rect);

  /// Moves the site [id] to [rect].
  void move(String id, Rect rect);

  /// Plays the finish of the site [id]: the workers leave, the cover comes
  /// off and, with [png] (a picture of the widget as it is now), the widget
  /// pops in. The controller removes the site when it is done.
  void reveal(String id, Uint8List? png);

  /// Takes the site [id] away: it fades, or with [fade] false goes at once.
  void remove(String id, {bool fade = true});

  /// Takes every site and the page's root element away.
  void dispose();
}

/// Replaces the platform's stage in tests.
@visibleForTesting
ConstructionStage Function()? debugConstructionStage;

/// The stage of this platform.
ConstructionStage constructionStage() =>
    debugConstructionStage?.call() ?? platform.createConstructionStage();
