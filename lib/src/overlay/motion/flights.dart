import 'package:flutter/widgets.dart';

/// How a send ended, as the paper plane needs to know it.
enum SendOutcome { pending, sent, failed }

/// One Send, as the plane and the "Sent" stamp draw it.
///
/// [rect] is where the Send button was, in global logical pixels, read when
/// the send began: the panel goes away at once when the send works, so the
/// ghost must not depend on it.
class SendRun extends ChangeNotifier {
  SendRun(this.rect);

  final Rect rect;

  SendOutcome get outcome => _outcome;
  SendOutcome _outcome = SendOutcome.pending;

  /// Says how the send ended. Only the first answer counts.
  void settle({required bool ok}) {
    if (_outcome != SendOutcome.pending) return;
    _outcome = ok ? SendOutcome.sent : SendOutcome.failed;
    notifyListeners();
  }
}

/// One "Save draft": a ghost of the panel [from] flies to the pin that
/// appears at [pin]. Both are in global logical pixels.
class DraftRun {
  const DraftRun({required this.from, required this.pin});

  final Rect from;

  /// The corner of the saved widget the pin sits on.
  final Offset pin;
}

/// The one-shot moments of Pinpoint's UI that outlive the widget that
/// started them: the paper plane and the "Sent" stamp after a send, the
/// card that flies into its pin, and the ink that spreads over a new
/// palette. Each plays next to the action, never before it.
///
/// The overlay owns one and offers it below it through [FlightScope]. A
/// part built without a scope (a widget test of one panel) plays nothing.
class PinPointFlights extends ChangeNotifier {
  /// Put on the Send button by the comment footer, so its place can be read.
  final GlobalKey sendKey = GlobalKey(debugLabel: 'pinpoint send button');

  /// Put on the comment footer, which sits in the info panel: the panel's
  /// box is found above it.
  final GlobalKey footerKey = GlobalKey(debugLabel: 'pinpoint comment footer');

  /// Counts the Markdown copies that worked.
  final ValueNotifier<int> copies = ValueNotifier<int>(0);

  /// Starts the palette switch from a place; the overlay's palette host sets
  /// it. Takes a point in global logical pixels and returns whether a wipe
  /// plays.
  bool Function(Offset origin)? onInkWipe;

  SendRun? _send;
  DraftRun? _draft;

  /// The send being drawn, or null.
  SendRun? get send => _send;

  /// The save being drawn, or null.
  DraftRun? get draft => _draft;

  /// A send began. Reads where the Send button is now.
  void sendStarted() {
    final rect = _rectOf(sendKey.currentContext);
    if (rect == null || rect.isEmpty) return;
    _send = SendRun(rect);
    notifyListeners();
  }

  /// The send that began last ended, with [ok] or not.
  void sendSettled({required bool ok}) => _send?.settle(ok: ok);

  /// The ghost of [run] has played out.
  void sendDone(SendRun run) {
    if (_send != run) return;
    _send = null;
    notifyListeners();
  }

  /// The comment was saved as a draft whose pin sits at [pin].
  void draftSaved(Offset pin) {
    final footer = footerKey.currentContext;
    if (footer == null) return;
    Rect? panel;
    footer.visitAncestorElements((element) {
      if (element.widget.key == const ValueKey<String>('pinpoint.infoPanel')) {
        panel = _rectOf(element);
        return false;
      }
      return true;
    });
    final from = panel;
    if (from == null || from.isEmpty) return;
    _draft = DraftRun(from: from, pin: pin);
    notifyListeners();
  }

  /// The ghost of [run] has played out.
  void draftDone(DraftRun run) {
    if (_draft != run) return;
    _draft = null;
    notifyListeners();
  }

  /// The note was copied as Markdown.
  void copied() => copies.value++;

  /// Spreads the new palette from [origin]. False when nothing plays.
  bool inkWipe(Offset origin) => onInkWipe?.call(origin) ?? false;

  @override
  void dispose() {
    copies.dispose();
    super.dispose();
  }

  static Rect? _rectOf(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }
}

/// Offers a [PinPointFlights] to the parts of the overlay below it.
class FlightScope extends InheritedWidget {
  const FlightScope({super.key, required this.flights, required super.child});

  final PinPointFlights flights;

  /// The flights of the overlay above [context], or null without one.
  static PinPointFlights? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FlightScope>()?.flights;

  @override
  bool updateShouldNotify(FlightScope oldWidget) =>
      flights != oldWidget.flights;
}
