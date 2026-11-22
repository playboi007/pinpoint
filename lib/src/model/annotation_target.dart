part of 'annotation.dart';

class AppInfo {
  const AppInfo({
    required this.buildMode,
    required this.platform,
    this.projectRoot,
    this.origin,
  });

  factory AppInfo._fromJson(Map<String, Object?> json) => AppInfo(
    buildMode: asString(json['buildMode']) ?? 'debug',
    platform: asString(json['platform']) ?? 'web',
    projectRoot: asString(json['projectRoot']),
    origin: asString(json['origin']),
  );

  /// `debug`, `profile` or `release`.
  final String buildMode;

  /// `web`, or a `TargetPlatform` name such as `android`.
  final String platform;

  /// Null when `PINPOINT_ROOT` is not set.
  final String? projectRoot;

  /// The page's origin on web, for example `http://localhost:5000`; null
  /// elsewhere. Two apps can poll one bridge; each loads only the notes
  /// with its own origin.
  final String? origin;

  Map<String, Object?> toJson() => {
    'buildMode': buildMode,
    'platform': platform,
    'projectRoot': projectRoot,
    'origin': origin,
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

  factory PageInfo._fromJson(Map<String, Object?> json) => PageInfo(
    url: asString(json['url']),
    route: asString(json['route']),
    viewport: PayloadSize._fromJson(json['viewport']),
    devicePixelRatio: asDouble(json['devicePixelRatio']),
    textScale: asDouble(json['textScale']),
    brightness: asString(json['brightness']),
    locale: asString(json['locale']),
  );

  /// The browser's URL on web; null elsewhere. Every query value is masked
  /// (`?token=***`): a page URL can carry a session token.
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

  factory TargetInfo._fromJson(Map<String, Object?> json) => TargetInfo(
    widget: asString(json['widget']) ?? '?',
    description: asString(json['description']),
    key: asString(json['key']),
    source: SourceRef._fromJson(json['source']),
    sourceUnavailable: json['sourceUnavailable'] == true,
    rect: PayloadRect._fromJson(json['rect']),
    renderObject: asString(json['renderObject']),
    constraints: asString(json['constraints']),
    parentData: asString(json['parentData']),
    text: asString(json['text']),
    properties: asStringMap(json['properties']),
    sections: {
      for (final MapEntry(:key, :value) in asJsonMap(json['sections']).entries)
        key: asStringMap(value),
    },
  );

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

  static SourceRef? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final file = json['file'];
    final line = json['line'];
    if (file is! String || line is! int) return null;
    final column = json['column'];
    return SourceRef(
      file: file,
      line: line,
      column: column is int ? column : 1,
    );
  }

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

  static AncestorInfo? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final widget = json.str('widget');
    if (widget == null) return null;
    return AncestorInfo(
      widget: widget,
      source: SourceRef._fromJson(json['source']),
    );
  }

  final String widget;
  final SourceRef? source;

  Map<String, Object?> toJson() => {
    'widget': widget,
    'source': source?.toJson(),
  };
}

/// Where a note's pin belongs, in terms that outlive the widget.
///
/// A pin cannot hold an `Element`: elements die on rebuild, hot reload and
/// restart. The anchor names the widget by its constructor call instead,
/// and `SourceIndex` finds the live element again.
class NoteAnchor {
  const NoteAnchor({
    this.file,
    this.line,
    this.column,
    this.widget,
    this.key,
    this.ordinal = 0,
    this.itemIndex,
    this.route,
  });

  /// [json] (a [toJson] map) as an anchor. Reads defensively: a field of
  /// the wrong type is left out.
  factory NoteAnchor.fromJson(Map<String, Object?> json) {
    final ordinal = json['ordinal'];
    return NoteAnchor(
      file: asString(json['file']),
      line: asInt(json['line']),
      column: asInt(json['column']),
      widget: asString(json['widget']),
      key: asString(json['key']),
      ordinal: ordinal is int && ordinal >= 0 ? ordinal : 0,
      itemIndex: asInt(json['itemIndex']),
      route: asString(json['route']),
    );
  }

  /// The source file, as in [SourceRef.file]: relative to the project root
  /// when under it. Null outside debug, where no location exists.
  final String? file;

  /// 1-based.
  final int? line;

  /// 1-based.
  final int? column;

  /// The widget's type name, for example `Text`.
  final String? widget;

  /// The widget's key as text, for example `[<'save'>]`, or null.
  final String? key;

  /// Which of the widgets that match the rest of the anchor, in tree order.
  /// One constructor call builds every row of a list.
  final int ordinal;

  /// The index of the lazy-list item (`ListView.builder`, `GridView`) the
  /// widget is in, or null outside one. A scrolled list builds other items,
  /// so the [ordinal] alone would move to another row.
  final int? itemIndex;

  /// The route the note was written on, for the agent and the bridge.
  final String? route;

  /// Whether a live widget can be looked up: only with a file and a line.
  bool get resolvable => file != null && line != null;

  /// This anchor at another place in the same file, for a widget that
  /// moved after an edit. Each later edit is then measured from here.
  NoteAnchor movedTo({required int line, int? column}) => NoteAnchor(
    file: file,
    line: line,
    column: column,
    widget: widget,
    key: key,
    ordinal: ordinal,
    itemIndex: itemIndex,
    route: route,
  );

  /// This anchor with [ordinal].
  NoteAnchor withOrdinal(int ordinal) => NoteAnchor(
    file: file,
    line: line,
    column: column,
    widget: widget,
    key: key,
    ordinal: ordinal,
    itemIndex: itemIndex,
    route: route,
  );

  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'column': column,
    'widget': widget,
    'key': key,
    'ordinal': ordinal,
    'itemIndex': itemIndex,
    'route': route,
  };

  @override
  bool operator ==(Object other) =>
      other is NoteAnchor &&
      other.file == file &&
      other.line == line &&
      other.column == column &&
      other.widget == widget &&
      other.key == key &&
      other.ordinal == ordinal &&
      other.itemIndex == itemIndex &&
      other.route == route;

  @override
  int get hashCode =>
      Object.hash(file, line, column, widget, key, ordinal, itemIndex, route);

  @override
  String toString() =>
      'NoteAnchor(${widget ?? '?'} at ${file ?? '?'}:${line ?? '?'}'
      '${itemIndex == null ? '' : ', item $itemIndex'}'
      '${ordinal == 0 ? '' : ', #$ordinal'})';
}
