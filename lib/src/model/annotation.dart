// Plain Dart: no `dart:ui` and no `package:flutter`, so the bridge (`bin/`)
// can read and write the same payload.

import 'dart:math' as math;

/// The payload version. The receiver rejects any other value, so a change
/// to the shape below needs a new number.
const int annotationSchema = 1;

/// What the note asks for.
enum AnnotationIntent { bug, improve, question }

/// One note: a comment on a widget, with everything an agent needs to act
/// on it without seeing the app.
///
/// [toJson] keeps a fixed shape: every key is present, with null for a part
/// that could not be read, except [errors] and [truncated], which appear
/// only when not empty. `test/goldens/annotation_schema.json` fixes it.
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

  /// Fields that failed to collect, for example `target.parentData`. The
  /// note is sent anyway.
  final List<String> errors;

  /// Fields cut to keep the payload in its size budget.
  final List<String> truncated;

  Map<String, Object?> toJson() => {
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
