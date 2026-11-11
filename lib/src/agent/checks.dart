import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/app_semantics.dart';
import '../detect/a11y_audit.dart';
import '../detect/detector.dart';
import '../detect/overflow_detector.dart';
import '../detect/truncation_detector.dart';
import '../model/annotation.dart';
import '../search/render_search.dart';
import '../search/source_index.dart';
import '../search/source_resolver.dart';

/// The outcome of one check of a note.
@immutable
class CheckResult {
  const CheckResult({
    required this.type,
    required this.passed,
    required this.message,
    this.measured,
  });

  /// A failed check: [message] says why.
  const CheckResult.fail(this.type, this.message, {this.measured})
    : passed = false;

  /// For example `no_overflow`.
  final String type;

  final bool passed;

  /// One line: what was measured, for example `Row overflows by 72 px on
  /// the right`.
  final String message;

  /// The measured value, as JSON: a number, a size or a list.
  final Object? measured;

  Map<String, Object?> toJson() => {
    'type': type,
    'passed': passed,
    'message': message,
    'measured': ?measured,
  };

  @override
  String toString() => '${passed ? 'PASS' : 'FAIL'} $type: $message';
}

/// A check the comment form offers in its menu.
@immutable
class CheckOption {
  const CheckOption(this.label, this.check);

  /// For example `No overflow`.
  final String label;

  /// The check as it goes into the note, for example `{type: no_overflow}`.
  final Map<String, Object?> check;

  String get type => check['type']! as String;
}

/// The checks the comment form offers: the ones that need no second
/// widget. `text_contains` is offered too, with the selected widget's
/// text, when it shows text. `gap_to`, `aligned_with`, `min_size` and
/// `max_size` need values the form does not ask for; an agent or a note
/// made by hand can carry them.
const List<CheckOption> commentChecks = [
  CheckOption('Visible', {'type': 'visible'}),
  CheckOption('No overflow', {'type': 'no_overflow'}),
  CheckOption('Text not cut off', {'type': 'not_truncated'}),
  CheckOption('Inside its parent', {'type': 'within_parent'}),
  CheckOption('Tap target at least 48', {'type': 'tap_target_min', 'min': 48}),
  CheckOption('Contrast at least 4.5:1', {'type': 'contrast_min', 'min': 4.5}),
];

/// Measures the checks of a note on one widget (plan Milestone 12, step
/// 7).
///
/// Sizes, gaps and edges are in the app's own logical pixels (its
/// boundary's space), so a what-if viewport the frame scales down does not
/// change them.
class CheckRunner {
  CheckRunner({
    required this.appRoot,
    required this.content,
    required this.resolver,
    required this.devicePixelRatio,
  });

  /// Half a pixel: layout rounding is not a failure.
  static const double tolerance = 0.5;

  /// The app's boundary.
  final RenderObject appRoot;

  /// The element directly above the app's own widgets.
  final Element content;

  final SourceResolver resolver;

  final double devicePixelRatio;

  late final FindingLocator _locator = FindingLocator(
    resolver: resolver,
    boundary: content,
  );

  /// Runs [checks] on [target], in order. [target] null means the note's
  /// anchor did not resolve: then every check fails with "anchor not
  /// found" (watch out for: a check that passes because the widget is
  /// gone is a false pass).
  Future<List<CheckResult>> run(
    Element? target,
    List<Map<String, Object?>> checks,
  ) async {
    final results = <CheckResult>[];
    final renderObject = target == null ? null : _renderObjectOf(target);
    for (final check in checks) {
      final type = check['type'] is String ? check['type']! as String : '?';
      if (target == null) {
        results.add(CheckResult.fail(type, 'anchor not found'));
        continue;
      }
      if (renderObject == null) {
        results.add(CheckResult.fail(type, 'the widget is not laid out'));
        continue;
      }
      try {
        results.add(await _one(type, check, target, renderObject));
      } on Object catch (error) {
        results.add(CheckResult.fail(type, 'could not measure: $error'));
      }
    }
    return results;
  }

  Future<CheckResult> _one(
    String type,
    Map<String, Object?> check,
    Element target,
    RenderObject renderObject,
  ) async {
    switch (type) {
      case 'visible':
        return _visible(renderObject);
      case 'no_overflow':
        return _scan(
          type,
          renderObject,
          const OverflowDetector(),
          'no overflow',
        );
      case 'not_truncated':
        return _scan(
          type,
          renderObject,
          const TruncationDetector(),
          'no text cut off',
        );
      case 'min_size':
      case 'max_size':
        return _size(type, check, renderObject);
      case 'within_parent':
        return _withinParent(target, renderObject);
      case 'gap_to':
        return _gap(check, renderObject);
      case 'aligned_with':
        return _aligned(check, renderObject);
      case 'text_contains':
        return _text(check, renderObject);
      case 'contrast_min':
        return _contrast(check, renderObject);
      case 'tap_target_min':
        return _tapTarget(check, renderObject);
    }
    return CheckResult.fail(type, 'unknown check: $type');
  }

  CheckResult _visible(RenderObject renderObject) {
    final visible = RenderSearch.visibleRectOf(renderObject);
    if (visible == null || visible.width <= 0 || visible.height <= 0) {
      return const CheckResult.fail(
        'visible',
        'not on screen (offstage, clipped or scrolled away)',
      );
    }
    if (!RenderSearch.isOnApp(appRoot, visible.center)) {
      return const CheckResult.fail('visible', 'outside the app viewport');
    }
    return CheckResult(
      type: 'visible',
      passed: true,
      message: 'on screen',
      measured: _rect(visible),
    );
  }

  CheckResult _scan(
    String type,
    RenderObject renderObject,
    Detector detector,
    String clean,
  ) {
    final found = scanTree(
      renderObject,
      [detector],
      locator: _locator,
      includeRoot: true,
    ).findings;
    if (found.isEmpty) {
      return CheckResult(type: type, passed: true, message: clean);
    }
    return CheckResult.fail(
      type,
      [for (final f in found.take(3)) f.summary].join('; '),
      measured: [for (final f in found.take(5)) f.data],
    );
  }

  CheckResult _size(
    String type,
    Map<String, Object?> check,
    RenderObject renderObject,
  ) {
    final rect = _appRect(renderObject);
    final width = _double(check['width']);
    final height = _double(check['height']);
    if (width == null && height == null) {
      return CheckResult.fail(type, 'give a width, a height or both');
    }
    final min = type == 'min_size';
    bool ok(double actual, double? limit) =>
        limit == null ||
        (min ? actual >= limit - tolerance : actual <= limit + tolerance);
    final passed = ok(rect.width, width) && ok(rect.height, height);
    final size = '${_num(rect.width)} x ${_num(rect.height)}';
    final limit = [
      if (width != null) 'width ${_num(width)}',
      if (height != null) 'height ${_num(height)}',
    ].join(', ');
    return CheckResult(
      type: type,
      passed: passed,
      message: '$size, ${min ? 'at least' : 'at most'} $limit',
      measured: {'width': _num(rect.width), 'height': _num(rect.height)},
    );
  }

  CheckResult _withinParent(Element target, RenderObject renderObject) {
    const type = 'within_parent';
    // The nearest local widget above with its own render object: a custom
    // widget shares its build root's render object (api-notes item 19),
    // and is never outside itself.
    final chain = resolver.chain(target, boundary: content);
    RenderObject? parent;
    String? name;
    for (var i = 1; i < chain.length; i++) {
      final entry = chain[i];
      if (!entry.isLocal) continue;
      final candidate = _renderObjectOf(entry.element);
      if (candidate == null || identical(candidate, renderObject)) continue;
      parent = candidate;
      name = entry.name;
      break;
    }
    if (parent == null) {
      return const CheckResult.fail(type, 'no local parent to measure against');
    }
    final r = _appRect(renderObject);
    final p = _appRect(parent);
    final over = {
      'left': p.left - r.left,
      'top': p.top - r.top,
      'right': r.right - p.right,
      'bottom': r.bottom - p.bottom,
    };
    final out = {
      for (final MapEntry(:key, :value) in over.entries)
        if (value > tolerance) key: _num(value),
    };
    if (out.isEmpty) {
      return CheckResult(type: type, passed: true, message: 'inside $name');
    }
    return CheckResult.fail(
      type,
      'sticks out of $name: '
      '${[for (final MapEntry(:key, :value) in out.entries) '$key by $value px'].join(', ')}',
      measured: out,
    );
  }

  CheckResult _gap(Map<String, Object?> check, RenderObject renderObject) {
    const type = 'gap_to';
    final other = _target(check['target']);
    if (other == null) return const CheckResult.fail(type, 'target not found');
    final a = _appRect(renderObject);
    final b = _appRect(other);
    final dx = math.max(b.left - a.right, a.left - b.right);
    final dy = math.max(b.top - a.bottom, a.top - b.bottom);
    final axis = check['axis'];
    final gap = switch (axis) {
      'horizontal' => dx,
      'vertical' => dy,
      _ => math.max(dx, dy),
    };
    final min = _double(check['min']);
    final max = _double(check['max']);
    final passed =
        (min == null || gap >= min - tolerance) &&
        (max == null || gap <= max + tolerance);
    final range = [
      if (min != null) 'at least ${_num(min)}',
      if (max != null) 'at most ${_num(max)}',
    ].join(' and ');
    return CheckResult(
      type: type,
      passed: passed,
      message: 'gap ${_num(gap)} px${range.isEmpty ? '' : ', $range'}',
      measured: _num(gap),
    );
  }

  CheckResult _aligned(Map<String, Object?> check, RenderObject renderObject) {
    const type = 'aligned_with';
    final edge = check['edge'] is String ? check['edge']! as String : 'left';
    final other = _target(check['target']);
    if (other == null) return const CheckResult.fail(type, 'target not found');
    double? value(Rect r) => switch (edge) {
      'left' => r.left,
      'right' => r.right,
      'top' => r.top,
      'bottom' => r.bottom,
      'centerX' => r.center.dx,
      'centerY' => r.center.dy,
      _ => null,
    };
    final mine = value(_appRect(renderObject));
    final theirs = value(_appRect(other));
    if (mine == null || theirs == null) {
      return CheckResult.fail(type, 'unknown edge: $edge');
    }
    final off = (mine - theirs).abs();
    final allowed = _double(check['tolerance']) ?? tolerance;
    return CheckResult(
      type: type,
      passed: off <= allowed,
      message: '$edge edges ${_num(off)} px apart',
      measured: _num(off),
    );
  }

  CheckResult _text(Map<String, Object?> check, RenderObject renderObject) {
    const type = 'text_contains';
    final want = check['text'];
    if (want is! String || want.isEmpty) {
      return const CheckResult.fail(type, 'give the text to look for');
    }
    final texts = <String>[];
    var visited = 0;
    void visit(RenderObject node) {
      if (++visited > RenderSearch.defaultMaxNodes) return;
      if (node is RenderParagraph) {
        texts.add(node.text.toPlainText(includeSemanticsLabels: false));
      } else if (node is RenderEditable && !node.obscureText) {
        final text = node.text?.toPlainText(includeSemanticsLabels: false);
        if (text != null) texts.add(text);
      }
      node.visitChildren(visit);
    }

    visit(renderObject);
    final shown = texts.join(' ');
    return CheckResult(
      type: type,
      passed: shown.contains(want),
      message: shown.contains(want)
          ? 'contains "${clipText(want, 60)}"'
          : 'no "${clipText(want, 60)}" in "${clipText(shown, 80)}"',
      measured: clipText(shown, 200),
    );
  }

  Future<CheckResult> _contrast(
    Map<String, Object?> check,
    RenderObject renderObject,
  ) async {
    const type = 'contrast_min';
    final boundary = appRoot;
    if (boundary is! RenderRepaintBoundary) {
      return const CheckResult.fail(type, 'no app boundary to capture');
    }
    final paragraphs = <(RenderParagraph, Rect)>[];
    RenderSearch.visitVisible(renderObject, (node, rect, visible) {
      if (node is! RenderParagraph) return;
      // The walk starts below the clips above the widget: read each
      // paragraph's own visible part.
      final shown = RenderSearch.visibleRectOf(node);
      if (shown != null && shown.width > 0 && shown.height > 0) {
        paragraphs.add((node, shown));
      }
    }, includeRoot: true);
    final measures = await measureContrast(boundary, paragraphs);
    if (measures.isEmpty) {
      return const CheckResult.fail(type, 'no text to measure');
    }
    final lowest = measures.reduce((a, b) => a.ratio <= b.ratio ? a : b);
    final min = _double(check['min']) ?? lowest.required;
    final ratio = (lowest.ratio * 100).roundToDouble() / 100;
    return CheckResult(
      type: type,
      passed: lowest.ratio >= min,
      message:
          'lowest contrast $ratio:1, at least ${_num(min)}:1'
          '${lowest.highConfidence ? '' : ' (low confidence: mixed background)'}',
      measured: ratio,
    );
  }

  Future<CheckResult> _tapTarget(
    Map<String, Object?> check,
    RenderObject renderObject,
  ) async {
    const type = 'tap_target_min';
    final min = _double(check['min']) ?? minTapTarget;
    // Semantics are on for this check only: on web they cost a parallel
    // DOM tree (Milestone 10). The handle is disposed on every path.
    final handle = SemanticsBinding.instance.ensureSemantics();
    // The wrapper hides the app's semantics while a mode is active.
    final done = AppSemantics.read();
    try {
      // The tree is built in the next frame. A check runs on demand, so
      // forcing that one frame is fine (engineering rule 2).
      await SchedulerBinding.instance.endOfFrame;
      if (!renderObject.attached) {
        return const CheckResult.fail(type, 'the widget went away');
      }
      final sides = <double>[];
      final seen = <SemanticsNode>{};
      RenderSearch.visitVisible(renderObject, (node, rect, visible) {
        final semantics = node.debugSemantics;
        if (semantics == null || !seen.add(semantics)) return;
        if (semantics.isMergedIntoParent) return;
        final data = semantics.getSemanticsData();
        if (data.flagsCollection.isHidden) return;
        if (!data.hasAction(ui.SemanticsAction.tap) &&
            !data.hasAction(ui.SemanticsAction.longPress)) {
          return;
        }
        final global = semanticsGlobalRect(semantics, devicePixelRatio);
        if (global != null) {
          sides.add(math.min(global.width, global.height));
        }
      }, includeRoot: true);
      if (sides.isEmpty) {
        return const CheckResult.fail(type, 'no tap target in the widget');
      }
      final smallest = sides.reduce(math.min);
      final rounded = (smallest * 10).roundToDouble() / 10;
      return CheckResult(
        type: type,
        passed: smallest >= min - 0.01,
        message:
            'smallest tap target side ${_num(rounded)}, at least ${_num(min)}',
        measured: _num(rounded),
      );
    } finally {
      done();
      handle.dispose();
    }
  }

  /// The render object of the widget a check's `target` names: an anchor
  /// with a file and line (nearest-line matching), or a type and key.
  RenderObject? _target(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final anchor = NoteAnchor.fromJson(json);
    final index = SourceIndex(resolver: resolver);
    Element? element;
    if (anchor.resolvable) {
      element = index.resolve(anchor, root: content);
    } else if (anchor.widget != null || anchor.key != null) {
      final matches = index.query(
        root: content,
        type: anchor.widget,
        where: anchor.key == null
            ? null
            : (e) => e.widget.key?.toString() == anchor.key,
      );
      element = anchor.ordinal < matches.length
          ? matches[anchor.ordinal]
          : null;
    }
    return element == null ? null : _renderObjectOf(element);
  }

  /// [renderObject]'s rect in the app's own logical pixels.
  Rect _appRect(RenderObject renderObject) => MatrixUtils.transformRect(
    renderObject.getTransformTo(appRoot),
    renderObject.paintBounds,
  );

  static RenderObject? _renderObjectOf(Element element) {
    try {
      final renderObject = element.renderObject;
      return renderObject != null && renderObject.attached
          ? renderObject
          : null;
    } catch (_) {
      return null;
    }
  }

  static List<num> _rect(Rect rect) => [
    _num(rect.left),
    _num(rect.top),
    _num(rect.width),
    _num(rect.height),
  ];

  static double? _double(Object? value) =>
      value is num ? value.toDouble() : null;

  static num _num(double value) {
    final r = (value * 10).roundToDouble() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }
}
