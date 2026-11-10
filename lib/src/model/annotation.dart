// Plain Dart: no `dart:ui` and no `package:flutter`, so the bridge (`bin/`)
// can read and write the same payload.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sink/markdown_formatter.dart';

/// The payload version. The receiver rejects any other value, so a change
/// to the shape below needs a new number.
const int annotationSchema = 1;

/// Largest JSON for a note, without the screenshot, in UTF-8 bytes.
const int maxPayloadBytes = 8 * 1024;

/// What the note asks for.
enum AnnotationIntent { bug, improve, question }

/// One note: a comment on a widget, with everything an agent needs to act
/// on it without seeing the app.
///
/// [toJson] keeps a fixed shape: every key is present, with null for a part
/// that could not be read, except [errors] and [truncated], which appear
/// only when not empty, and [screenshot], which appears only when the note
/// has one. `test/goldens/annotation_schema.json` fixes it.
class Annotation {
  const Annotation({
    required this.id,
    required this.createdAt,
    required this.intent,
    required this.comment,
    required this.app,
    required this.page,
    required this.target,
    this.ancestors = const <AncestorInfo>[],
    this.frameworkChain = const <String>[],
    this.siblings,
    this.subtree,
    this.inherited,
    this.screenshot,
    this.errors = const <String>[],
    this.truncated = const <String>[],
  });

  /// For example `pp_20261110_143205_a1f3`. See [annotationId].
  final String id;

  final DateTime createdAt;
  final AnnotationIntent intent;
  final String comment;
  final AppInfo app;
  final PageInfo page;
  final TargetInfo target;

  /// Local widgets above the target, nearest first.
  final List<AncestorInfo> ancestors;

  /// Type names from the picked widget up, framework widgets included.
  final List<String> frameworkChain;

  final SiblingsInfo? siblings;

  /// The target's subtree as indented text, `file:line` on local widgets.
  final String? subtree;

  final InheritedInfo? inherited;

  /// Null when "Include screenshot" was off or the capture failed.
  final ScreenshotInfo? screenshot;

  /// Fields that failed to collect, for example `target.parentData`. The
  /// note is sent anyway.
  final List<String> errors;

  /// Fields cut to keep the payload in its size budget.
  final List<String> truncated;

  Annotation copyWith({
    String? comment,
    TargetInfo? target,
    List<AncestorInfo>? ancestors,
    List<String>? frameworkChain,
    SiblingsInfo? Function()? siblings,
    String? Function()? subtree,
    ScreenshotInfo? Function()? screenshot,
    List<String>? errors,
    List<String>? truncated,
  }) => Annotation(
    id: id,
    createdAt: createdAt,
    intent: intent,
    comment: comment ?? this.comment,
    app: app,
    page: page,
    target: target ?? this.target,
    ancestors: ancestors ?? this.ancestors,
    frameworkChain: frameworkChain ?? this.frameworkChain,
    siblings: siblings == null ? this.siblings : siblings(),
    subtree: subtree == null ? this.subtree : subtree(),
    inherited: inherited,
    screenshot: screenshot == null ? this.screenshot : screenshot(),
    errors: errors ?? this.errors,
    truncated: truncated ?? this.truncated,
  );

  /// This note with [shot] as its screenshot.
  Annotation withScreenshot(ScreenshotInfo? shot) =>
      copyWith(screenshot: () => shot);

  /// This note with [field] named in [errors].
  Annotation withError(String field) =>
      errors.contains(field) ? this : copyWith(errors: [...errors, field]);

  /// This note cut until its JSON is at most [maxBytes] UTF-8 bytes.
  ///
  /// Each step runs only while the note is still too large, least useful
  /// part first: the subtree, then long property values, then the sibling
  /// and framework lists. The comment, the source and the rect are what the
  /// agent acts on; the comment is cut only as the last resort. Each part
  /// cut is named once in [truncated].
  Annotation fitToBudget({int maxBytes = maxPayloadBytes}) {
    var note = this;
    for (final (name, cut) in _budgetSteps) {
      if (note._bytes <= maxBytes) return note;
      final smaller = cut(note);
      if (smaller == null) continue;
      note = smaller._marked(name);
    }
    if (note._bytes <= maxBytes) return note;
    // Marked first: the name in `truncated` counts toward the budget too.
    return note._marked('comment')._fitComment(maxBytes) ?? note;
  }

  int get _bytes => utf8.encode(jsonEncode(toJson())).length;

  Annotation _marked(String name) => truncated.contains(name)
      ? this
      : copyWith(truncated: [...truncated, name]);

  /// The longest cut of [comment] that fits, or null when none does.
  Annotation? _fitComment(int maxBytes) {
    Annotation withLength(int n) => copyWith(comment: clipText(comment, n));
    if (withLength(1)._bytes > maxBytes) return null;
    var low = 1; // fits
    var high = comment.length; // does not fit
    while (high - low > 1) {
      final middle = (low + high) ~/ 2;
      if (withLength(middle)._bytes <= maxBytes) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return withLength(low);
  }

  /// The budget steps, in order. A step returns null when it has nothing
  /// to cut.
  static final List<(String, Annotation? Function(Annotation))> _budgetSteps = [
    ('subtree', (a) => a._subtreeLines(10)),
    ('target.properties', (a) => a._target(a.target._clipProperties(60))),
    ('siblings', (a) => a._siblingWindow(5)),
    (
      'frameworkChain',
      (a) => a.frameworkChain.length <= 12
          ? null
          : a.copyWith(frameworkChain: a.frameworkChain.take(12).toList()),
    ),
    (
      'ancestors',
      (a) => a.ancestors.length <= 4
          ? null
          : a.copyWith(ancestors: a.ancestors.take(4).toList()),
    ),
    ('target.sections', (a) => a._target(a.target._clipSections(60))),
    ('target.text', (a) => a._target(a.target._clipText(100))),
    ('target.description', (a) => a._target(a.target._clipDescription(80))),
    (
      'subtree',
      (a) => a.subtree == null ? null : a.copyWith(subtree: () => null),
    ),
    ('target.properties', (a) => a._target(a.target._firstProperties(8))),
    (
      'frameworkChain',
      (a) => a.frameworkChain.isEmpty
          ? null
          : a.copyWith(frameworkChain: const <String>[]),
    ),
    (
      'siblings',
      (a) => a.siblings == null ? null : a.copyWith(siblings: () => null),
    ),
    (
      'ancestors',
      (a) => a.ancestors.length <= 1
          ? null
          : a.copyWith(ancestors: a.ancestors.take(1).toList()),
    ),
    ('target.sections', (a) => a._target(a.target._firstSections(0))),
    ('target.properties', (a) => a._target(a.target._firstProperties(0))),
  ];

  Annotation? _target(TargetInfo? cut) =>
      cut == null ? null : copyWith(target: cut);

  Annotation? _subtreeLines(int max) {
    final lines = subtree?.split('\n');
    if (lines == null || lines.length <= max + 1) return null;
    return copyWith(subtree: () => [...lines.take(max), '…'].join('\n'));
  }

  /// [max] siblings around the target's branch.
  Annotation? _siblingWindow(int max) {
    final s = siblings;
    if (s == null || s.children.length <= max) return null;
    final offset = s.index - s.firstIndex;
    final from = math.max(
      0,
      math.min(offset - max ~/ 2, s.children.length - max),
    );
    return copyWith(
      siblings: () => SiblingsInfo(
        parent: s.parent,
        index: s.index,
        count: s.count,
        firstIndex: s.firstIndex + from,
        children: s.children.sublist(from, from + max),
      ),
    );
  }

  /// The note as the Markdown a coding agent reads. Never holds the image.
  String toMarkdown() => markdownFor(this);

  /// The note as JSON. The screenshot's PNG goes in as base64 only with
  /// [includeScreenshotData], for a sink that wants the image (the HTTP
  /// sink). Without it, and in the size budget, the image is left out.
  Map<String, Object?> toJson({bool includeScreenshotData = false}) => {
    'schema': annotationSchema,
    'id': id,
    'createdAt': formatTimestamp(createdAt),
    'intent': intent.name,
    'comment': comment,
    'app': app.toJson(),
    'page': page.toJson(),
    'target': target.toJson(),
    'ancestors': [for (final a in ancestors) a.toJson()],
    'frameworkChain': frameworkChain,
    'siblings': siblings?.toJson(),
    'subtree': subtree,
    'inherited': inherited?.toJson(),
    if (screenshot case final shot?)
      'screenshot': shot.toJson(includeData: includeScreenshotData),
    if (errors.isNotEmpty) 'errors': errors,
    if (truncated.isNotEmpty) 'truncated': truncated,
  };
}

class AppInfo {
  const AppInfo({
    required this.buildMode,
    required this.platform,
    this.projectRoot,
  });

  /// `debug`, `profile` or `release`.
  final String buildMode;

  /// `web`, or a `TargetPlatform` name such as `android`.
  final String platform;

  /// Null when `PINPOINT_ROOT` is not set.
  final String? projectRoot;

  Map<String, Object?> toJson() => {
    'buildMode': buildMode,
    'platform': platform,
    'projectRoot': projectRoot,
  };
}

/// The screen the note was written on.
class PageInfo {
  const PageInfo({
    this.url,
    this.route,
    this.viewport,
    this.devicePixelRatio,
    this.textScale,
    this.brightness,
    this.locale,
  });

  /// The browser's URL on web; null elsewhere.
  final String? url;

  /// The route name of the target's route, else from the URL.
  final String? route;

  /// Logical pixels.
  final PayloadSize? viewport;

  final double? devicePixelRatio;

  /// The text scaler's factor for a 14 px font.
  final double? textScale;

  /// The platform brightness: `light` or `dark`.
  final String? brightness;

  /// For example `en_US`.
  final String? locale;

  Map<String, Object?> toJson() => {
    'url': url,
    'route': route,
    'viewport': viewport?.toJson(),
    'devicePixelRatio': jsonNumber(devicePixelRatio),
    'textScale': jsonNumber(textScale),
    'brightness': brightness,
    'locale': locale,
  };
}

/// The selected widget.
class TargetInfo {
  const TargetInfo({
    required this.widget,
    this.description,
    this.key,
    this.source,
    required this.sourceUnavailable,
    this.rect,
    this.renderObject,
    this.constraints,
    this.parentData,
    this.text,
    this.properties = const <String, String>{},
    this.sections = const <String, Map<String, String>>{},
  });

  /// The widget's type name, for example `Text`.
  final String widget;

  /// For example `Text("Save changes")`.
  final String? description;

  final String? key;

  /// Null outside debug and for widgets with no local location.
  final SourceRef? source;

  /// True when no widget in the chain has a local location.
  final bool sourceUnavailable;

  /// Global logical pixels.
  final PayloadRect? rect;

  /// For example `RenderParagraph`.
  final String? renderObject;

  final String? constraints;
  final String? parentData;

  /// Text shown in the target's subtree. Masked for obscured fields.
  final String? text;

  /// The widget's own diagnostics, `name: description`.
  final Map<String, String> properties;

  /// The info panel's sections, `title: {name: label}`.
  final Map<String, Map<String, String>> sections;

  TargetInfo copyWith({
    String? description,
    String? text,
    Map<String, String>? properties,
    Map<String, Map<String, String>>? sections,
  }) => TargetInfo(
    widget: widget,
    description: description ?? this.description,
    key: key,
    source: source,
    sourceUnavailable: sourceUnavailable,
    rect: rect,
    renderObject: renderObject,
    constraints: constraints,
    parentData: parentData,
    text: text ?? this.text,
    properties: properties ?? this.properties,
    sections: sections ?? this.sections,
  );

  TargetInfo? _clipProperties(int max) =>
      properties.values.every((v) => v.length <= max)
      ? null
      : copyWith(
          properties: {
            for (final MapEntry(:key, :value) in properties.entries)
              key: clipText(value, max),
          },
        );

  TargetInfo? _firstProperties(int max) => properties.length <= max
      ? null
      : copyWith(properties: Map.fromEntries(properties.entries.take(max)));

  TargetInfo? _clipSections(int max) =>
      sections.values.every((s) => s.values.every((v) => v.length <= max))
      ? null
      : copyWith(
          sections: {
            for (final MapEntry(key: title, value: labels) in sections.entries)
              title: {
                for (final MapEntry(:key, :value) in labels.entries)
                  key: clipText(value, max),
              },
          },
        );

  TargetInfo? _firstSections(int max) => sections.length <= max
      ? null
      : copyWith(sections: Map.fromEntries(sections.entries.take(max)));

  TargetInfo? _clipText(int max) {
    final value = text;
    return value == null || value.length <= max
        ? null
        : copyWith(text: clipText(value, max));
  }

  TargetInfo? _clipDescription(int max) {
    final value = description;
    return value == null || value.length <= max
        ? null
        : copyWith(description: clipText(value, max));
  }

  Map<String, Object?> toJson() => {
    'widget': widget,
    'description': description,
    'key': key,
    'source': source?.toJson(),
    'sourceUnavailable': sourceUnavailable,
    'rect': rect?.toJson(),
    'renderObject': renderObject,
    'constraints': constraints,
    'parentData': parentData,
    'text': text,
    'properties': properties,
    'sections': sections,
  };
}

/// A place in source. [file] is relative to the project root when it is
/// under it.
class SourceRef {
  const SourceRef({
    required this.file,
    required this.line,
    required this.column,
  });

  final String file;

  /// 1-based.
  final int line;

  /// 1-based.
  final int column;

  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'column': column,
  };
}

/// A local widget above the target.
class AncestorInfo {
  const AncestorInfo({required this.widget, this.source});

  final String widget;
  final SourceRef? source;

  Map<String, Object?> toJson() => {
    'widget': widget,
    'source': source?.toJson(),
  };
}

/// The children of the nearest ancestor with more than one child.
///
/// [children] is a window around the target's branch: [firstIndex] is the
/// index of its first entry, [count] the number of children in all.
class SiblingsInfo {
  const SiblingsInfo({
    required this.parent,
    required this.index,
    required this.count,
    required this.firstIndex,
    required this.children,
  });

  final String parent;

  /// The index of the child that holds the target.
  final int index;

  final int count;
  final int firstIndex;
  final List<String> children;

  Map<String, Object?> toJson() => {
    'parent': parent,
    'index': index,
    'count': count,
    'firstIndex': firstIndex,
    'children': children,
  };
}

/// Inherited values seen by the target.
class InheritedInfo {
  const InheritedInfo({
    this.themeBrightness,
    this.useMaterial3,
    this.textDirection,
  });

  final String? themeBrightness;
  final bool? useMaterial3;
  final String? textDirection;

  Map<String, Object?> toJson() => {
    'themeBrightness': themeBrightness,
    'useMaterial3': useMaterial3,
    'textDirection': textDirection,
  };
}

/// A PNG crop of the app around the target, with the target outlined.
class ScreenshotInfo {
  const ScreenshotInfo({
    required this.file,
    required this.pixelRatio,
    required this.width,
    required this.height,
    this.crop,
    this.hasPlatformViews = false,
    this.debugPaint = const <String>[],
    this.png,
  });

  /// The file name the receiver writes the image to: `<id>.png`.
  final String file;

  /// Image pixels per logical pixel.
  final double pixelRatio;

  /// In image pixels.
  final int width;
  final int height;

  /// The captured part of the screen, in global logical pixels.
  final PayloadRect? crop;

  /// True when a platform view (`HtmlElementView`, a map, an iframe) is in
  /// the crop. On web those render as empty areas, so the image is partial.
  final bool hasPlatformViews;

  /// The debug paint flags that were on, for example
  /// `debugPaintSizeEnabled`. Their marks are in the image.
  final List<String> debugPaint;

  /// The PNG bytes. Never in [toJson] unless asked for.
  final Uint8List? png;

  Map<String, Object?> toJson({bool includeData = false}) => {
    'file': file,
    'pixelRatio': jsonNumber(pixelRatio),
    'width': width,
    'height': height,
    'crop': crop?.toJson(),
    'hasPlatformViews': hasPlatformViews,
    'debugPaint': debugPaint,
    if (includeData && png != null) 'data': base64Encode(png!),
  };
}

/// A rect in global logical pixels, without `dart:ui`.
class PayloadRect {
  const PayloadRect(this.x, this.y, this.w, this.h);

  final double x;
  final double y;
  final double w;
  final double h;

  Map<String, Object?> toJson() => {
    'x': jsonNumber(x),
    'y': jsonNumber(y),
    'w': jsonNumber(w),
    'h': jsonNumber(h),
  };
}

/// A size in logical pixels, without `dart:ui`.
class PayloadSize {
  const PayloadSize(this.width, this.height);

  final double width;
  final double height;

  Map<String, Object?> toJson() => {
    'width': jsonNumber(width),
    'height': jsonNumber(height),
  };
}

/// [value] for JSON: null when not finite (JSON has no `Infinity` or `NaN`,
/// and `jsonEncode` throws on them), rounded to 0.01, and an `int` when
/// whole.
num? jsonNumber(double? value) {
  if (value == null || !value.isFinite) return null;
  final rounded = (value * 100).roundToDouble() / 100;
  return rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded;
}

/// [time] in UTC to the second, for example `2026-11-10T14:32:05Z`.
String formatTimestamp(DateTime time) {
  final t = time.toUtc();
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-'
      '${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}Z';
}

/// A new note id, for example `pp_20261110_143205_a1f3`: the UTC time to
/// the second and four random hex digits.
///
/// It becomes a file name on the receiver, so it holds only `[a-z0-9_]`.
String annotationId(DateTime time, math.Random random) {
  final t = time.toUtc();
  final suffix = random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
  return 'pp_${t.year.toString().padLeft(4, '0')}${_two(t.month)}'
      '${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}'
      '_$suffix';
}

/// [text] cut to at most [max] UTF-16 code units, ending in "…" when cut.
/// A surrogate pair is never split, so the result always encodes.
String clipText(String text, int max) {
  if (text.length <= max) return text;
  if (max <= 1) return '…';
  var end = max - 1;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${text.substring(0, end)}…';
}

String _two(int n) => n.toString().padLeft(2, '0');
