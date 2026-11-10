import 'package:flutter/rendering.dart';

import '../model/annotation.dart' show PayloadRect, clipText;
import 'detector.dart';

/// Finds text cut off at its line limit: every visible `RenderParagraph`
/// with `didExceedMaxLines`.
///
/// Truncation is often intended (a list title with an ellipsis), so a
/// finding is `info`, and Milestone 12's stress matrix must never file one
/// as a note by itself.
class TruncationDetector extends Detector {
  const TruncationDetector();

  /// Longest text kept (engineering rule 9).
  static const int maxText = 300;

  @override
  String get kind => 'truncated_text';

  @override
  Iterable<Finding> scan(RenderObject renderObject, ScanContext context) {
    if (renderObject is! RenderParagraph || !renderObject.hasSize) {
      return const <Finding>[];
    }
    final paragraph = renderObject;
    if (!paragraph.didExceedMaxLines) return const <Finding>[];
    final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
    final lines = paragraph.maxLines;
    final visible = context.visible;
    return [
      context.finding(
        paragraph,
        kind: kind,
        severity: Severity.info,
        summary:
            'Text cut at ${lines ?? 'its'} line${lines == 1 ? '' : 's'}: '
            '"${clipText(text, 60)}"',
        data: {
          'text': clipText(text, maxText),
          'maxLines': ?lines,
          'overflow': paragraph.overflow.name,
          'visible': PayloadRect(
            visible.left,
            visible.top,
            visible.width,
            visible.height,
          ).toJson(),
        },
      ),
    ];
  }
}
