import 'package:flutter/widgets.dart';

import 'draft_ghost.dart';
import 'flights.dart';
import 'paper_plane.dart';

/// Draws the ghosts of [PinPointFlights] above the panels: the paper plane
/// and the "Sent" stamp, and the card that flies into its pin.
///
/// It takes no pointer events, and builds nothing while no ghost plays.
/// The layer sits at the wrapper's origin like every other layer, so a
/// global rect is a rect here too (engineering rule 7).
class FlightLayer extends StatelessWidget {
  const FlightLayer({super.key, required this.flights});

  static const Key layerKey = ValueKey<String>('pinpoint.flights');

  final PinPointFlights flights;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: flights,
      builder: (context, _) {
        final send = flights.send;
        final draft = flights.draft;
        if (send == null && draft == null) return const SizedBox.shrink();
        return IgnorePointer(
          child: Stack(
            key: layerKey,
            fit: StackFit.expand,
            children: [
              if (draft != null)
                Positioned.fill(
                  key: ValueKey<DraftRun>(draft),
                  child: DraftGhost(
                    run: draft,
                    onDone: () => flights.draftDone(draft),
                  ),
                ),
              if (send != null)
                Positioned.fill(
                  key: ValueKey<SendRun>(send),
                  child: SendGhost(
                    run: send,
                    onDone: () => flights.sendDone(send),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
