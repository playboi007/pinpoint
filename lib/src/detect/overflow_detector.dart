import 'package:flutter/rendering.dart';

import 'detector.dart';

/// Finds a `Row`, `Column` or `Flex` whose children do not fit, by
/// measuring: the children's main-axis sizes plus the spacing, against the
/// flex's own size.
///
/// Flutter's own overflow error (captured by the error hook) comes once per
/// render object until the next reassemble, so it misses the same overflow
/// after a what-if change. Measuring finds it every time.
class OverflowDetector extends Detector {
  const OverflowDetector();

  /// Rounding makes children a fraction of a pixel too wide; below this it
  /// is not an overflow (watch out for: false errors without a tolerance).
  static const double tolerance = 0.5;

  @override
  String get kind => 'overflow';

  @override
  Iterable<Finding> scan(RenderObject renderObject, ScanContext context) {
    if (renderObject is! RenderFlex || !renderObject.hasSize) {
      return const <Finding>[];
    }
    final flex = renderObject;
    final horizontal = flex.direction == Axis.horizontal;
    var total = 0.0;
    var count = 0;
    // The overflow state is private (docs/api-notes.md, item 9): measure.
    flex.visitChildren((child) {
      if (child is RenderBox && child.hasSize) {
        total += horizontal ? child.size.width : child.size.height;
        count++;
      }
    });
    if (count > 1) total += flex.spacing * (count - 1);
    final overflow = total - (horizontal ? flex.size.width : flex.size.height);
    if (overflow <= tolerance) return const <Finding>[];

    // While overflowing, the children start at the main axis start, so
    // they spill over its end.
    final side = horizontal
        ? (flex.textDirection == TextDirection.rtl ? 'left' : 'right')
        : (flex.verticalDirection == VerticalDirection.up ? 'top' : 'bottom');
    final widget = _widgetName(context.elementOf(flex)?.widget, horizontal);
    final amount = (overflow * 10).roundToDouble() / 10;
    return [
      context.finding(
        flex,
        kind: kind,
        severity: Severity.error,
        summary:
            '$widget overflows by ${formatPixels(amount)} px '
            '${horizontal ? 'on the' : 'at the'} $side',
        data: {
          'widget': widget,
          'overflow': amount,
          'side': side,
          'axis': horizontal ? 'horizontal' : 'vertical',
        },
      ),
    ];
  }

  static String _widgetName(Object? widget, bool horizontal) {
    final name = widget?.runtimeType.toString();
    if (name != null && !name.startsWith('_')) return name;
    return horizontal ? 'Row' : 'Column';
  }
}

/// [value] with no decimals when it is whole, else one: `72`, `25.5`.
String formatPixels(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1);
