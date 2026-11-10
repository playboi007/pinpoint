import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../model/annotation.dart';
import 'pin_tracker.dart';

/// Covers the screen and draws a [PinMarker] at the top-right of each
/// pinned widget. Only the markers take pointer events.
class PinLayer extends StatelessWidget {
  const PinLayer({super.key, required this.placements, required this.onOpen});

  static const Key layerKey = ValueKey<String>('pinpoint.pins');

  final ValueListenable<List<PinPlacement>> placements;

  /// A click on the pin of the note with this id.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PinPlacement>>(
      key: layerKey,
      valueListenable: placements,
      builder: (context, pins, _) => LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            for (final pin in pins)
              Positioned(
                key: ValueKey<String>('pinpoint.pin.${pin.id}'),
                // The layer sits at the wrapper's origin, so a global rect
                // is a rect here too (engineering rule 7). Centered on the
                // widget's top-right corner, kept inside the screen.
                left: _clamp(
                  pin.rect.right - PinMarker.size / 2,
                  constraints.maxWidth - PinMarker.size,
                ),
                top: _clamp(
                  pin.rect.top - PinMarker.size / 2,
                  constraints.maxHeight - PinMarker.size,
                ),
                child: PinMarker(
                  number: pin.number,
                  status: pin.status,
                  onTap: () => onOpen(pin.id),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static double _clamp(double value, double max) =>
      max <= 0 ? 0 : value.clamp(0, max).toDouble();
}

/// A numbered pin. A note the agent is done with shows a tick (or a cross
/// when it rejected it) and fades, but stays until the user accepts it.
class PinMarker extends StatelessWidget {
  const PinMarker({
    super.key,
    required this.number,
    required this.status,
    required this.onTap,
  });

  /// Width and height.
  static const double size = 22;

  /// The opacity a resolved or rejected pin fades to.
  static const double fadedOpacity = 0.4;

  /// How long the fade takes. With the 2 second poll, a resolution shows
  /// within 3 seconds.
  static const Duration fadeDuration = Duration(milliseconds: 400);

  final int number;
  final NoteStatus status;
  final VoidCallback onTap;

  /// Whether the pin shows a tick or a cross instead of its number.
  static bool showsMark(NoteStatus status) =>
      status == NoteStatus.fixed ||
      status == NoteStatus.resolved ||
      status == NoteStatus.rejected;

  /// Whether the pin is faded: the agent says it is done. The agent can
  /// mark a note resolved without fixing it, so the pin stays until the
  /// user accepts the result.
  static bool isFaded(NoteStatus status) =>
      status == NoteStatus.resolved || status == NoteStatus.rejected;

  static String label(NoteStatus status) => switch (status) {
    NoteStatus.draft => 'draft',
    NoteStatus.submitted => 'sent',
    NoteStatus.inProgress => 'in progress',
    NoteStatus.fixed => 'fixed',
    NoteStatus.verified => 'accepted',
    NoteStatus.resolved => 'resolved',
    NoteStatus.rejected => 'rejected',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color fill, Color ink) = switch (status) {
      NoteStatus.draft => (scheme.surface, scheme.onSurfaceVariant),
      NoteStatus.submitted => (scheme.primary, scheme.onPrimary),
      NoteStatus.inProgress => (const Color(0xFFF9A825), Colors.black),
      NoteStatus.fixed ||
      NoteStatus.resolved ||
      NoteStatus.verified => (const Color(0xFF2E7D32), Colors.white),
      NoteStatus.rejected => (scheme.error, scheme.onError),
    };
    final mark = status == NoteStatus.rejected ? Icons.close : Icons.check;
    return Tooltip(
      message: 'Note $number (${label(status)})',
      child: AnimatedOpacity(
        opacity: isFaded(status) ? fadedOpacity : 1,
        duration: fadeDuration,
        child: Material(
          color: fill,
          shape: CircleBorder(
            side: BorderSide(
              color: status == NoteStatus.draft ? ink : Colors.white,
              width: 1.5,
            ),
          ),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: size,
              child: Center(
                child: showsMark(status)
                    ? Icon(mark, size: 14, color: ink)
                    : Text(
                        '$number',
                        style: TextStyle(
                          color: ink,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
