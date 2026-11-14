import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../../model/annotation.dart';
import '../../theme/pinpoint_tokens.dart';
import '../pin_tracker.dart';
import 'construction_layout.dart';
import 'construction_markup.dart';
import 'construction_stage.dart';

/// Takes one PNG of [rect] (global logical pixels), or null.
typedef RegionCapture = Future<Uint8List?> Function(Rect rect);

/// Puts a "construction site" over each widget the agent works on.
///
/// While a note is `inProgress`, its widget is covered: hatching, tape that
/// reads "UNDER PROGRESS", and small workers at work. When the note becomes
/// `fixed` the workers finish, the cover comes off and the new widget pops
/// in. For any other change (back to submitted, deleted, resolved, the
/// widget gone) the site fades away.
///
/// It follows the pins' placements, which update on the app's own frames,
/// and a status change. It draws nothing in Flutter and starts no animation,
/// ticker or timer loop: the [ConstructionStage] moves everything by CSS
/// keyframes. The agent's commands wait for the app to stop drawing, and a
/// frame is also a trace event (engineering rule 2). The agent's screenshots
/// come from Flutter layers, so none of this ever shows in them.
class ConstructionSites {
  ConstructionSites({
    required this.stage,
    required this.capture,
    this.captureTimeout = const Duration(seconds: 5),
  });

  /// What draws the sites.
  final ConstructionStage stage;

  /// One picture of the widget, taken once the note is `fixed`.
  final RegionCapture capture;

  /// The longest wait for [capture]; then the site goes without the bounce.
  final Duration captureTimeout;

  /// The length of the finish.
  static const Duration revealDuration = Duration(
    milliseconds: ConstructionMarkup.revealMillis,
  );

  final Map<String, _Site> _sites = <String, _Site>{};
  ValueListenable<List<PinPlacement>>? _placements;
  ValueListenable<PinPointPalette>? _palette;
  bool _reduced = false;
  bool _disposed = false;

  /// Ids of the sites on screen, in the order they went up.
  @visibleForTesting
  List<String> get siteIds => _sites.keys.toList();

  /// Follows [placements] and [palette], and forgets the ones before. Call
  /// it again when the overlay's tracker or controller changes.
  void follow({
    required ValueListenable<List<PinPlacement>> placements,
    required ValueListenable<PinPointPalette> palette,
  }) {
    if (_disposed || !stage.available) return;
    _placements?.removeListener(_sync);
    _palette?.removeListener(_colors);
    _placements = placements..addListener(_sync);
    _palette = palette..addListener(_colors);
    _colors();
    stage.setReducedMotion(_reduced);
    _sync();
  }

  /// Whether the system asks for reduced motion: sites show still and go
  /// at once.
  set reduced(bool value) {
    if (value == _reduced) return;
    _reduced = value;
    if (!_disposed && stage.available) stage.setReducedMotion(value);
  }

  bool get reduced => _reduced;

  void _colors() {
    final palette = _palette;
    if (palette == null) return;
    stage.setColors(ConstructionColors.of(palette.value.tokens));
  }

  void _sync() {
    if (_disposed) return;
    final placements = _placements?.value ?? const <PinPlacement>[];
    final byId = {for (final p in placements) p.id: p};

    // Sites whose note is no longer being worked on.
    for (final id in _sites.keys.toList()) {
      final site = _sites[id]!;
      final placement = byId[id];
      final working =
          placement != null &&
          !placement.accepted &&
          placement.status == NoteStatus.inProgress;
      if (working) continue;
      switch (site.phase) {
        case _Phase.working:
          if (placement != null &&
              !placement.accepted &&
              placement.status == NoteStatus.fixed) {
            _lift(id, site);
          } else {
            _drop(id);
          }
        case _Phase.capturing:
          // Changed again while the picture was taken.
          if (placement == null ||
              placement.accepted ||
              placement.status != NoteStatus.fixed) {
            _drop(id);
          }
        case _Phase.revealing:
          break;
      }
    }

    // Sites for notes being worked on, up to the limit.
    for (final placement in placements) {
      if (placement.accepted || placement.status != NoteStatus.inProgress) {
        continue;
      }
      final site = _sites[placement.id];
      if (site != null && site.phase == _Phase.working) {
        if (site.rect != placement.rect) {
          site.rect = placement.rect;
          stage.move(placement.id, placement.rect);
        }
        continue;
      }
      // Back in progress while an old finish still plays: it ends now.
      if (site != null) _drop(placement.id, fade: false);
      if (_sites.length >= ConstructionLayout.maxSites) continue;
      _sites[placement.id] = _Site(placement.rect);
      stage.add(placement.id, placement.rect);
    }
  }

  /// The note became `fixed`: take one picture of the widget, then play the
  /// finish.
  void _lift(String id, _Site site) {
    if (_reduced) {
      _drop(id, fade: false);
      return;
    }
    site.phase = _Phase.capturing;
    unawaited(_reveal(id, site));
  }

  Future<void> _reveal(String id, _Site site) async {
    Uint8List? png;
    try {
      png = await capture(site.rect).timeout(captureTimeout);
    } catch (_) {
      // No picture: the cover comes off without the bounce.
    }
    if (_disposed || _sites[id] != site || site.phase != _Phase.capturing) {
      return;
    }
    site.phase = _Phase.revealing;
    stage.reveal(id, png);
    site.timer = Timer(revealDuration, () {
      if (_disposed || _sites[id] != site) return;
      _drop(id, fade: false);
      // A note that waited for a free place goes up now.
      _sync();
    });
  }

  void _drop(String id, {bool fade = true}) {
    final site = _sites.remove(id);
    if (site == null) return;
    site.timer?.cancel();
    stage.remove(id, fade: fade);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _placements?.removeListener(_sync);
    _palette?.removeListener(_colors);
    for (final site in _sites.values) {
      site.timer?.cancel();
    }
    _sites.clear();
    stage.dispose();
  }
}

enum _Phase { working, capturing, revealing }

class _Site {
  _Site(this.rect);

  Rect rect;
  _Phase phase = _Phase.working;
  Timer? timer;
}
