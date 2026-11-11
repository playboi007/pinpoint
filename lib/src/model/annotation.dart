// Plain Dart: no `dart:ui` and no `package:flutter`, so the bridge (`bin/`)
// can read and write the same payload.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sink/markdown_formatter.dart';

/// The payload version. The receiver rejects any other value, so a change
/// to the shape below needs a new number.
///
/// 2 (Milestone 8): `status`, `anchor`, `messages` and `app.origin`.
/// 3 (Milestone 9): `environment`, the what-if overrides.
/// 4 (Milestone 10): `finding` and `checks`, for a note made from a finding.
/// 5 (Milestone 11): `tweaks`, the live edits, and `screenshot.beforeAfter`.
/// 6 (Milestone 12): `verification`, the outcome of `verify_note`, written
/// by the bridge.
const int annotationSchema = 6;

/// Largest JSON for a note, without the screenshot, in UTF-8 bytes.
const int maxPayloadBytes = 8 * 1024;

/// What the note asks for.
enum AnnotationIntent { bug, improve, question }

/// Where a note is in its round trip between the user and the agent.
///
/// The JSON value is the enum name, for example `inProgress`.
enum NoteStatus {
  /// Written but not sent. Never visible to the agent, so half-written
  /// feedback never triggers an edit.
  draft,

  /// Sent: the agent may work on it.
  submitted,

  /// The agent is working on it.
  inProgress,

  /// The agent changed the code; not yet checked.
  fixed,

  /// The user (Milestone 12: a measured check) accepted the result.
  verified,

  /// The agent says it is done. The pin fades but stays until the user
  /// accepts it: an agent can mark a note resolved without fixing it.
  resolved,

  /// The agent will not do it, with a message that says why.
  rejected;

  /// The status named [name], or null.
  static NoteStatus? byName(Object? name) {
    for (final status in values) {
      if (status.name == name) return status;
    }
    return null;
  }

  /// Statuses whose files live in `open/`: the agent's work list.
  static const Set<NoteStatus> open = {submitted, inProgress, fixed};

  /// Statuses whose files live in `resolved/`.
  static const Set<NoteStatus> closed = {verified, resolved, rejected};
}

/// A message on a note, for example the agent's reply when it resolves it.
class NoteMessage {
  const NoteMessage({required this.at, required this.from, required this.text});

  /// [json] as a message, or null when it has no text.
  static NoteMessage? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final text = json['text'];
    if (text is! String) return null;
    final from = json['from'];
    return NoteMessage(
      at: _dateOrNull(json['at']) ?? DateTime.utc(1970),
      from: from is String ? from : 'agent',
      text: text,
    );
  }

  final DateTime at;

  /// `agent` or `user`.
  final String from;

  final String text;

  Map<String, Object?> toJson() => {
    'at': formatTimestamp(at),
    'from': from,
    'text': text,
  };
}

/// One note: a comment on a widget, with everything an agent needs to act
/// on it without seeing the app.
///
/// [toJson] keeps a fixed shape: every key is present, with null for a part
/// that could not be read, except [errors] and [truncated], which appear
/// only when not empty, [screenshot], which appears only when the note
/// has one, [environment], which appears only while a what-if override
/// is active, [finding] and [checks], which appear only on a note made
/// from a finding, [tweaks], which appear only while a tweak is active, and
/// [verification], which appears once `verify_note` ran.
/// `test/goldens/annotation_schema.json` fixes it.
class Annotation {
  const Annotation({
    required this.id,
    required this.createdAt,
    required this.intent,
    required this.comment,
    required this.app,
    required this.page,
    required this.target,
    this.status = NoteStatus.draft,
    this.anchor,
    this.messages = const <NoteMessage>[],
    this.ancestors = const <AncestorInfo>[],
    this.frameworkChain = const <String>[],
    this.siblings,
    this.subtree,
    this.inherited,
    this.environment,
    this.finding,
    this.checks = const <Map<String, Object?>>[],
    this.tweaks = const <Map<String, Object?>>[],
    this.verification,
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

  /// A new note is a draft until it is sent.
  final NoteStatus status;

  /// Where the note's pin belongs. Null when it was not read.
  final NoteAnchor? anchor;

  /// Replies from the agent and the user, oldest first.
  final List<NoteMessage> messages;

  /// Local widgets above the target, nearest first.
  final List<AncestorInfo> ancestors;

  /// Type names from the picked widget up, framework widgets included.
  final List<String> frameworkChain;

  final SiblingsInfo? siblings;

  /// The target's subtree as indented text, `file:line` on local widgets.
  final String? subtree;

  final InheritedInfo? inherited;

  /// The what-if overrides active when the note was filed, only the
  /// overridden fields (`EnvironmentController.toJson`), for example
  /// `{viewport: {width: 360, height: 800}, textScale: 1.5}`. Null when
  /// nothing was overridden. [page] keeps the real window.
  final Map<String, Object?>? environment;

  /// The finding this note was made from (`Finding.toJson`: kind,
  /// severity, summary, key and measured data), or null for a note written
  /// by hand.
  final Map<String, Object?>? finding;

  /// What Milestone 12's `verify_note` measures, each with a `type`, for
  /// example `{type: no_overflow}`. Empty when none were chosen.
  final List<Map<String, Object?>> checks;

  /// The last `verify_note` outcome, written by the bridge: `at`,
  /// `passed`, `checks` (each `type`, `passed`, `message`, `measured`),
  /// `found` (where the anchor resolved) and `after` (the after
  /// screenshot's file). Null until a verification ran.
  final Map<String, Object?>? verification;

  /// Whether the last verification passed; null when none ran.
  bool? get checksPassed => switch (verification?['passed']) {
    final bool passed => passed,
    _ => null,
  };

  /// The live edits on screen when the note was filed (`Tweak.toJson`):
  /// `renderType`, `property`, `from`, `to`, `createdBy` and
  /// `nearestLocal`, for the agent to apply in source. Empty without any.
  final List<Map<String, Object?>> tweaks;

  /// Null when "Include screenshot" was off or the capture failed.
  final ScreenshotInfo? screenshot;

  /// Fields that failed to collect, for example `target.parentData`. The
  /// note is sent anyway.
  final List<String> errors;

  /// Fields cut to keep the payload in its size budget.
  final List<String> truncated;

  Annotation copyWith({
    String? comment,
    AnnotationIntent? intent,
    NoteStatus? status,
    NoteAnchor? Function()? anchor,
    List<NoteMessage>? messages,
    TargetInfo? target,
    List<AncestorInfo>? ancestors,
    List<String>? frameworkChain,
    SiblingsInfo? Function()? siblings,
    String? Function()? subtree,
    ScreenshotInfo? Function()? screenshot,
    Map<String, Object?>? Function()? environment,
    Map<String, Object?>? Function()? finding,
    List<Map<String, Object?>>? checks,
    List<Map<String, Object?>>? tweaks,
    Map<String, Object?>? Function()? verification,
    List<String>? errors,
    List<String>? truncated,
  }) => Annotation(
    id: id,
    createdAt: createdAt,
    intent: intent ?? this.intent,
    comment: comment ?? this.comment,
    app: app,
    page: page,
    target: target ?? this.target,
    status: status ?? this.status,
    anchor: anchor == null ? this.anchor : anchor(),
    messages: messages ?? this.messages,
    ancestors: ancestors ?? this.ancestors,
    frameworkChain: frameworkChain ?? this.frameworkChain,
    siblings: siblings == null ? this.siblings : siblings(),
    subtree: subtree == null ? this.subtree : subtree(),
    inherited: inherited,
    environment: environment == null ? this.environment : environment(),
    finding: finding == null ? this.finding : finding(),
    checks: checks ?? this.checks,
    tweaks: tweaks ?? this.tweaks,
    verification: verification == null ? this.verification : verification(),
    screenshot: screenshot == null ? this.screenshot : screenshot(),
    errors: errors ?? this.errors,
    truncated: truncated ?? this.truncated,
  );

  /// This note with [status].
  Annotation withStatus(NoteStatus status) => copyWith(status: status);

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

  /// [json] (a [toJson] map, as the bridge stores it) as a note, or null
  /// when it has no id.
  ///
  /// Reads defensively: a part of the wrong type is left empty, never
  /// thrown on. A schema 1 note, written before notes had a status, was
  /// sent, so it reads as [NoteStatus.submitted]. The screenshot's PNG is
  /// never read: the bridge keeps it beside the JSON.
  static Annotation? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String) return null;
    final target = _mapOrEmpty(json['target']);
    final shot = json['screenshot'];
    return Annotation(
      id: id,
      createdAt: _dateOrNull(json['createdAt']) ?? DateTime.utc(1970),
      status:
          NoteStatus.byName(json['status']) ??
          (json['schema'] == 1 ? NoteStatus.submitted : NoteStatus.draft),
      intent: AnnotationIntent.values.firstWhere(
        (i) => i.name == json['intent'],
        orElse: () => AnnotationIntent.improve,
      ),
      comment: _stringOrNull(json['comment']) ?? '',
      app: AppInfo._fromJson(_mapOrEmpty(json['app'])),
      page: PageInfo._fromJson(_mapOrEmpty(json['page'])),
      environment: switch (json['environment']) {
        final Map<String, Object?> env when env.isNotEmpty => env,
        _ => null,
      },
      finding: switch (json['finding']) {
        final Map<String, Object?> finding when finding.isNotEmpty => finding,
        _ => null,
      },
      checks: [
        for (final check in _listOrEmpty(json['checks']))
          if (check is Map<String, Object?> && check['type'] is String) check,
      ],
      tweaks: [
        for (final tweak in _listOrEmpty(json['tweaks']))
          if (tweak is Map<String, Object?> &&
              tweak['property'] is String &&
              tweak['from'] is String &&
              tweak['to'] is String)
            tweak,
      ],
      verification: switch (json['verification']) {
        final Map<String, Object?> v when v.isNotEmpty => v,
        _ => null,
      },
      target: TargetInfo._fromJson(target),
      anchor: json['anchor'] is Map<String, Object?>
          ? NoteAnchor.fromJson(json['anchor']! as Map<String, Object?>)
          : null,
      messages: [
        for (final m in _listOrEmpty(json['messages']))
          ?NoteMessage.fromJson(m),
      ],
      ancestors: [
        for (final a in _listOrEmpty(json['ancestors']))
          if (a is Map<String, Object?> && a['widget'] is String)
            AncestorInfo(
              widget: a['widget']! as String,
              source: SourceRef._fromJson(a['source']),
            ),
      ],
      frameworkChain: [
        for (final n in _listOrEmpty(json['frameworkChain']))
          if (n is String) n,
      ],
      siblings: SiblingsInfo._fromJson(json['siblings']),
      subtree: _stringOrNull(json['subtree']),
      inherited: json['inherited'] is Map<String, Object?>
          ? InheritedInfo._fromJson(json['inherited']! as Map<String, Object?>)
          : null,
      screenshot: shot is Map<String, Object?>
          ? ScreenshotInfo._fromJson(shot)
          : null,
      errors: _strings(json['errors']),
      truncated: _strings(json['truncated']),
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
    'status': status.name,
    'intent': intent.name,
    'comment': comment,
    'app': app.toJson(),
    'page': page.toJson(),
    if (environment case final env? when env.isNotEmpty) 'environment': env,
    'finding': ?finding,
    if (checks.isNotEmpty) 'checks': checks,
    if (tweaks.isNotEmpty) 'tweaks': tweaks,
    'verification': ?verification,
    'target': target.toJson(),
    'anchor': anchor?.toJson(),
    'messages': [for (final m in messages) m.toJson()],
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
    this.origin,
  });

  factory AppInfo._fromJson(Map<String, Object?> json) => AppInfo(
    buildMode: _stringOrNull(json['buildMode']) ?? 'debug',
    platform: _stringOrNull(json['platform']) ?? 'web',
    projectRoot: _stringOrNull(json['projectRoot']),
    origin: _stringOrNull(json['origin']),
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
    url: _stringOrNull(json['url']),
    route: _stringOrNull(json['route']),
    viewport: PayloadSize._fromJson(json['viewport']),
    devicePixelRatio: _doubleOrNull(json['devicePixelRatio']),
    textScale: _doubleOrNull(json['textScale']),
    brightness: _stringOrNull(json['brightness']),
    locale: _stringOrNull(json['locale']),
  );

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

  factory TargetInfo._fromJson(Map<String, Object?> json) => TargetInfo(
    widget: _stringOrNull(json['widget']) ?? '?',
    description: _stringOrNull(json['description']),
    key: _stringOrNull(json['key']),
    source: SourceRef._fromJson(json['source']),
    sourceUnavailable: json['sourceUnavailable'] == true,
    rect: PayloadRect._fromJson(json['rect']),
    renderObject: _stringOrNull(json['renderObject']),
    constraints: _stringOrNull(json['constraints']),
    parentData: _stringOrNull(json['parentData']),
    text: _stringOrNull(json['text']),
    properties: _stringMap(json['properties']),
    sections: {
      for (final MapEntry(:key, :value) in _mapOrEmpty(
        json['sections'],
      ).entries)
        key: _stringMap(value),
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

  static SiblingsInfo? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final parent = json['parent'];
    if (parent is! String) return null;
    return SiblingsInfo(
      parent: parent,
      index: _intOrNull(json['index']) ?? 0,
      count: _intOrNull(json['count']) ?? 0,
      firstIndex: _intOrNull(json['firstIndex']) ?? 0,
      children: _strings(json['children']),
    );
  }

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

  factory InheritedInfo._fromJson(Map<String, Object?> json) => InheritedInfo(
    themeBrightness: _stringOrNull(json['themeBrightness']),
    useMaterial3: json['useMaterial3'] is bool
        ? json['useMaterial3']! as bool
        : null,
    textDirection: _stringOrNull(json['textDirection']),
  );

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
    this.beforeAfter = false,
    this.png,
  });

  factory ScreenshotInfo._fromJson(Map<String, Object?> json) => ScreenshotInfo(
    file: _stringOrNull(json['file']) ?? '',
    pixelRatio: _doubleOrNull(json['pixelRatio']) ?? 1,
    width: _intOrNull(json['width']) ?? 0,
    height: _intOrNull(json['height']) ?? 0,
    crop: PayloadRect._fromJson(json['crop']),
    hasPlatformViews: json['hasPlatformViews'] == true,
    debugPaint: _strings(json['debugPaint']),
    beforeAfter: json['beforeAfter'] == true,
  );

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

  /// True when the image is two crops side by side: on the left the screen
  /// without the note's tweaks, on the right with them.
  final bool beforeAfter;

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
    'beforeAfter': beforeAfter,
    if (includeData && png != null) 'data': base64Encode(png!),
  };
}

/// A rect in global logical pixels, without `dart:ui`.
class PayloadRect {
  const PayloadRect(this.x, this.y, this.w, this.h);

  static PayloadRect? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final x = _doubleOrNull(json['x']);
    final y = _doubleOrNull(json['y']);
    final w = _doubleOrNull(json['w']);
    final h = _doubleOrNull(json['h']);
    if (x == null || y == null || w == null || h == null) return null;
    return PayloadRect(x, y, w, h);
  }

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

  static PayloadSize? _fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final width = _doubleOrNull(json['width']);
    final height = _doubleOrNull(json['height']);
    if (width == null || height == null) return null;
    return PayloadSize(width, height);
  }

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
      file: _stringOrNull(json['file']),
      line: _intOrNull(json['line']),
      column: _intOrNull(json['column']),
      widget: _stringOrNull(json['widget']),
      key: _stringOrNull(json['key']),
      ordinal: ordinal is int && ordinal >= 0 ? ordinal : 0,
      itemIndex: _intOrNull(json['itemIndex']),
      route: _stringOrNull(json['route']),
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

String? _stringOrNull(Object? value) => value is String ? value : null;

int? _intOrNull(Object? value) => value is int ? value : null;

double? _doubleOrNull(Object? value) => value is num ? value.toDouble() : null;

DateTime? _dateOrNull(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

Map<String, Object?> _mapOrEmpty(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

List<Object?> _listOrEmpty(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

List<String> _strings(Object? value) => [
  for (final v in _listOrEmpty(value))
    if (v is String) v,
];

Map<String, String> _stringMap(Object? value) => {
  for (final MapEntry(:key, :value) in _mapOrEmpty(value).entries)
    if (value is String) key: value,
};
