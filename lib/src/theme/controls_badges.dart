part of 'controls.dart';

/// A 14 px ink pill with a count in paper micro text.
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Container(
      height: 14,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      color: tokens.ink,
      child: Text('$count', style: tokens.micro.copyWith(color: tokens.paper)),
    );
  }
}

/// The severity of a finding, for [SeverityBadge].
enum PinPointSeverityLook { error, warn, info }

/// An 18 px badge: tinted fill, 1 px border, icon and `ERROR`, `WARN` or
/// `INFO`.
class SeverityBadge extends StatelessWidget {
  const SeverityBadge(this.look, {super.key});

  final PinPointSeverityLook look;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final (
      Color color,
      Color fill,
      IconData icon,
      String text,
    ) = switch (look) {
      PinPointSeverityLook.error => (
        tokens.err,
        tokens.errBg,
        PinPointIcons.error,
        'ERROR',
      ),
      PinPointSeverityLook.warn => (
        tokens.warn,
        tokens.warnBg,
        PinPointIcons.warning,
        'WARN',
      ),
      PinPointSeverityLook.info => (
        tokens.info,
        tokens.infoBg,
        PinPointIcons.info,
        'INFO',
      ),
    };
    return Container(
      height: 18,
      padding: const EdgeInsets.only(left: 3, right: 6),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(text, style: tokens.caps.copyWith(color: color)),
        ],
      ),
    );
  }
}

enum _SystemBadgeKind { bridgeOffline, frozen }

/// A 22 px badge for a state of the whole tool.
///
/// [SystemBadge.bridgeOffline]: dashed ink border, link-off icon. The
/// optional detail (why it is offline) shows as a tooltip.
/// [SystemBadge.frozen]: ink fill, snowflake icon.
class SystemBadge extends StatelessWidget {
  const SystemBadge.bridgeOffline({super.key, this.detail})
    : _kind = _SystemBadgeKind.bridgeOffline;

  const SystemBadge.frozen({super.key})
    : detail = null,
      _kind = _SystemBadgeKind.frozen;

  /// More text for a tooltip. Only [SystemBadge.bridgeOffline] has it.
  final String? detail;
  final _SystemBadgeKind _kind;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final offline = _kind == _SystemBadgeKind.bridgeOffline;
    final color = offline ? tokens.ink : tokens.paper;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            offline ? PinPointIcons.linkOff : PinPointIcons.acUnit,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            offline ? 'BRIDGE OFFLINE' : 'FROZEN',
            style: tokens.caps.copyWith(color: color),
          ),
        ],
      ),
    );
    Widget badge = SizedBox(
      height: 22,
      child: offline
          ? DashedBox(
              color: tokens.ink,
              fill: tokens.paper,
              child: Center(widthFactor: 1, child: content),
            )
          : ColoredBox(
              color: tokens.ink,
              child: Center(widthFactor: 1, child: content),
            ),
    );
    if (detail != null) badge = Tooltip(message: detail, child: badge);
    return badge;
  }
}
